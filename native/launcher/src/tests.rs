use super::*;
use crate::device::{Device, LOOPBACK_FIX, PAIRING_FIX, PAIRING_PORT_FIX, Pairing, PairingKind};
use idevice::remote_pairing::RpPairingFile;
use serde_json::json;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

fn temp(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("poki-launcher-{}-{name}", std::process::id()))
}

fn wait_for(events: &Arc<Mutex<Vec<Value>>>, seconds: u64, check: impl Fn(&[Value]) -> bool) -> bool {
    let until = Instant::now() + Duration::from_secs(seconds);
    while Instant::now() < until {
        if check(&events.lock().unwrap()) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn config_defaults_to_the_loopback_and_local_runner() {
    let config: Config = serde_json::from_str(r#"{"pairing_file": "/p"}"#).unwrap();
    assert_eq!(config.device_address.to_string(), "10.7.0.1");
    assert_eq!(config.wda_host.to_string(), "127.0.0.1");
    assert_eq!(config.wda_port, 8100);
}

#[test]
fn standalone_runner_listens_only_on_the_phone_loopback() {
    let mut environment = plist::Dictionary::new();
    environment.insert("USE_IP".into(), "0.0.0.0".into());
    launch::secure_runner_environment(&mut environment);
    assert_eq!(environment.get("POKI_LAUNCHER").and_then(plist::Value::as_string), Some("1"));
    assert_eq!(environment.get("USE_IP").and_then(plist::Value::as_string), Some("127.0.0.1"));
}

#[test]
fn pairing_files_of_either_kind_are_told_apart() {
    let path = temp("rp.plist");
    std::fs::write(&path, RpPairingFile::generate("Poki").to_bytes()).unwrap();
    assert_eq!(Pairing::read(&path, None).unwrap().kind(), PairingKind::Remote);
    std::fs::write(&path, b"<plist><dict><key>x</key><string>y</string></dict></plist>").unwrap();
    let failure = Pairing::read(&path, None).err().unwrap();
    assert_eq!(failure.fix.as_deref(), Some(PAIRING_FIX));
    std::fs::remove_file(&path).unwrap();
}

/// The tests that need 127.0.0.1:49152 free, or that listen on it, take turns.
static PORT_49152_TAKEN: Mutex<()> = Mutex::new(());

/// The loopback is on and the phone's remote pairing service is not on the port Poki uses: iOS
/// answers the connection with a refusal. That is not "turn on the loopback" (the owner's loopback
/// works); the launcher says the port moved, and keeps trying until the app sets the port it found.
#[test]
fn a_refused_port_is_not_called_a_loopback_that_is_off_and_it_keeps_trying() {
    let _port = PORT_49152_TAKEN.lock().unwrap_or_else(|e| e.into_inner());
    let path = temp("rp2.plist");
    std::fs::write(&path, RpPairingFile::generate("Poki").to_bytes()).unwrap();
    // Nothing listens on 127.0.0.1:49152 here, and the address answers: a refusal.
    let config: Config = serde_json::from_value(json!({"pairing_file": path, "device_address": "127.0.0.1"})).unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = events.clone();
    let launcher = Arc::new(Launcher::new(config, Box::new(move |e| sink.lock().unwrap().push(e))));
    launcher.clone().start();
    assert!(wait_for(&events, 5, |e| e.iter().any(|v| v["state"] == "waiting_network" && v["fix"] == PAIRING_PORT_FIX && v["code"] == "pairing_port")));
    let said = events.lock().unwrap().iter().find(|v| v["code"] == "pairing_port").unwrap()["detail"].as_str().unwrap().to_string();
    assert!(said.contains("127.0.0.1:49152") && !said.contains("Is the loopback on"), "{said}");
    // A restart cuts the backoff short: a second attempt comes at once.
    launcher.restart();
    assert!(wait_for(&events, 3, |e| e.iter().filter(|v| v["state"] == "connecting").count() >= 2));
    launcher.stop();
    assert_eq!(launcher.status()["state"], "idle");
    std::fs::remove_file(&path).unwrap();
}

/// An address that does not answer at all is still the loopback's to fix.
#[test]
fn an_address_that_does_not_answer_is_still_a_loopback_that_is_off() {
    let failure = crate::device::remote_failure(crate::remote::RemoteError { stage: crate::remote::Stage::Connect, detail: "10.7.0.1:49152: Network is unreachable (os error 51)".into() });
    assert_eq!(failure.fix.as_deref(), Some(LOOPBACK_FIX));
    assert_eq!(failure.code, Some("loopback"));
}

/// iOS moved the remote pairing service off 49152 (it names the port in Bonjour). Once the app sets
/// the port it found, the connection goes there: 49152 is refused here, and the moved service is
/// reached (it closes the connection, so the failure is the handshake, past the connect).
#[tokio::test]
async fn the_port_the_app_found_is_the_one_connected_to() {
    let _port = PORT_49152_TAKEN.lock().unwrap_or_else(|e| e.into_inner());
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let moved = listener.local_addr().unwrap().port();
    assert_ne!(moved, crate::remote::REMOTE_PAIRING_PORT);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            drop(stream);
        }
    });
    let path = temp("rp-moved.plist");
    std::fs::write(&path, RpPairingFile::generate("Poki").to_bytes()).unwrap();
    let mut pairing = Pairing::read(&path, None).unwrap();
    let address: std::net::IpAddr = "127.0.0.1".parse().unwrap();
    let before = Device::open(address, &mut pairing, Duration::from_secs(5)).await.err().expect("no phone here");
    assert_eq!(before.code, Some("pairing_port"), "{}", before.detail);
    poki_set_remote_pairing_port(moved);
    let after = Device::open(address, &mut pairing, Duration::from_secs(5)).await.err().expect("no phone here");
    poki_set_remote_pairing_port(0);
    std::fs::remove_file(&path).unwrap();
    assert_eq!(crate::remote::port(), crate::remote::REMOTE_PAIRING_PORT);
    assert_eq!(after.code, Some("handshake"), "{}", after.detail);
    assert!(after.detail.starts_with("remote pairing handshake failed"), "{}", after.detail);
}

