//! The Poki Setup window: Tauri over poki-setup-core. Commands are thin: each one calls the core
//! and turns its `Progress` into events the page draws.
mod commands;

use std::sync::Arc;
use tauri::{Emitter, Manager};
use tokio::sync::Mutex;

/// What lives for the whole app: the signed-in account, a sign-in waiting for its code, the
/// pairing hand-off server, the log stream.
pub struct State {
    pub signer: Mutex<Option<poki_setup_core::setup::Signer>>,
    pub pending: Mutex<Option<poki_setup_core::apple::gsa::Pending>>,
    pub handoff: Mutex<Option<poki_setup_core::pairshare::Server>>,
    pub logs: Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub busy: Mutex<bool>,
}

pub type Shared = Arc<State>;

pub fn run() {
    let state: Shared = Arc::new(State { signer: Mutex::new(None), pending: Mutex::new(None), handoff: Mutex::new(None), logs: Mutex::new(None), busy: Mutex::new(false) });
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .target(tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Folder { path: poki_setup_core::paths::log_dir().unwrap_or_else(|_| std::env::temp_dir()), file_name: Some("poki-setup".into()) }))
                .target(tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout))
                .build(),
        )
        .manage(state.clone())
        .setup(move |app| {
            let _window = app.get_webview_window("main").expect("main window");
            #[cfg(target_os = "macos")]
            {
                use window_vibrancy::{NSVisualEffectMaterial, NSVisualEffectState, apply_vibrancy};
                let _ = apply_vibrancy(&_window, NSVisualEffectMaterial::Sidebar, Some(NSVisualEffectState::Active), None);
            }
            #[cfg(target_os = "windows")]
            {
                let _ = window_vibrancy::apply_mica(&_window, None).or_else(|_| window_vibrancy::apply_acrylic(&_window, Some((10, 60, 160, 160))));
            }
            tray(app)?;
            keeper_loop(app.handle().clone(), state.clone());
            watch_account(app.handle().clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window keeps the app (and the weekly renewal) alive in the menu bar / tray.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::app_info,
            commands::phones,
            commands::pair,
            commands::share_pairing,
            commands::stop_sharing,
            commands::approve_certificate_replacement,
            commands::devmode,
            commands::account,
            commands::sign_in,
            commands::finish_sign_in,
            commands::sign_out,
            commands::teams,
            commands::choose_team,
            commands::set_anisette,
            commands::install,
            commands::records,
            commands::renew,
            commands::forget_phone,
            commands::latest_release,
            commands::relay_state,
            commands::relay_worker,
            commands::relay_token_saved,
            commands::relay_forget_token,
            commands::relay_accounts,
            commands::relay_deploy,
            commands::relay_check,
            commands::connectors,
            commands::connector_add,
            commands::connector_forget,
            commands::connector_check,
            commands::connector_snippets,
            commands::logs_start,
            commands::logs_stop,
            commands::mount_ddi,
            commands::support_bundle,
            commands::agent_prompt,
            commands::check_update,
            commands::install_update,
            commands::channels,
            commands::set_channel,
            commands::qr_svg,
        ])
        .run(tauri::generate_context!())
        .expect("Poki Setup could not start");
}

fn tray(app: &tauri::App) -> tauri::Result<()> {
    use tauri::menu::{MenuBuilder, MenuItemBuilder};
    use tauri::tray::TrayIconBuilder;
    let open = MenuItemBuilder::with_id("open", "Open Poki Setup").build(app)?;
    let renew = MenuItemBuilder::with_id("renew", "Renew Poki now").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit Poki Setup").build(app)?;
    let menu = MenuBuilder::new(app).item(&open).item(&renew).separator().item(&quit).build()?;
    let mut builder = TrayIconBuilder::with_id("main").menu(&menu).tooltip("Poki Setup").show_menu_on_left_click(true);
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    #[cfg(target_os = "macos")]
    {
        builder = builder.icon_as_template(false);
    }
    builder
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app),
            "renew" => {
                let _ = app.emit("renew-requested", ());
                show_main(app);
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

/// Tells the window whenever any client (this app, the CLI) saved the account, so an open Account
/// page shows a stored sign-in-again state without waiting for its next request.
fn watch_account(app: tauri::AppHandle) {
    let mut seen = poki_setup_core::apple::store::revision();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            let now = poki_setup_core::apple::store::revision();
            if now != seen {
                seen = now;
                let _ = app.emit("account-changed", ());
            }
        }
    });
}

