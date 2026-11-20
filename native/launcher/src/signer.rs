//! Poki keeps its own signing: Poki Setup's core (desktop/core) on the phone. It signs in to the
//! Apple account with remote anisette, asks the developer portal for the certificate and the 7-day
//! profiles, re-signs Poki (the installed copy for a refresh, the channel's release for an update)
//! ahead of time, and installs it over the loopback when the person says so.
//!
//! Secrets never touch a file: the app installs a [`Vault`] backed by its Keychain before the
//! first call (poki_signer_set_vault). One request at a time; see include/poki_launcher.h.
use crate::device::{Device, Pairing};
use idevice::{installation_proxy::InstallationProxyClient, lockdown::LockdownClient, misagent::MisagentClient, utils::installation};
use poki_setup_core::{
    self as core, Progress, Reporter,
    apple::{
        anisette::Source,
        gsa::{CodeCaller, Pending},
        identity,
    },
    release::{self, Channel},
    setup::{self, Signer},
    sign,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    net::IpAddr,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

type EmitFn = Arc<dyn Fn(Value) + Send + Sync>;

tokio::task_local! {
    static LOG_EMIT: EmitFn;
}

fn ensure_log_hook() {
    core::apple::gsa::set_code_request_hook(|line| {
        let _ = LOG_EMIT.try_with(|cb| {
            cb(json!({"event": "log", "line": line}));
        });
    });
}

/// Signed in and pending state, shared by the calls.
struct State {
    signer: Option<Signer>,
    pending: Option<Pending>,
}

static STATE: tokio::sync::Mutex<State> = tokio::sync::Mutex::const_new(State { signer: None, pending: None });
static HOME: Mutex<Option<PathBuf>> = Mutex::new(None);

#[derive(Debug)]
pub struct Failure {
    pub message: String,
    pub code: &'static str,
}

impl From<core::Error> for Failure {
    fn from(e: core::Error) -> Self {
        let code = match &e {
            core::Error::NeedsCode(_) => "needs_code",
            // The Apple session ran out and no kept password opened a new one: the app offers Sign In
            // Again. Only this sentence, since Apple's -20101 also means a wrong password at sign-in.
            core::Error::NeedsPerson(m) if m == core::apple::gsa::SESSION_EXPIRED => "session_expired",
            core::Error::NeedsPerson(_) => "needs_person",
            core::Error::Apple { .. } => "apple",
            _ => e.kind(),
        };
        Failure { message: e.to_string(), code }
    }
}

impl From<crate::device::Failure> for Failure {
    fn from(e: crate::device::Failure) -> Self {
        let message = match e.fix {
            Some(fix) => format!("{} {}", e.detail, fix),
            None => e.detail,
        };
        Failure { message, code: e.code.unwrap_or("device") }
    }
}

impl From<idevice::IdeviceError> for Failure {
    fn from(e: idevice::IdeviceError) -> Self { Failure { message: e.to_string(), code: "device" } }
}

impl From<std::io::Error> for Failure {
    fn from(e: std::io::Error) -> Self { Failure { message: e.to_string(), code: "io" } }
}

fn fail(message: impl Into<String>, code: &'static str) -> Failure { Failure { message: message.into(), code } }

type Out = std::result::Result<Value, Failure>;

/// The phone's own services, as the launcher reaches them.
#[derive(Deserialize, Clone)]
struct Phone {
    device_address: String,
    pairing_file: String,
    #[serde(default)]
    host_name: Option<String>,
}

impl Phone {
    async fn open(&self) -> std::result::Result<Device, Failure> {
        let address: IpAddr = self.device_address.parse().map_err(|_| fail(format!("{} is not an address", self.device_address), "config"))?;
        let mut pairing = Pairing::read(Path::new(&self.pairing_file), self.host_name.as_deref())?;
        Ok(Device::open(address, &mut pairing, Duration::from_secs(20)).await?)
    }
}

fn str_of<'a>(v: &'a Value, key: &str) -> std::result::Result<&'a str, Failure> {
    v[key].as_str().filter(|s| !s.is_empty()).ok_or_else(|| fail(format!("{key} is missing"), "config"))
}

