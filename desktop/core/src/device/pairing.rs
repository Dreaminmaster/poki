//! Lockdown pairing over USB (the Trust This Computer dance) and the records it leaves behind.
//!
//! The record is what Poki on the phone needs to talk to its own developer services through the
//! loopback, so it is saved on this computer (`paths::pairings_dir`), given to usbmuxd, and handed
//! to the phone with [`crate::pairshare`].
use super::{LABEL, Phone};
use crate::{Error, Progress, Reporter, Result, paths};
use idevice::{IdeviceService, lockdown::LockdownClient, pairing_file::PairingFile, usbmuxd::UsbmuxdConnection};
use std::{path::{Path, PathBuf}, time::Duration};

pub const HOST_NAME: &str = "Poki Setup";

pub fn record_path(udid: &str) -> Result<PathBuf> {
    Ok(paths::pairings_dir()?.join(format!("{udid}.plist")))
}

/// The record saved on this computer for `udid`, if any.
pub fn saved(udid: &str) -> Result<Option<PairingFile>> {
    let Some(bytes) = read_record(&record_path(udid)?)? else { return Ok(None) };
    Ok(Some(PairingFile::from_bytes(&bytes)?))
}

/// Writes a record (either kind) readable by this user only from the moment it exists: whoever
/// holds it can use the iPhone's developer services. The bytes go to a private temporary file in
/// the records folder (0600 where the platform has modes), which then takes the record's place, so
/// a record is never open to others or half written. On a failure nothing is left behind.
fn write_record(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let dir = path.parent().ok_or_else(|| Error::msg("A pairing record needs a folder."))?;
    let mut file = tempfile::NamedTempFile::new_in(dir)?;
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| e.error)?;
    Ok(())
}

/// Reads a record (either kind), first closing one an earlier version left readable by other users.
/// A record that cannot be made private is not used.
fn read_record(path: &Path) -> Result<Option<Vec<u8>>> {
    if !path.exists() {
        return Ok(None);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if std::fs::metadata(path)?.permissions().mode() & 0o077 != 0 {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e| {
                Error::msg(format!("The pairing record {} is readable by other users of this computer and could not be made private ({e}). Remove it and pair again.", path.display()))
            })?;
        }
    }
    Ok(Some(std::fs::read(path)?))
}

/// The saved record's bytes, as Poki wants them (a lockdown pairing plist, UDID included).
pub fn saved_bytes(udid: &str) -> Result<Option<Vec<u8>>> {
    read_record(&record_path(udid)?)
}

// Settling on one record.
//
// Two records can speak for this computer: the one Poki Setup saved (`record_path`) and the one
// usbmuxd keeps (Finder on the Mac, Apple Devices on Windows). They drift apart when the phone
// forgets one (Reset Location & Privacy, an erase, an update), when another app pairs again, or
// when usbmuxd did not take the record Poki Setup gave it. Pairing used to check only the saved
// record while every service over the cable used usbmuxd's, so setup failed with "not paired"
// at the profiles or remote pairing step right after pairing worked (#421). `settle` finds the
// record the phone accepts, keeps it in both places, and the USB provider uses it.

/// Where a record came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Source {
    Saved,
    Mux,
}

/// What [`settle`] does once it knows which records the phone accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Plan {
    /// The record to use from now on.
    keep: Source,
    /// Save it as this computer's record (it came from usbmuxd).
    write_saved: bool,
    /// Give it to usbmuxd, whose record is missing or no longer accepted.
    write_mux: bool,
}

/// `saved` and `mux` are `None` when there is no such record, else whether the phone accepts it.
/// `None` back means the phone accepts neither: it has to be trusted again.
fn plan(saved: Option<bool>, mux: Option<bool>) -> Option<Plan> {
    match (saved, mux) {
        (Some(true), mux) => Some(Plan { keep: Source::Saved, write_saved: false, write_mux: mux != Some(true) }),
        (_, Some(true)) => Some(Plan { keep: Source::Mux, write_saved: true, write_mux: false }),
        _ => None,
    }
}

/// The record each phone last accepted in this run, which the USB provider opens sessions with.
static SETTLED: std::sync::Mutex<Option<std::collections::HashMap<String, PairingFile>>> = std::sync::Mutex::new(None);

