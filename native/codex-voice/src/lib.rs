#![recursion_limit = "256"]

use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use codex_app_server::in_process::{self, InProcessServerEvent, InProcessStartArgs};
use codex_app_server_protocol::{
    ClientInfo, ClientRequest, InitializeCapabilities, InitializeParams, JSONRPCErrorError,
    RequestId,
};
use codex_config::{CloudConfigBundleLoader, LoaderOverrides, NoopThreadConfigLoader};
use codex_core::config::ConfigBuilder;
use codex_exec_server::EnvironmentManager;
use codex_feedback::CodexFeedback;
use codex_protocol::protocol::SessionSource;
use serde_json::{Value, json};
use tokio::sync::mpsc;

type Event = extern "C" fn(*const c_char);
static REQUESTS: Mutex<Option<mpsc::Sender<Value>>> = Mutex::new(None);

/// Installs a process-lifetime App Server for the app's private support directory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_codex_start(home: *const c_char, emit: Event) -> bool {
    let Some(home) = (unsafe { string(home) }).map(PathBuf::from) else {
        return false;
    };
    let Ok(mut slot) = REQUESTS.lock() else {
        return false;
    };
    if slot.is_some() {
        return true;
    }

    let (requests, incoming) = mpsc::channel(32);
    let worker = std::thread::Builder::new()
        .name("poki-codex-voice".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            if let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                let _ = runtime.block_on(serve(home, incoming, emit));
            }
            if let Ok(mut slot) = REQUESTS.lock() {
                *slot = None;
            }
            publish(emit, json!({"method": "poki/runtime/closed"}));
        });
    if worker.is_err() {
        return false;
    }
    *slot = Some(requests);
    true
}

/// Copies an App Server request or tool response before returning to Swift.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn poki_codex_send(message: *const c_char) -> bool {
    let Some(message) =
        (unsafe { string(message) }).and_then(|text| serde_json::from_str(&text).ok())
    else {
        return false;
    };
    REQUESTS
        .lock()
        .ok()
        .and_then(|slot| slot.clone())
        .is_some_and(|requests| requests.try_send(message).is_ok())
}

async fn serve(
    home: PathBuf,
    mut incoming: mpsc::Receiver<Value>,
    emit: Event,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(&home)?;
    let overrides = vec![
        (
            "cli_auth_credentials_store".into(),
            toml::Value::String("keyring".into()),
        ),
        ("features.shell_tool".into(), toml::Value::Boolean(false)),
        ("features.plugins".into(), toml::Value::Boolean(false)),
    ];
    let loader = LoaderOverrides::default();
    let mut config = ConfigBuilder::default()
        .codex_home(home.clone())
        .fallback_cwd(Some(home.clone()))
        .without_project_context()
        .cli_overrides(overrides.clone())
        .build()
        .await?;
    let network = in_process::EmbeddedNetworkPolicy::load(&loader).await;
    network.activate(&mut config);
    let environments = EnvironmentManager::from_codex_home(
        &home,
        None,
        network.bind(config.http_client_factory()),
    )
    .await?;
    let state_db = codex_core::init_state_db(&config).await;
    let mut client = in_process::start(InProcessStartArgs {
        arg0_paths: Default::default(),
        config: Arc::new(config),
        cli_overrides: overrides,
        loader_overrides: loader,
        strict_config: false,
        cloud_config_bundle: CloudConfigBundleLoader::default(),
        embedded_network_policy: network,
        thread_config_loader: Arc::new(NoopThreadConfigLoader),
        feedback: CodexFeedback::new(),
        log_db: None,
        state_db,
        environment_manager: Arc::new(environments),
        config_warnings: Vec::new(),
        session_source: SessionSource::Custom("poki".into()),
        enable_codex_api_key_env: false,
        initialize: InitializeParams {
            client_info: ClientInfo {
                name: "poki".into(),
                title: Some("Poki".into()),
                version: "1".into(),
            },
            capabilities: Some(InitializeCapabilities {
                experimental_api: true,
                ..Default::default()
            }),
        },
        channel_capacity: 64,
    })
    .await?;
    let sender = client.sender();

    loop {
        tokio::select! {
            Some(message) = incoming.recv() => {
                let Some(id) = message.get("id").cloned() else { continue; };
                if let Some(result) = message.get("result") {
                    if let Ok(id) = serde_json::from_value::<RequestId>(id) {
                        let _ = sender.respond_to_server_request(id, result.clone());
                    }
                    continue;
                }
                let method = message.get("method").and_then(Value::as_str).unwrap_or_default();
                if !matches!(method, "account/read" | "account/login/start" | "account/login/cancel" | "account/logout" | "thread/start" | "thread/realtime/start" | "thread/realtime/stop")
                    || method == "account/login/start" && message.pointer("/params/type").and_then(Value::as_str) != Some("chatgptDeviceCode")
                {
                    publish(emit, json!({"id": id, "error": {"code": -32601}}));
                    continue;
                }
                let Ok(request) = serde_json::from_value::<ClientRequest>(message) else {
                    publish(emit, json!({"id": id, "error": {"code": -32602}}));
                    continue;
                };
                let sender = sender.clone();
                tokio::spawn(async move {
                    let response = match sender.request(request).await {
                        Ok(Ok(result)) => json!({"id": id, "result": result}),
                        Ok(Err(error)) => json!({"id": id, "error": {"code": error.code}}),
                        Err(_) => json!({"id": id, "error": {"code": -32000}}),
                    };
                    publish(emit, response);
                });
            }
            event = client.next_event() => match event {
                Some(InProcessServerEvent::ServerNotification(event)) => {
                    let Ok(mut value) = serde_json::to_value(event) else { continue; };
                    let method = value.get("method").and_then(Value::as_str).unwrap_or_default();
                    if method.starts_with("thread/realtime/") || matches!(method, "account/login/completed" | "account/updated") {
                        if let Some(params) = value.get_mut("params").and_then(Value::as_object_mut) {
                            params.remove("error");
                            params.remove("message");
                        }
                        publish(emit, value);
                    }
                }
                Some(InProcessServerEvent::ServerRequest(event)) => {
                    let Ok(value) = serde_json::to_value(event) else { continue; };
                    if value.get("method").and_then(Value::as_str) == Some("item/tool/call") {
                        publish(emit, value);
                    } else if let Some(id) = value.get("id").and_then(|id| serde_json::from_value(id.clone()).ok()) {
                        let _ = sender.fail_server_request(id, JSONRPCErrorError {
                            code: -32601, message: "Tool unavailable".into(), data: None,
                        });
                    }
                }
                Some(InProcessServerEvent::Lagged { .. }) | None => break,
            },
        }
    }
    client.shutdown().await?;
    Ok(())
}

fn publish(emit: Event, value: Value) {
    if let Ok(value) = CString::new(value.to_string()) {
        emit(value.as_ptr());
    }
}

unsafe fn string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(str::to_owned)
}