/// Every six hours: when a phone is due and the account can sign without a person, renew it.
fn keeper_loop(app: tauri::AppHandle, state: Shared) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        loop {
            let due = poki_setup_core::keeper::due().unwrap_or_default();
            if !due.is_empty() {
                let _ = app.emit("keeper", serde_json::json!({ "due": due.iter().map(|r| r.udid.clone()).collect::<Vec<_>>() }));
                if !*state.busy.lock().await {
                    let mut guard = state.signer.lock().await;
                    if guard.is_none() {
                        *guard = poki_setup_core::setup::Signer::open().ok();
                    }
                    if let Some(signer) = guard.as_mut() {
                        if signer.account.password.is_some() && signer.pending().is_none() && !signer.is_rate_limited() {
                            let reporter = commands::reporter(&app, "keeper");
                            for (udid, res) in poki_setup_core::setup::renew_due(signer, &reporter).await {
                                if let Err(poki_setup_core::Error::NeedsCode(ref p)) = res {
                                    *state.pending.lock().await = Some((**p).clone());
                                }
                                let _ = app.emit("keeper-result", serde_json::json!({ "udid": udid, "ok": res.is_ok(), "error": res.err().map(|e| e.to_string()) }));
                            }
                        }
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct VecLogger(Arc<Mutex<Vec<String>>>);

    impl log::Log for VecLogger {
        fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
            metadata.level() <= log::Level::Info
        }
        fn log(&self, record: &log::Record<'_>) {
            if self.enabled(record.metadata()) {
                self.0.lock().unwrap().push(format!("{}", record.args()));
            }
        }
        fn flush(&self) {}
    }

    #[test]
    fn tracing_code_requests_bridge_into_log_crate_sink() {
        let captured: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        log::set_boxed_logger(Box::new(VecLogger(captured.clone()))).unwrap();
        log::set_max_level(log::LevelFilter::Info);

        let dir = std::env::temp_dir().join(format!("poki-tauri-log-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        unsafe {
            std::env::set_var("POKI_SETUP_HOME", &dir);
            std::env::set_var("POKI_SETUP_FILE_SECRETS", "1");
        }

        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            tokio::spawn(async move {
                while let Ok((mut stream, _)) = listener.accept().await {
                    let mut buf = [0u8; 2048];
                    let n = stream.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]);
                    let body = if req.starts_with("GET /v3/client_info") {
                        r#"{"client_info":"<Mac15,7>","user_agent":"akd/1.0"}"#
                    } else {
                        // Invalid newline in header halts reqwest locally right after log_code_request, with zero external I/O.
                        "{\"result\":\"Headers\",\"X-Apple-I-MD-M\":\"mid-1\",\"X-Apple-I-MD\":\"otp\\nbreak\",\"X-Apple-I-MD-RINFO\":\"17106176\"}"
                    };
                    let reply = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = stream.write_all(reply.as_bytes()).await;
                }
            });

            use sha2::{Digest, Sha256};
            let mut hash = [0u8; 6];
            hash.copy_from_slice(&Sha256::digest(url.as_bytes())[..6]);
            let tag: String = hash.iter().map(|b| format!("{b:02x}")).collect();
            let ani_dir = poki_setup_core::paths::anisette_dir().unwrap();
            let client_info = poki_setup_core::apple::anisette::CLIENT_INFO_OVERRIDE.map(|(c, _)| c.to_string());
            let state = poki_setup_core::apple::anisette::remote::State {
                keychain_identifier: vec![1u8; 16],
                adi_pb: Some(b"provisioned-adi".to_vec()),
                client_info,
            };
            std::fs::write(ani_dir.join(format!("state-{tag}.json")), serde_json::to_vec(&state).unwrap()).unwrap();

            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
            let pending: poki_setup_core::apple::gsa::Pending = serde_json::from_value(serde_json::json!({
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
            }))
            .unwrap();
            poki_setup_core::apple::store::save_pending(&pending).unwrap();

            let mut signer = poki_setup_core::setup::Signer::open().unwrap();
            let _ = signer.resend_code().await;
        });

        let _ = std::fs::remove_dir_all(&dir);
        let lines = captured.lock().unwrap().clone();
        assert!(
            lines.iter().any(|l| l.contains("2fa-code-request path=ask_trusted_device caller=resend_code")),
            "Tauri log sink must receive tracing 2fa-code-request INFO events, got: {lines:?}"
        );
        for line in &lines {
            assert!(!line.contains("person@example.com") && !line.contains("synthetic-secret-password"));
        }
    }
}