/// The record the phone last accepted from this computer in this run, if any.
pub fn settled(udid: &str) -> Option<PairingFile> {
    SETTLED.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|m| m.get(udid).cloned())
}

fn remember(udid: &str, record: Option<&PairingFile>) {
    let mut map = SETTLED.lock().unwrap_or_else(|e| e.into_inner());
    let map = map.get_or_insert_with(Default::default);
    match record {
        Some(r) => map.insert(udid.to_string(), r.clone()),
        None => map.remove(udid),
    };
}

#[cfg(test)]
pub(crate) fn remember_for_test(udid: &str, host_id: Option<&str>) {
    remember(udid, host_id.map(settle_tests::fake_record).as_ref());
}

/// Whether the phone opens a lockdown session with `record`. A record it does not know is `false`;
/// any other failure (the phone went away, usbmuxd stopped) is an error.
async fn accepts(phone: &Phone, record: &PairingFile) -> Result<bool> {
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;
    match lockdown.start_session(record).await {
        Ok(_) => Ok(true),
        Err(idevice::IdeviceError::InvalidHostID) => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// Finds the record the phone accepts (the saved one, else usbmuxd's), saves it on this computer,
/// gives it to usbmuxd when usbmuxd's is missing or stale, and has the USB provider use it.
/// `None` when the phone trusts neither: the person has to tap Trust again ([`pair`]).
pub async fn settle(phone: &Phone) -> Result<Option<PairingFile>> {
    let saved = match saved(&phone.udid) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("the saved pairing record does not read, trying usbmuxd's: {e}");
            None
        }
    };
    let through_mux = !matches!(phone.link, super::Link::Wifi { .. });
    let mux = if through_mux { super::mux_pairing_record(&phone.udid).await.ok().flatten() } else { None };

    let saved_ok = match &saved {
        Some(r) => Some(accepts(phone, r).await?),
        None => None,
    };
    let mux_ok = match (&mux, &saved) {
        (Some(m), Some(s)) if m.host_id == s.host_id => saved_ok,
        (Some(m), _) => Some(accepts(phone, m).await?),
        (None, _) => None,
    };

    let Some(plan) = plan(saved_ok, mux_ok) else {
        remember(&phone.udid, None);
        return Ok(None);
    };
    let mut record = match plan.keep {
        Source::Saved => saved.expect("plan keeps a saved record only when there is one"),
        Source::Mux => mux.expect("plan keeps usbmuxd's record only when there is one"),
    };
    record.udid = Some(phone.udid.clone());
    if plan.write_saved || plan.write_mux {
        let bytes = record.clone().serialize()?;
        if plan.write_saved {
            write_record(&record_path(&phone.udid)?, &bytes)?;
            tracing::info!("the iPhone trusts usbmuxd's pairing record, not the one saved here; saved usbmuxd's");
        }
        if plan.write_mux && through_mux {
            match UsbmuxdConnection::default().await {
                Ok(mut mux) => match mux.save_pair_record(&phone.udid, bytes).await {
                    Ok(()) => tracing::info!("gave usbmuxd the pairing record the iPhone trusts"),
                    Err(e) => tracing::warn!("usbmuxd did not take the pairing record the iPhone trusts: {e}"),
                },
                Err(e) => tracing::warn!("could not reach usbmuxd to give it the pairing record: {e}"),
            }
        }
    }
    remember(&phone.udid, Some(&record));
    Ok(Some(record))
}

/// Whether the phone still trusts this computer, through the saved record or usbmuxd's. A record
/// that works is settled on ([`settle`]), so the steps after this use it.
pub async fn verify(phone: &Phone) -> Result<bool> {
    Ok(settle(phone).await?.is_some())
}