fn home() -> std::result::Result<PathBuf, Failure> {
    HOME.lock().unwrap().clone().ok_or_else(|| fail("the signer is not configured", "config"))
}

async fn signer(state: &mut State) -> std::result::Result<&mut Signer, Failure> {
    if core::vault::installed().is_none() {
        return Err(fail("the Keychain vault is not installed", "config"));
    }
    if state.signer.is_none() {
        state.signer = Some(Signer::open()?);
    }
    if state.signer.as_mut().unwrap().sync_account() {
        state.pending = None;
    }
    Ok(state.signer.as_mut().unwrap())
}

fn channels() -> Value {
    Value::Array([Channel::Beta].iter().map(|c| json!({"id": c.id(), "title": c.title()})).collect())
}

/// Runs one request. `emit` gets progress events while it runs.
pub async fn handle(request: Value, emit: impl Fn(Value) + Send + Sync + 'static) -> Out {
    ensure_log_hook();
    let emit_arc: EmitFn = Arc::new(emit);
    LOG_EMIT.scope(emit_arc.clone(), handle_inner(request, emit_arc)).await
}

async fn handle_inner(request: Value, emit_arc: EmitFn) -> Out {
    let op = request["op"].as_str().unwrap_or("");
    let reporter = Reporter::new(move |p: Progress| emit_arc(json!({"event": "progress", "progress": p})));
    match op {
        "configure" => {
            // Where the core keeps its non-secret files (release cache, channel, machine id).
            let dir = PathBuf::from(str_of(&request, "home")?);
            std::fs::create_dir_all(&dir)?;
            // SAFETY: set once, before any request reads them; the app makes this call at launch.
            unsafe {
                std::env::set_var("POKI_SETUP_HOME", &dir);
                if let Some(name) = request["device_name"].as_str() {
                    std::env::set_var("POKI_DEVICE_NAME", name);
                }
            }
            *HOME.lock().unwrap() = Some(dir);
            Ok(json!({}))
        }
        "status" => {
            let mut state = STATE.lock().await;
            signer(&mut state).await?;
            let mem_pending = state.pending.clone();
            let s = state.signer.as_mut().unwrap();
            let active_pending = mem_pending.or_else(|| s.pending().cloned());
            let pending = active_pending.is_some();
            let resend_available_at = active_pending.as_ref().map(|p| p.resend_available_at());
            let rate_limited = s.is_rate_limited();
            let rate_limited_until = s.rate_limited_until();
            let source = match s.account.anisette.clone().unwrap_or_else(Source::default_for_platform) {
                Source::Remote { url } => url,
                Source::System => "system".into(),
            };
            Ok(json!({
                "signed_in": s.signed_in(),
                "needs_reauth": s.needs_reauth(),
                "needs_code": pending,
                "rate_limited": rate_limited,
                "rate_limited_until": rate_limited_until,
                "resend_available_at": resend_available_at,
                "apple_id": s.account.apple_id(),
                "name": s.account.display_name(),
                "team_id": s.account.team_id,
                "keeps_password": s.account.password.is_some(),
                "anisette": source,
                "channel": release::channel().id(),
                "channels": channels(),
            }))
        }
        "sign_in" => {
            let mut state = STATE.lock().await;
            let (id, pw) = (str_of(&request, "apple_id")?.to_string(), str_of(&request, "password")?.to_string());
            let keep = request["keep_password"].as_bool().unwrap_or(true);
            let pending = signer(&mut state).await?.sign_in_as(&id, &pw, keep, CodeCaller::IosSignIn).await?;
            let needs_code = pending.is_some();
            state.pending = pending;
            Ok(json!({"needs_code": needs_code}))
        }
        "finish_sign_in" => {
            let mut state = STATE.lock().await;
            let code = str_of(&request, "code")?.to_string();
            signer(&mut state).await?;
            let mem_pending = state.pending.take();
            let s = state.signer.as_mut().unwrap();
            let pending = mem_pending.or_else(|| s.pending().cloned()).ok_or_else(|| fail("Sign in again. The verification step has expired.", "needs_person"))?;
            let result = s.finish_sign_in(pending, &code).await;
            if let Err(e) = result {
                state.pending = s.pending().cloned();
                return Err(e.into());
            }
            Ok(json!({}))
        }
        "cancel_sign_in" => {
            let mut state = STATE.lock().await;
            state.pending = None;
            signer(&mut state).await?.cancel_sign_in()?;
            Ok(json!({}))
        }
        "resend_code" => {
            let mut state = STATE.lock().await;
            let s = signer(&mut state).await?;
            match s.resend_code().await {
                Ok(pending) => {
                    let available_at = pending.resend_available_at();
                    state.pending = Some(pending);
                    Ok(json!({"resend_available_at": available_at}))
                }
                Err(e) => {
                    state.pending = s.pending().cloned();
                    Err(e.into())
                }
            }
        }
        "sign_out" => {
            let mut state = STATE.lock().await;
            state.pending = None;
            signer(&mut state).await?.sign_out()?;
            Ok(json!({}))
        }
        "teams" => {
            let mut state = STATE.lock().await;
            let s = signer(&mut state).await?;
            match s.teams().await {
                Ok(teams) => Ok(Value::Array(teams.into_iter().map(|t| json!({"team_id": t.team_id, "name": t.name, "kind": t.kind, "is_free": t.is_free})).collect())),
                Err(core::Error::NeedsCode(pending)) => {
                    let msg = core::Error::NeedsCode(pending.clone()).to_string();
                    state.pending = Some(*pending);
                    Err(fail(msg, "needs_code"))
                }
                Err(e) => Err(e.into()),
            }
        }
        "choose_team" => {
            let mut state = STATE.lock().await;
            signer(&mut state).await?.choose_team(str_of(&request, "team_id")?)?;
            Ok(json!({}))
        }
        "set_anisette" => {
            let mut state = STATE.lock().await;
            let url = request["url"].as_str().map(str::trim).filter(|u| !u.is_empty()).unwrap_or(core::apple::anisette::DEFAULT_REMOTE);
            if !url.starts_with("https://") {
                return Err(fail("The anisette server address starts with https://.", "needs_person"));
            }
            signer(&mut state).await?.set_anisette(Source::Remote { url: url.to_string() })?;
            Ok(json!({"anisette": url}))
        }
        "set_channel" => {
            let channel = Channel::parse(str_of(&request, "channel")?).ok_or_else(|| fail("unknown channel", "config"))?;
            release::set_channel(channel)?;
            Ok(json!({"channel": release::channel().id()}))
        }
        "import_identity" => import_identity(&request).await,
        "check_update" => {
            let r = release::latest().await?;
            Ok(json!({"tag": r.tag, "version": r.version, "build": r.build, "channel": r.channel.id(), "published_at": r.published_at, "notes": r.notes, "source": r.source, "source_notice": r.source_notice}))
        }
        "udid" => {
            let phone: Phone = serde_json::from_value(request.clone()).map_err(|e| fail(e.to_string(), "config"))?;
            let mut device = phone.open().await?;
            Ok(json!({"udid": udid(&mut device).await?}))
        }
        "apps" => {
            let phone: Phone = serde_json::from_value(request.clone()).map_err(|e| fail(e.to_string(), "config"))?;
            let mut device = phone.open().await?;
            Ok(json!({"apps": installed_apps(&mut device).await?}))
        }
        "prepare" => prepare(&request, &reporter).await,
        "install" => install(&request, &reporter).await,
        other => Err(fail(format!("unknown request {other:?}"), "config")),
    }
}