/// GitHub issue 69: the loopback takes the connection, then the phone's remote pairing service never
/// answers. Developer Mode is on (it cannot go off without a restart), so that is not the fix, and
/// the pairing was never checked, so the app must not read it as refused.
#[tokio::test]
async fn a_remote_pairing_service_that_takes_the_connection_and_never_answers_is_not_called_developer_mode() {
    let _port = PORT_49152_TAKEN.lock().unwrap_or_else(|e| e.into_inner());
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", crate::remote::REMOTE_PAIRING_PORT)).await.unwrap();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            drop(stream);
        }
    });
    let path = temp("rp-silent.plist");
    std::fs::write(&path, RpPairingFile::generate("Poki").to_bytes()).unwrap();
    let mut pairing = Pairing::read(&path, None).unwrap();
    let failure = match Device::open("127.0.0.1".parse().unwrap(), &mut pairing, Duration::from_secs(5)).await {
        Ok(_) => panic!("a service that closes every connection opened a tunnel"),
        Err(failure) => failure,
    };
    std::fs::remove_file(&path).unwrap();
    assert!(failure.detail.starts_with("remote pairing handshake failed"), "{}", failure.detail);
    let fix = failure.fix.expect("the owner is told what to do");
    assert!(!fix.contains("Developer Mode"), "{fix}");
    // The app reads "Pair again" as the phone refusing the pairing (AppModel.verifyPairing, runnerChanged).
    assert!(!fix.contains("Pair again"), "{fix}");
}

#[test]
fn status_is_true_only_for_a_200() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for answer in [&b"HTTP/1.1 200 OK\r\n\r\n{}"[..], &b"HTTP/1.1 500 Oops\r\n\r\n"[..]] {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut buffer = [0u8; 256];
                let _ = stream.read(&mut buffer).await;
                stream.write_all(answer).await.unwrap();
            }
        });
        assert!(launch::status(address, Duration::from_secs(1)).await);
        assert!(!launch::status(address, Duration::from_secs(1)).await);
        // Nothing listening at all.
        assert!(!launch::status("127.0.0.1:9".parse().unwrap(), Duration::from_millis(300)).await);
    });
}

#[test]
fn pairing_advertises_what_bonjour_needs() {
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = events.clone();
    let config = pair::PairConfig { host_name: "Poki".into(), out_path: temp("paired.plist"), identity_path: Some(temp("identity")) };
    let task = runtime().spawn(pair::run(config, move |e| sink.lock().unwrap().push(e)));
    assert!(wait_for(&events, 3, |e| e.iter().any(|v| v["event"] == "advertise")));
    let advertise = events.lock().unwrap()[0].clone();
    assert_eq!(advertise["service_type"], "_remotepairing-pairable-host._tcp");
    assert!(advertise["port"].as_u64().unwrap() > 0);
    for key in ["name", "identifier", "authTag", "model"] {
        assert!(advertise["txt"][key].is_string(), "{key}");
    }
    assert_eq!(advertise["instance"], advertise["txt"]["identifier"]);
    task.abort();
    // The host identity is kept, so the phone recognizes Poki next time.
    assert_eq!(std::fs::read(temp("identity")).unwrap().len(), 16);
    let _ = std::fs::remove_file(temp("identity"));
}