/// Pairs over USB. Waits for the person to tap Trust and enter the passcode (up to `wait`), then
/// tests the record, saves it on this computer and with usbmuxd. Returns the record's bytes.
pub async fn pair(phone: &Phone, reporter: &Reporter, wait: Duration) -> Result<Vec<u8>> {
    if !phone.is_usb() {
        return Err(Error::device("Pairing needs the cable. Plug the iPhone in with a data cable."));
    }
    reporter.step("pair", "Pairing with the iPhone");

    // A record this computer or usbmuxd already holds is kept when it still works: the phone then
    // shows no dialog, and Poki keeps the identity it knows.
    if settle(phone).await?.is_some() {
        reporter.note("pair", "This iPhone already trusts this computer.");
        reporter.done("pair", None);
        return saved_bytes(&phone.udid)?.ok_or_else(|| Error::msg("The pairing record went missing while it was in use."));
    }

    let mut mux = UsbmuxdConnection::default().await?;
    let buid = mux.get_buid().await?;
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;
    let host_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    reporter.waiting("pair", "On the iPhone: tap Trust, then enter the passcode.");
    let pairing = tokio::time::timeout(wait, lockdown.pair(host_id, buid, Some(HOST_NAME)))
        .await
        .map_err(|_| Error::NeedsPerson("The iPhone did not answer the Trust dialog in time. Unlock it, plug it in again and tap Trust.".into()))??;
    let mut record = pairing;
    record.udid = Some(phone.udid.clone());

    // Test it before anything is saved.
    let mut check = LockdownClient::connect(&*provider).await?;
    check.start_session(&record).await?;

    let bytes = record.clone().serialize()?;
    write_record(&record_path(&phone.udid)?, &bytes)?;
    if let Err(e) = mux.save_pair_record(&phone.udid, bytes.clone()).await {
        tracing::warn!("usbmuxd did not keep the pairing record: {e}");
    }
    remember(&phone.udid, Some(&record));
    reporter.done("pair", Some("Paired.".into()));
    reporter.emit(Progress::Note { id: "pair".into(), text: format!("Record saved for {}.", phone.udid) });
    Ok(bytes)
}

/// Forgets the record on this computer and asks the phone to forget this host.
pub async fn unpair(phone: &Phone) -> Result<()> {
    if let Some(record) = saved(&phone.udid)? {
        let provider = phone.provider()?;
        let mut lockdown = LockdownClient::connect(&*provider).await?;
        let _ = lockdown.start_session(&record).await;
        let _ = lockdown.unpair(record.host_id.clone()).await;
    }
    remember(&phone.udid, None);
    let path = record_path(&phone.udid)?;
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    let _ = LABEL;
    Ok(())
}


/// Lets the iPhone accept this pairing over the network as well as the cable
/// (`com.apple.mobile.wireless_lockdown` / `EnableWifiConnections`). Poki talks to the phone's
/// own services over the loopback, which lockdown treats as a network connection: without this,
/// the record works over USB only and Poki's connections fail with "device socket io failed".
pub async fn enable_network(phone: &Phone) -> Result<()> {
    let record = saved(&phone.udid)?.ok_or_else(|| Error::device("Pair the iPhone first."))?;
    let provider = phone.provider()?;
    let mut lockdown = idevice::lockdown::LockdownClient::connect(&*provider).await?;
    lockdown.start_session(&record).await?;
    lockdown.set_value("EnableWifiConnections", true.into(), Some("com.apple.mobile.wireless_lockdown")).await?;
    Ok(())
}

// Remote pairing (RPPairing).
//
// Since iOS 26.4 the phone hangs up on lockdown records over the loopback Poki uses to reach its
// own developer services; a Remote Pairing record (the kind the phone makes for itself, or that
// idevice_pair makes over USB) is accepted there. Poki Setup makes one over the cable, through
// remotepairingdeviced, right after the lockdown pairing, and that is what Poki gets.

/// The plist key Poki reads for the host name to send with an RPPairing record.
pub const SENDING_HOST_KEY: &str = "sending_host";

pub fn remote_record_path(udid: &str) -> Result<PathBuf> {
    Ok(paths::pairings_dir()?.join(format!("{udid}.rppairing.plist")))
}

/// Whether `bytes` is an RPPairing record (public_key, private_key, identifier) rather than a
/// lockdown pairing plist.
pub fn is_remote_record(bytes: &[u8]) -> bool {
    idevice::remote_pairing::RpPairingFile::from_bytes(bytes).is_ok()
}