async fn udid(device: &mut Device) -> std::result::Result<String, Failure> {
    let mut lockdown: LockdownClient = device.connect().await?;
    let v = lockdown.get_value(Some("UniqueDeviceID"), None).await?;
    v.as_string().map(String::from).filter(|s| !s.is_empty()).ok_or_else(|| fail("the phone did not say its UDID", "device"))
}

/// Every app on the phone, as installation_proxy lists it (the service Poki Runner's lookup used):
/// its bundle id, its Home Screen name, its bundle name and whether it is a User or a System app. The
/// chat's agent launches apps by these ids instead of ids a model recalls (a tester's 淘宝 and 美团,
/// Nov 2026), and the app's icons and capsules know every installed app by name. Only these four
/// attributes are asked for, so the answer stays small.
async fn installed_apps(device: &mut Device) -> std::result::Result<Vec<Value>, Failure> {
    let mut proxy: InstallationProxyClient = device.connect().await?;
    let mut options = plist::Dictionary::new();
    options.insert("ApplicationType".into(), plist::Value::String("Any".into()));
    options.insert(
        "ReturnAttributes".into(),
        plist::Value::Array(["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "ApplicationType"].iter().map(|k| plist::Value::String((*k).into())).collect()),
    );
    let list = tokio::time::timeout(Duration::from_secs(20), proxy.browse(Some(plist::Value::Dictionary(options))))
        .await
        .map_err(|_| fail("The iPhone did not list its apps in time.", "device"))??;
    Ok(installed_entries(&list))
}

/// installation_proxy's entries as {id, name, bundle_name, type}; entries without a bundle id are left out.
fn installed_entries(list: &[plist::Value]) -> Vec<Value> {
    let text = |d: &plist::Dictionary, k: &str| d.get(k).and_then(|v| v.as_string()).map(str::trim).filter(|s| !s.is_empty()).map(String::from);
    list.iter()
        .filter_map(|app| {
            let d = app.as_dictionary()?;
            let id = text(d, "CFBundleIdentifier")?;
            Some(json!({"id": id, "name": text(d, "CFBundleDisplayName"), "bundle_name": text(d, "CFBundleName"), "type": text(d, "ApplicationType")}))
        })
        .collect()
}

/// Takes the signing key Poki Setup left in the container (Documents/PokiSetup/signing-identity.json),
/// keeps it in the Keychain and deletes the file, so the phone and the computer share one
/// certificate (a free team allows one).
async fn import_identity(request: &Value) -> Out {
    let path = PathBuf::from(str_of(request, "path")?);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(json!({"imported": false})),
        Err(e) => return Err(e.into()),
    };
    let v: Value = serde_json::from_str(&text).map_err(|e| fail(format!("signing-identity.json: {e}"), "config"))?;
    if v["schema"].as_str() != Some("poki.signing-identity/1") {
        return Err(fail("signing-identity.json has an unknown schema", "config"));
    }
    let team = str_of(&v, "team_id")?.to_string();
    identity::import_key(&team, str_of(&v, "key_pkcs8_pem")?)?;
    let mut state = STATE.lock().await;
    let s = signer(&mut state).await?;
    if s.account.team_id.is_none() {
        s.choose_team(&team)?;
    }
    std::fs::remove_file(&path)?;
    Ok(json!({"imported": true, "team_id": team, "apple_id": v["apple_id"]}))
}

/// Builds the next signed Poki ahead of time. kind "refresh" re-signs the installed app
/// (`app_path`, Bundle.main); kind "update" takes the newest release on the chosen channel.
/// The result lands in `<home>/ready/<kind>/` with a manifest; nothing is installed.
async fn prepare(request: &Value, reporter: &Reporter) -> Out {
    {
        let mut state = STATE.lock().await;
        signer(&mut state).await?;
        let mem_pending = state.pending.clone();
        let s = state.signer.as_mut().unwrap();
        if s.needs_reauth() {
            return Err(core::apple::gsa::incomplete_session().into());
        }
        if !s.signed_in() {
            return Err(fail("Sign in with your Apple Account in Setup first.", "needs_person"));
        }
        if s.is_rate_limited() {
            return Err(core::apple::gsa::rate_limited().into());
        }
        if let Some(pending) = mem_pending.or_else(|| s.pending().cloned()) {
            let msg = core::Error::NeedsCode(Box::new(pending.clone())).to_string();
            state.pending = Some(pending);
            return Err(fail(msg, "needs_code"));
        }
    }
    let kind = request["kind"].as_str().unwrap_or("refresh");
    let phone: Phone = serde_json::from_value(request.clone()).map_err(|e| fail(e.to_string(), "config"))?;
    let out_dir = home()?.join("ready").join(kind);
    let _ = std::fs::remove_dir_all(&out_dir);
    std::fs::create_dir_all(&out_dir)?;

    reporter.step("phone", "Checking this iPhone");
    let (udid, name) = match request["udid"].as_str() {
        Some(u) if !u.is_empty() => (u.to_string(), request["device_name"].as_str().unwrap_or("iPhone").to_string()),
        _ => {
            let mut device = phone.open().await?;
            (udid(&mut device).await?, request["device_name"].as_str().unwrap_or("iPhone").to_string())
        }
    };
    reporter.done("phone", Some(udid.clone()));

    let (ipa, signing_zip, tag) = match kind {
        "refresh" => {
            reporter.step("release", "Packing the installed Poki");
            let app = PathBuf::from(str_of(request, "app_path")?);
            let ipa = out_dir.join("installed.ipa");
            let (a, i) = (app.clone(), ipa.clone());
            tokio::task::spawn_blocking(move || sign::package_app(&a, &i)).await.map_err(|e| fail(e.to_string(), "io"))??;
            reporter.done("release", None);
            (ipa, None, "installed".to_string())
        }
        "update" => {
            reporter.step("release", "Getting the newest Poki");
            let rel = release::latest().await?;
            let (ipa, zip) = release::fetch(&rel, reporter).await?;
            reporter.done("release", Some(rel.tag.clone()));
            (ipa, zip, rel.tag)
        }
        other => return Err(fail(format!("unknown kind {other:?}"), "config")),
    };

    let automatic = request["automatic"].as_bool() == Some(true);
    let mut state = STATE.lock().await;
    let s = signer(&mut state).await?;
    if !s.signed_in() {
        return Err(fail("Sign in with your Apple Account in Setup first.", "needs_person"));
    }
    s.set_caller(if automatic { CodeCaller::IosMaintain } else { CodeCaller::IosPrepare });
    let team = match s.team().await {
        Ok(team) => team,
        Err(core::Error::NeedsCode(pending)) => {
            let msg = core::Error::NeedsCode(pending.clone()).to_string();
            state.pending = Some(*pending);
            return Err(fail(msg, "needs_code"));
        }
        Err(e) => return Err(e.into()),
    };
    let out = out_dir.join("Poki-signed.ipa");
    // Unpacking, signing and packing run synchronously inside; block_in_place moves the runtime's
    // other work (the runner's launcher) to another thread meanwhile instead of stalling it.
    let handle = tokio::runtime::Handle::current();
    let built = match tokio::task::block_in_place(|| handle.block_on(setup::sign_for_team(s, &team, Some((&udid, &name)), &ipa, signing_zip.as_deref(), &out, reporter))) {
        Ok(built) => built,
        Err(core::Error::NeedsCode(pending)) => {
            let msg = core::Error::NeedsCode(pending.clone()).to_string();
            state.pending = Some(*pending);
            return Err(fail(msg, "needs_code"));
        }
        Err(e) => return Err(e.into()),
    };
    let _ = std::fs::remove_file(out_dir.join("installed.ipa"));
    let mut profiles = vec![];
    for (i, p) in built.profiles.iter().enumerate() {
        let path = out_dir.join(format!("profile-{i}.mobileprovision"));
        std::fs::write(&path, p)?;
        profiles.push(path.to_string_lossy().to_string());
    }
    let manifest = json!({
        "kind": kind,
        "ipa": built.ipa.to_string_lossy(),
        "profiles": profiles,
        "bundle_id": built.bundle_id,
        "version": built.version,
        "build": built.build,
        "tag": tag,
        "team_id": team.team_id,
        "team_name": team.name,
        "team_is_free": team.is_free,
        "profile_expires_at": built.profile_expires_at,
        "prepared_at": core::keeper::now(),
        "notes": built.notes,
    });
    std::fs::write(out_dir.join("manifest.json"), serde_json::to_vec_pretty(&manifest).unwrap_or_default())?;
    Ok(manifest)
}

/// Installs a prepared build: its profiles through misagent, then the app as an upgrade through
/// installation_proxy (Poki's data stays). iOS ends Poki when the new copy lands.
async fn install(request: &Value, reporter: &Reporter) -> Out {
    let phone: Phone = serde_json::from_value(request.clone()).map_err(|e| fail(e.to_string(), "config"))?;
    let manifest_path = PathBuf::from(str_of(request, "manifest")?);
    let manifest: Value = serde_json::from_slice(&std::fs::read(&manifest_path)?).map_err(|e| fail(e.to_string(), "config"))?;
    let ipa = PathBuf::from(str_of(&manifest, "ipa")?);
    let mut device = phone.open().await?;

    reporter.step("profiles", "Installing the provisioning profiles");
    let profiles: Vec<String> = manifest["profiles"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
    {
        let mut misagent: MisagentClient = device.connect().await?;
        for (i, p) in profiles.iter().enumerate() {
            misagent.install(std::fs::read(p)?).await.map_err(|e| fail(format!("The iPhone refused a provisioning profile: {e}"), "device"))?;
            reporter.part("profiles", (i + 1) as f64 / profiles.len().max(1) as f64, None);
        }
    }
    reporter.done("profiles", None);

    reporter.step("install", "Updating Poki");
    let r = reporter.clone();
    let cb = move |(percent, _): (u64, ())| {
        let r = r.clone();
        async move { r.part("install", percent as f64 / 100.0, None) }
    };
    let work = installation::upgrade_package_with_callback_rsd(&mut device.adapter, &mut device.rsd, &ipa, None, cb, ());
    match tokio::time::timeout(Duration::from_secs(600), work).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            let text = e.to_string();
            let message = if text.contains("ApplicationVerificationFailed") {
                "The iPhone did not accept the new signature. Check that Developer Mode is on, then prepare the build again.".to_string()
            } else {
                format!("The update did not install: {text}")
            };
            return Err(fail(message, "device"));
        }
        Err(_) => return Err(fail("The iPhone stopped answering while installing. Try again.", "device")),
    }
    reporter.done("install", None);
    Ok(json!({"installed": true}))
}