/// The person starts pairing, then gives up in Settings: the pairing ends by itself, so the app stops
/// its silent-audio keep-alive and its Bonjour service instead of running in the background for good.
#[tokio::test(start_paused = true)]
async fn an_abandoned_pairing_ends_by_itself_within_ten_minutes() {
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = events.clone();
    let config = pair::PairConfig { host_name: "Poki".into(), out_path: temp("abandoned.plist"), identity_path: None };
    let ended = tokio::time::timeout(Duration::from_secs(10 * 60 + 1), pair::run(config, move |e| sink.lock().unwrap().push(e))).await;
    assert!(ended.is_ok(), "the pairing was still waiting for the phone after ten minutes");
    let events = events.lock().unwrap();
    assert_eq!(events.first().unwrap()["event"], "advertise");
    assert_eq!(events.last().unwrap()["event"], "failed");
}

#[test]
fn an_unreadable_config_gives_null() {
    extern "C" fn ignore(_: *mut c_void, _: *const c_char) {}
    let bad = CString::new("{").unwrap();
    assert!(unsafe { poki_launcher_new(bad.as_ptr(), ignore, std::ptr::null_mut()) }.is_null());
    let good = CString::new(r#"{"pairing_file": "/nowhere"}"#).unwrap();
    let launcher = unsafe { poki_launcher_new(good.as_ptr(), ignore, std::ptr::null_mut()) };
    assert!(!launcher.is_null());
    let status = unsafe { poki_launcher_status(launcher) };
    assert!(unsafe { CStr::from_ptr(status) }.to_str().unwrap().contains("idle"));
    unsafe {
        poki_string_free(status);
        poki_launcher_free(launcher);
    }
}

#[test]
fn disk_image_failures_name_their_own_fix() {
    use crate::ddi::classify;
    use idevice::IdeviceError;
    use idevice::cryptexd::CryptexdError;
    let refused = classify(&IdeviceError::UnexpectedResponse("TSS server responded with non-success status (STATUS=94&MESSAGE=This device isn't eligible)".into()));
    assert_eq!(refused.code, Some("ddi_refused"));
    let bad = classify(&IdeviceError::Cryptexd(CryptexdError::BadDdiBundle("no trustcache".into())));
    assert_eq!(bad.code, Some("ddi_bad"));
    let network = classify(&IdeviceError::Http("connection refused".into()));
    assert_eq!(network.code, Some("network"));
    assert_eq!(network.fix.as_deref(), Some(crate::device::NETWORK_FIX));
}

/// GitHub issue 69 and ESP-225: a failure on the way to the phone is not Developer Mode. Only the
/// phone saying so (DeveloperModeStatus false, or its "Developer mode is not enabled" error) is.
/// Anything else that cannot be told apart is "can't reach this iPhone", with the loopback first.
#[test]
fn only_the_phone_saying_so_is_called_developer_mode_off() {
    use crate::remote::{RemoteError, Stage};
    use idevice::IdeviceError;
    let says_developer_mode_off = |failure: &crate::device::Failure| {
        failure.code == Some("developer_mode") || failure.fix.as_deref().is_some_and(|fix| fix.starts_with("Turn on Developer Mode"))
    };
    for stage in [Stage::Connect, Stage::NotListening, Stage::Handshake, Stage::PairVerify, Stage::Listener, Stage::Tunnel, Stage::Rsd] {
        let failure = crate::device::remote_failure(RemoteError { stage, detail: "device socket io failed".into() });
        assert!(!says_developer_mode_off(&failure), "{stage:?}: {:?}", failure.fix);
    }
    for stage in [Stage::Listener, Stage::Tunnel, Stage::Rsd] {
        let failure = crate::device::remote_failure(RemoteError { stage, detail: "x".into() });
        assert_eq!(failure.code, Some("unreachable"), "{stage:?}");
        let fix = failure.fix.unwrap();
        let order: Vec<usize> = ["Setup › Loopback", "Setup › Pairing", "Developer Mode"].iter().map(|step| fix.find(step).unwrap_or_else(|| panic!("{step} in {fix}"))).collect();
        assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "loopback, then pairing, then Developer Mode: {fix}");
    }

    assert!(says_developer_mode_off(&crate::ddi::without_cryptexd(Some(false))));
    assert!(!says_developer_mode_off(&crate::ddi::without_cryptexd(Some(true))));
    assert!(!says_developer_mode_off(&crate::ddi::without_cryptexd(None)));

    // The runner's session ends after the disk image mounted, which needs Developer Mode on.
    assert!(!says_developer_mode_off(&launch::ended_before_ready(Ok(()))));
    assert!(!says_developer_mode_off(&launch::ended_before_ready(Err(IdeviceError::UnexpectedResponse("test failed".into())))));
    assert!(says_developer_mode_off(&launch::ended_before_ready(Err(IdeviceError::DeveloperModeNotEnabled))));
}