/// The saved RPPairing record for `udid`, as Poki wants it.
pub fn saved_remote_bytes(udid: &str) -> Result<Option<Vec<u8>>> {
    read_record(&remote_record_path(udid)?)
}

/// The record to give Poki: the RPPairing record when there is one, else the lockdown record.
pub fn for_poki(udid: &str) -> Result<Option<Vec<u8>>> {
    Ok(match saved_remote_bytes(udid)? {
        Some(b) => Some(b),
        None => saved_bytes(udid)?,
    })
}

/// Whether the iOS version string is one where the phone needs an RPPairing record for the
/// loopback (26.4 and later).
pub fn needs_remote_record(ios: &str) -> bool {
    let mut parts = ios.split('.').map(|p| p.parse::<u32>().unwrap_or(0));
    let major = parts.next().unwrap_or(0);
    let minor = parts.next().unwrap_or(0);
    (major, minor) >= (26, 4)
}

/// Makes (or reuses) an RPPairing record over USB. The lockdown pairing must already exist (the
/// service is reached through lockdown). The iPhone may ask to trust this computer again; it has
/// to be unlocked, ideally on the Home Screen. Returns the record's bytes.
pub async fn pair_remote(phone: &Phone, reporter: &Reporter, wait: Duration) -> Result<Vec<u8>> {
    use idevice::remote_pairing::{RemotePairingLockdownService, RpPairingFile};
    if !phone.is_usb() {
        return Err(Error::device("Remote pairing needs the cable. Plug the iPhone in with a data cable."));
    }
    let provider = phone.provider()?;
    let path = remote_record_path(&phone.udid)?;

    // A record that still verifies is kept: Poki may already be using it.
    if let Some(bytes) = read_record(&path)? {
        if let Ok(mut file) = RpPairingFile::from_bytes(&bytes) {
            let ok = async {
                let service = RemotePairingLockdownService::connect(&*provider).await?;
                let mut client = service.into_client(HOST_NAME)?;
                client.attempt_pair_verify().await?;
                client.validate_pairing(&mut file).await
            };
            match tokio::time::timeout(Duration::from_secs(15), ok).await {
                Ok(Ok(_)) => return Ok(bytes),
                Ok(Err(e)) => tracing::info!("saved RPPairing record no longer verifies: {e}"),
                Err(_) => tracing::info!("verifying the saved RPPairing record timed out"),
            }
        }
    }

    reporter.waiting("pair", "On the iPhone: stay on the Home Screen, unlocked. If it asks, tap Trust and enter the passcode.");
    let mut file = RpPairingFile::generate(HOST_NAME);
    let made = async {
        let service = RemotePairingLockdownService::connect(&*provider).await?;
        let mut client = service.into_client(HOST_NAME)?;
        client.connect(&mut file, || async { "000000".to_string() }).await
    };
    tokio::time::timeout(wait, made)
        .await
        .map_err(|_| Error::NeedsPerson("The iPhone did not finish remote pairing in time. Unlock it, stay on the Home Screen and try again.".into()))??;

    let bytes = with_sending_host(&file.to_bytes(), HOST_NAME)?;
    write_record(&path, &bytes)?;
    Ok(bytes)
}

/// Adds the `sending_host` key Poki reads, so it identifies itself by the name the record was
/// made with.
fn with_sending_host(bytes: &[u8], host: &str) -> Result<Vec<u8>> {
    let mut dict: plist::Dictionary = plist::from_bytes(bytes).map_err(|e| Error::msg(format!("RPPairing record: {e}")))?;
    dict.insert(SENDING_HOST_KEY.into(), plist::Value::String(host.into()));
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, &dict).map_err(|e| Error::msg(format!("RPPairing record: {e}")))?;
    Ok(out)
}

#[cfg(test)]
mod settle_tests {
    use super::*;

    /// A record with made-up keys: enough for the provider and the plan, never sent to a phone.
    pub(crate) fn fake_record(host_id: &str) -> PairingFile {
        PairingFile {
            device_certificate: vec![1].into(),
            host_private_key: vec![2],
            host_certificate: vec![3].into(),
            root_private_key: vec![4],
            root_certificate: vec![5].into(),
            system_buid: "BUID".into(),
            host_id: host_id.into(),
            escrow_bag: None,
            wifi_mac_address: "00:00:00:00:00:00".into(),
            udid: None,
        }
    }