#[cfg(test)]
mod installed_tests {
    use super::*;

    #[test]
    fn entries_keep_id_and_names_and_skip_ones_without_an_id() {
        let app = |pairs: &[(&str, &str)]| {
            let mut d = plist::Dictionary::new();
            for (k, v) in pairs {
                d.insert((*k).into(), plist::Value::String((*v).into()));
            }
            plist::Value::Dictionary(d)
        };
        let list = vec![
            app(&[("CFBundleIdentifier", "com.taobao.taobao4iphone"), ("CFBundleDisplayName", "淘宝"), ("CFBundleName", "Taobao4iPhone"), ("ApplicationType", "User")]),
            app(&[("CFBundleIdentifier", "com.meituan.imeituan"), ("CFBundleDisplayName", " ")]),
            app(&[("CFBundleDisplayName", "No id")]),
        ];
        let out = installed_entries(&list);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], json!({"id": "com.taobao.taobao4iphone", "name": "淘宝", "bundle_name": "Taobao4iPhone", "type": "User"}));
        assert_eq!(out[1], json!({"id": "com.meituan.imeituan", "name": null, "bundle_name": null, "type": null}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[derive(Default)]
    struct TestVault(Mutex<HashMap<String, Vec<u8>>>);

    impl core::vault::Vault for TestVault {
        fn get(&self, name: &str) -> core::Result<Option<Vec<u8>>> {
            Ok(self.0.lock().unwrap().get(name).cloned())
        }
        fn set(&self, name: &str, value: &[u8]) -> core::Result<()> {
            self.0.lock().unwrap().insert(name.to_string(), value.to_vec());
            Ok(())
        }
        fn delete(&self, name: &str) -> core::Result<()> {
            self.0.lock().unwrap().remove(name);
            Ok(())
        }
    }

    #[test]
    fn concurrent_request_completion_does_not_drop_in_flight_code_request_log() {
        crate::pin_crypto_provider();
        let _ = core::vault::install(Box::new(TestVault::default()));
        let vault = core::vault::installed().expect("vault installed");

        let dir = std::env::temp_dir().join(format!("poki-signer-log-scope-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
        rt.block_on(async {
            handle(json!({"op": "configure", "home": dir.to_string_lossy()}), |_| {}).await.unwrap();

            let entered = Arc::new(tokio::sync::Notify::new());
            let release = Arc::new(tokio::sync::Notify::new());
            let entered_srv = entered.clone();
            let release_srv = release.clone();

            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            tokio::spawn(async move {
                while let Ok((mut stream, _)) = listener.accept().await {
                    let entered_srv = entered_srv.clone();
                    let release_srv = release_srv.clone();
                    tokio::spawn(async move {
                        let mut buf = [0u8; 2048];
                        let n = stream.read(&mut buf).await.unwrap_or(0);
                        let req = String::from_utf8_lossy(&buf[..n]);
                        let body = if req.starts_with("GET /v3/client_info") {
                            entered_srv.notify_waiters();
                            release_srv.notified().await;
                            r#"{"client_info":"<Mac15,7>","user_agent":"akd/1.0"}"#
                        } else {
                            "{\"result\":\"Headers\",\"X-Apple-I-MD-M\":\"mid-1\",\"X-Apple-I-MD\":\"otp\\nbreak\",\"X-Apple-I-MD-RINFO\":\"17106176\"}"
                        };
                        let reply = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = stream.write_all(reply.as_bytes()).await;
                    });
                }
            });

            use sha2::{Digest, Sha256};
            let mut hash = [0u8; 6];
            hash.copy_from_slice(&Sha256::digest(url.as_bytes())[..6]);
            let tag: String = hash.iter().map(|b| format!("{b:02x}")).collect();
            let client_info = core::apple::anisette::CLIENT_INFO_OVERRIDE.map(|(c, _)| c.to_string());
            let ani_state = core::apple::anisette::remote::State {
                keychain_identifier: vec![3u8; 16],
                adi_pb: Some(b"provisioned-adi".to_vec()),
                client_info,
            };
            vault.set(&format!("anisette-{tag}"), &serde_json::to_vec(&ani_state).unwrap()).unwrap();

            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
            let pending_json = serde_json::json!({
                "apple_id": "person@example.com",
                "password": "synthetic-secret-password",
                "keep_password": false,
                "session": {
                    "apple_id": "person@example.com",
                    "adsid": "000123-abc",
                    "gs_idms_token": "idms-tok-1",
                    "first_name": "Test",
                    "last_name": "Person",
                    "sk": "Bw==",
                    "c": "Yw=="
                },
                "via": "trusted_device",
                "phone_id": 0,
                "anisette": { "kind": "remote", "url": url },
                "created_at": now - 120,
                "last_sent_at": now - 120
            });
            vault.set("pending-sign-in", &serde_json::to_vec(&pending_json).unwrap()).unwrap();
            {
                let mut st = STATE.lock().await;
                st.signer = None;
                st.pending = None;
            }

            let resend_events: Arc<Mutex<Vec<Value>>> = Arc::new(Mutex::new(Vec::new()));
            let resend_events_cb = resend_events.clone();
            let resend_task = tokio::spawn(async move {
                handle(json!({"op": "resend_code"}), move |ev| {
                    resend_events_cb.lock().unwrap().push(ev);
                })
                .await
            });

            // Wait until resend_code is mid-flight, then finish an unrelated concurrent request so its guard drops.
            entered.notified().await;
            let other_events: Arc<Mutex<Vec<Value>>> = Arc::new(Mutex::new(Vec::new()));
            let other_events_cb = other_events.clone();
            handle(json!({"op": "set_channel", "channel": "beta"}), move |ev| {
                other_events_cb.lock().unwrap().push(ev);
            })
            .await
            .unwrap();

            release.notify_waiters();
            let _ = resend_task.await.unwrap();

            let _ = std::fs::remove_dir_all(&dir);
            let logs: Vec<String> = resend_events
                .lock()
                .unwrap()
                .iter()
                .filter(|v| v["event"] == "log")
                .filter_map(|v| v["line"].as_str().map(String::from))
                .collect();
            assert_eq!(
                logs,
                vec!["2fa-code-request path=ask_trusted_device caller=resend_code".to_string()],
                "finishing a concurrent request must not clear the in-flight request's log emitter"
            );
            assert!(
                other_events.lock().unwrap().iter().all(|v| v["event"] != "log"),
                "unrelated concurrent request must not receive another request's 2fa-code-request log"
            );
        });
    }
}
