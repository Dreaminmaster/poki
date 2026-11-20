//! The Mac app never stops its helper by signal: when the app quits, the helper's stdin closes.
//! The helper has to end then, or every quit leaves a background process behind.
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[tokio::test]
async fn the_helper_exits_once_the_app_closes_its_input() {
    let home = std::env::temp_dir().join(format!("poki-bridge-exit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_poki-setup-bridge"))
        .env("POKI_SETUP_HOME", &home)
        .env("POKI_SETUP_FILE_SECRETS", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap()).lines();
    let ready = output.next_line().await.unwrap().unwrap();
    assert!(ready.contains(r#""event":"ready""#), "{ready}");
    input.write_all(b"{\"id\":1,\"cmd\":\"ping\"}\n").await.unwrap();
    let pong = output.next_line().await.unwrap().unwrap();
    assert!(pong.contains(r#""ok":"pong""#), "{pong}");

    drop(input);
    let status = tokio::time::timeout(Duration::from_secs(1), child.wait()).await.expect("the helper is still running 1 s after its input closed").unwrap();
    assert!(status.success(), "{status}");
    let _ = std::fs::remove_dir_all(&home);
}