    #[test]
    fn a_working_saved_record_repairs_a_stale_usbmuxd_record() {
        // #421: the phone trusts Poki Setup's record, but Apple Devices keeps one it forgot.
        assert_eq!(plan(Some(true), Some(false)), Some(Plan { keep: Source::Saved, write_saved: false, write_mux: true }));
        assert_eq!(plan(Some(true), None), Some(Plan { keep: Source::Saved, write_saved: false, write_mux: true }));
        assert_eq!(plan(Some(true), Some(true)), Some(Plan { keep: Source::Saved, write_saved: false, write_mux: false }));
    }

    #[test]
    fn a_working_usbmuxd_record_replaces_a_stale_saved_one_without_a_trust_dialog() {
        // The person trusted the computer again in Finder or Apple Devices after the phone forgot it.
        assert_eq!(plan(Some(false), Some(true)), Some(Plan { keep: Source::Mux, write_saved: true, write_mux: false }));
        assert_eq!(plan(None, Some(true)), Some(Plan { keep: Source::Mux, write_saved: true, write_mux: false }));
    }

    #[test]
    fn no_working_record_means_trust_again() {
        assert_eq!(plan(Some(false), Some(false)), None);
        assert_eq!(plan(None, Some(false)), None);
        assert_eq!(plan(Some(false), None), None);
        assert_eq!(plan(None, None), None);
    }

    #[test]
    fn the_settled_record_is_remembered_per_phone_and_forgotten() {
        remember("SETTLE-A", Some(&fake_record("HOST-A")));
        remember("SETTLE-B", Some(&fake_record("HOST-B")));
        assert_eq!(settled("SETTLE-A").map(|r| r.host_id), Some("HOST-A".into()));
        assert_eq!(settled("SETTLE-B").map(|r| r.host_id), Some("HOST-B".into()));
        remember("SETTLE-A", None);
        assert!(settled("SETTLE-A").is_none());
        assert!(settled("SETTLE-B").is_some());
    }
}

#[cfg(test)]
mod remote_tests {
    use super::*;

    #[test]
    fn cutoff_is_26_4() {
        assert!(!needs_remote_record("26.3.1"));
        assert!(needs_remote_record("26.4"));
        assert!(needs_remote_record("27.3"));
        assert!(!needs_remote_record("18.6"));
    }

    #[test]
    fn sending_host_survives_and_record_still_reads() {
        let f = idevice::remote_pairing::RpPairingFile::generate(HOST_NAME);
        let b = with_sending_host(&f.to_bytes(), HOST_NAME).unwrap();
        assert!(is_remote_record(&b));
        let d: plist::Dictionary = plist::from_bytes(&b).unwrap();
        assert_eq!(d.get(SENDING_HOST_KEY).and_then(|v| v.as_string()), Some(HOST_NAME));
        assert!(!is_remote_record(b"<plist><dict><key>HostID</key><string>x</string></dict></plist>"));
    }
}

#[cfg(all(test, unix))]
mod record_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    fn open_up(p: &Path, mode: u32) {
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    /// Nothing but the record itself in the records folder: no temporary file left over.
    fn names_in(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        names
    }

    #[test]
    fn both_kinds_of_record_are_private_from_creation() {
        let (_lock, _dir) = crate::paths::test_home();
        for path in [record_path("TEST-UDID").unwrap(), remote_record_path("TEST-UDID").unwrap()] {
            write_record(&path, b"record").unwrap();
            assert_eq!(mode(&path), 0o600, "{}", path.display());
            assert_eq!(mode(path.parent().unwrap()), 0o700);
            // Writing over a record an earlier version left open replaces it with a private one.
            open_up(&path, 0o644);
            write_record(&path, b"again").unwrap();
            assert_eq!(mode(&path), 0o600, "{}", path.display());
            assert_eq!(std::fs::read(&path).unwrap(), b"again");
        }
        assert_eq!(names_in(&crate::paths::pairings_dir().unwrap()), ["TEST-UDID.plist", "TEST-UDID.rppairing.plist"]);
    }

