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

/// Whether the saved record still opens a session with the phone.
pub async fn verify(phone: &Phone) -> Result<bool> {
    let Some(record) = saved(&phone.udid)? else { return Ok(false) };
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;
    match lockdown.start_session(&record).await {
        Ok(_) => Ok(true),
        Err(idevice::IdeviceError::InvalidHostID) => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// Pairs over USB. Waits for the person to tap Trust and enter the passcode (up to `wait`), then
/// tests the record, saves it on this computer and with usbmuxd. Returns the record's bytes.
pub async fn pair(phone: &Phone, reporter: &Reporter, wait: Duration) -> Result<Vec<u8>> {
    if !phone.is_usb() {
        return Err(Error::device("Pairing needs the cable. Plug the iPhone in with a data cable."));
    }
    reporter.step("pair", "Pairing with the iPhone");
    let mut mux = UsbmuxdConnection::default().await?;
    let buid = mux.get_buid().await?;
    let provider = phone.provider()?;
    let mut lockdown = LockdownClient::connect(&*provider).await?;

    // A record this computer or usbmuxd already holds is kept when it still works: the phone then
    // shows no dialog, and Poki keeps the identity it knows.
    if let Some(existing) = saved(&phone.udid)? {
        if lockdown.start_session(&existing).await.is_ok() {
            reporter.note("pair", "This iPhone already trusts this computer.");
            reporter.done("pair", None);
            return saved_bytes(&phone.udid)?.ok_or_else(|| Error::msg("The pairing record went missing while it was in use."));
        }
        let mut lockdown2 = LockdownClient::connect(&*provider).await?;
        std::mem::swap(&mut lockdown, &mut lockdown2);
    } else if let Ok(Some(existing)) = super::mux_pairing_record(&phone.udid).await {
        if lockdown.start_session(&existing).await.is_ok() {
            let mut existing = existing;
            existing.udid = Some(phone.udid.clone());
            let bytes = existing.serialize()?;
            write_record(&record_path(&phone.udid)?, &bytes)?;
            reporter.note("pair", "Using the trust this computer already has with the iPhone.");
            reporter.done("pair", None);
            return Ok(bytes);
        }
        let mut lockdown2 = LockdownClient::connect(&*provider).await?;
        std::mem::swap(&mut lockdown, &mut lockdown2);
    }

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

    #[test]
    fn a_failed_write_leaves_the_record_as_it_was_and_nothing_behind() {
        let (_lock, _dir) = crate::paths::test_home();
        let path = remote_record_path("TEST-UDID").unwrap();
        write_record(&path, b"kept").unwrap();
        // A folder where the other record should go: the temporary file cannot take its place.
        let blocked = record_path("TEST-UDID").unwrap();
        std::fs::create_dir(&blocked).unwrap();
        std::fs::write(blocked.join("inside"), b"").unwrap();
        assert!(write_record(&blocked, b"record").is_err());
        assert_eq!(names_in(&crate::paths::pairings_dir().unwrap()), ["TEST-UDID.plist", "TEST-UDID.rppairing.plist"]);
        assert_eq!(std::fs::read(&path).unwrap(), b"kept");
        assert_eq!(mode(&path), 0o600);
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