    #[test]
    fn an_open_records_folder_is_closed() {
        let (_lock, _dir) = crate::paths::test_home();
        let dir = crate::paths::pairings_dir().unwrap();
        assert_eq!(mode(&dir), 0o700);
        open_up(&dir, 0o755);
        crate::paths::pairings_dir().unwrap();
        assert_eq!(mode(&dir), 0o700);
    }

    #[test]
    fn every_read_path_closes_a_record_left_open() {
        let (_lock, _dir) = crate::paths::test_home();
        let local = record_path("TEST-UDID").unwrap();
        let remote = remote_record_path("TEST-UDID").unwrap();
        let reads: [(&str, &Path, fn() -> bool); 4] = [
            ("saved", &local, || saved("TEST-UDID").is_err()), // not a real record: read, then refused
            ("saved_bytes", &local, || saved_bytes("TEST-UDID").unwrap().is_some()),
            ("saved_remote_bytes", &remote, || saved_remote_bytes("TEST-UDID").unwrap().is_some()),
            ("for_poki", &remote, || for_poki("TEST-UDID").unwrap().is_some()),
        ];
        for (name, path, read) in reads {
            write_record(path, b"record").unwrap();
            open_up(path, 0o644);
            assert!(read(), "{name}");
            assert_eq!(mode(path), 0o600, "{name}");
        }
    }

    /// Writing over each kind of record fails (the records folder takes no new file, so the
    /// temporary file cannot be made): that record still reads, unchanged and private.
    #[test]
    fn a_failed_write_leaves_the_record_as_it_was_and_nothing_behind() {
        let (_lock, _dir) = crate::paths::test_home();
        let dir = crate::paths::pairings_dir().unwrap();
        let kinds: [(&str, PathBuf, fn() -> Option<Vec<u8>>); 2] = [
            ("lockdown", record_path("TEST-UDID").unwrap(), || saved_bytes("TEST-UDID").unwrap()),
            ("RPPairing", remote_record_path("TEST-UDID").unwrap(), || saved_remote_bytes("TEST-UDID").unwrap()),
        ];
        for (kind, path, _) in &kinds {
            write_record(path, format!("{kind} kept").as_bytes()).unwrap();
        }
        open_up(&dir, 0o500);
        // Root writes into a read-only folder anyway, so there is no failure to see.
        if std::fs::write(dir.join("probe"), b"").is_ok() {
            let _ = std::fs::remove_file(dir.join("probe"));
            open_up(&dir, 0o700);
            eprintln!("skipped: this user can write into a read-only folder");
            return;
        }
        for (kind, path, read) in &kinds {
            assert!(write_record(path, b"replacement").is_err(), "{kind}: the write fails");
            assert_eq!(read().as_deref(), Some(format!("{kind} kept").as_bytes()), "{kind}: the record still reads, unchanged");
            assert_eq!(mode(path), 0o600, "{kind}");
        }
        open_up(&dir, 0o700);
        assert_eq!(names_in(&dir), ["TEST-UDID.plist", "TEST-UDID.rppairing.plist"], "nothing left behind");
    }

    /// The owner cannot change the mode of a file with the user immutable flag (macOS `chflags uchg`).
    #[cfg(target_os = "macos")]
    #[test]
    fn a_record_that_cannot_be_made_private_is_not_used() {
        let (_lock, _dir) = crate::paths::test_home();
        let path = remote_record_path("TEST-UDID").unwrap();
        write_record(&path, b"record").unwrap();
        open_up(&path, 0o644);
        let flag = |f: &str| assert!(std::process::Command::new("chflags").arg(f).arg(&path).status().unwrap().success());
        flag("uchg");
        let read = saved_remote_bytes("TEST-UDID");
        let fallback = for_poki("TEST-UDID");
        flag("nouchg");
        let err = read.expect_err("an open record is refused").to_string();
        assert!(err.contains("could not be made private"), "{err}");
        assert!(fallback.is_err(), "nor handed to Poki");
        assert_eq!(mode(&path), 0o644, "left as it was found");
    }
}
