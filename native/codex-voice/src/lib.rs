#![recursion_limit = "256"]

use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::Context;
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
            let stage = if let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                runtime
                    .block_on(serve(home, incoming, emit))
                    .err()
                    .map(|error| error.to_string())
            } else {
                Some("async runtime".to_owned())
            };
            if let Ok(mut slot) = REQUESTS.lock() {
                *slot = None;
            }
            publish(
                emit,
                json!({"method": "poki/runtime/closed", "params": {"stage": stage}}),
            );
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

fn codex_overrides() -> Vec<(String, toml::Value)> {
    vec![
        (
            "cli_auth_credentials_store".into(),
            toml::Value::String("keyring".into()),
        ),
        ("features.shell_tool".into(), toml::Value::Boolean(false)),
        ("features.plugins".into(), toml::Value::Boolean(false)),
        ("features.apps".into(), toml::Value::Boolean(false)),
        ("features.tool_suggest".into(), toml::Value::Boolean(false)),
        ("features.multi_agent".into(), toml::Value::Boolean(false)),
        ("agents.enabled".into(), toml::Value::Boolean(false)),
        ("features.view_image".into(), toml::Value::Boolean(false)),
        ("features.sleep_tool".into(), toml::Value::Boolean(false)),
        (
            "features.image_generation".into(),
            toml::Value::Boolean(false),
        ),
        ("features.hooks".into(), toml::Value::Boolean(false)),
        ("web_search".into(), toml::Value::String("disabled".into())),
        (
            "tools.experimental_request_user_input.enabled".into(),
            toml::Value::Boolean(false),
        ),
        ("skills.bundled.enabled".into(), toml::Value::Boolean(false)),
        (
            "skills.include_instructions".into(),
            toml::Value::Boolean(false),
        ),
        (
            "features.secret_auth_storage".into(),
            toml::Value::Boolean(false),
        ),
    ]
}

async fn serve(
    home: PathBuf,
    mut incoming: mpsc::Receiver<Value>,
    emit: Event,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(&home).context("app support directory")?;
    let overrides = codex_overrides();
    let loader = LoaderOverrides::default();
    let mut config = ConfigBuilder::default()
        .codex_home(home.clone())
        .fallback_cwd(Some(home.clone()))
        .without_project_context()
        .cli_overrides(overrides.clone())
        .build()
        .await
        .context("Codex configuration")?;
    let network = in_process::EmbeddedNetworkPolicy::load(&loader).await;
    network.activate(&mut config);
    let environments =
        EnvironmentManager::without_environments(network.bind(config.http_client_factory()));
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
    .await
    .context("app server initialization")?;
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
                    || method == "account/login/start" && !matches!(
                        message.pointer("/params/type").and_then(Value::as_str),
                        Some("chatgpt" | "chatgptDeviceCode")
                    )
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
                        Ok(Err(error)) => json!({"id": id, "error": {
                            "code": error.code,
                            "kind": auth_failure_kind(&error.message),
                        }}),
                        Err(_) => json!({"id": id, "error": {"code": -32000}}),
                    };
                    publish(emit, response);
                });
            }
            event = client.next_event() => match event {
                Some(InProcessServerEvent::ServerNotification(event)) => {
                    let Ok(mut value) = serde_json::to_value(event) else { continue; };
                    let method = value
                        .get("method")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    let realtime_error = method == "thread/realtime/error";
                    if method.starts_with("thread/realtime/")
                        || matches!(method.as_str(), "account/login/completed" | "account/updated")
                    {
                        if let Some(params) = value.get_mut("params").and_then(Value::as_object_mut)
                        {
                            if let Some(Value::String(message)) = params.remove("message") {
                                if let Some(kind) = auth_failure_kind(&message) {
                                    params.insert("kind".into(), json!(kind));
                                }
                                if realtime_error {
                                    params.insert(
                                        "diagnostic".into(),
                                        json!(realtime_error_diagnostic(&message)),
                                    );
                                }
                            }
                            params.remove("error");
                            if method == "thread/realtime/itemAdded" {
                                let item_type = params
                                    .get("item")
                                    .and_then(|item| item.get("type"))
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_owned();
                                params.insert("item".into(), json!({"type": item_type}));
                            }
                        }
                        publish(emit, value);
                    } else if let Some(summary) = backend_diagnostic_notification(&method, &value) {
                        publish(emit, summary);
                    }
                }
                Some(InProcessServerEvent::ServerRequest(event)) => {
                    let Ok(value) = serde_json::to_value(event) else { continue; };
                    let method = value
                        .get("method")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    if method == "item/tool/call" {
                        publish(emit, value);
                    } else {
                        if let Some(id) = value
                            .get("id")
                            .and_then(|id| serde_json::from_value(id.clone()).ok())
                        {
                            let _ = sender.fail_server_request(
                                id,
                                JSONRPCErrorError {
                                    code: -32601,
                                    message: "Tool unavailable".into(),
                                    data: None,
                                },
                            );
                        }
                        if let Some(thread_id) =
                            value.pointer("/params/threadId").and_then(Value::as_str)
                        {
                            publish(
                                emit,
                                json!({
                                    "method": "poki/tool/rejected",
                                    "params": {
                                        "threadId": thread_id,
                                        "requestMethod": method,
                                        "reason": "unsupportedServerRequest",
                                    }
                                }),
                            );
                        }
                    }
                }
                Some(InProcessServerEvent::Lagged { .. }) | None => break,
            },
        }
    }
    client.shutdown().await.context("app server shutdown")?;
    Ok(())
}

fn backend_diagnostic_notification(method: &str, value: &Value) -> Option<Value> {
    let thread_id = value.pointer("/params/threadId").and_then(Value::as_str)?;
    match method {
        "turn/started" => Some(json!({
            "method": "poki/backend/turnStarted",
            "params": { "threadId": thread_id }
        })),
        "turn/completed" => {
            let status = value
                .pointer("/params/turn/status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            Some(json!({
                "method": "poki/backend/turnCompleted",
                "params": { "threadId": thread_id, "status": status }
            }))
        }
        "error" => {
            let will_retry = value
                .pointer("/params/willRetry")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let code = match value.pointer("/params/error/codexErrorInfo") {
                Some(Value::String(name)) => name.as_str(),
                Some(Value::Object(map)) => map.keys().next().map(String::as_str).unwrap_or("unknown"),
                _ => "unknown",
            };
            let kind = value
                .pointer("/params/error/message")
                .and_then(Value::as_str)
                .and_then(auth_failure_kind);
            let mut params = json!({
                "threadId": thread_id,
                "willRetry": will_retry,
                "code": code,
            });
            if let (Some(kind), Some(obj)) = (kind, params.as_object_mut()) {
                obj.insert("kind".into(), json!(kind));
            }
            Some(json!({
                "method": "poki/backend/error",
                "params": params
            }))
        }
        _ => None,
    }
}

fn auth_failure_kind(message: &str) -> Option<&'static str> {
    let message = message.to_ascii_lowercase();
    [
        "401 unauthorized",
        "status code 401",
        "status: 401",
        "(401)",
        "invalid_grant",
        "invalid_token",
        "token expired",
        "token has expired",
        "access token could not be refreshed",
        "sign in again",
    ]
    .iter()
    .any(|marker| message.contains(marker))
    .then_some("signInRequired")
}

fn realtime_error_diagnostic(message: &str) -> String {
    // Server messages can include account details, URLs, or credentials. Keep only known
    // transport errors verbatim and copy only the status number from a failed upgrade.
    const STREAM: &str = "stream disconnected before completion: ";
    const CONNECT: &str = "failed to connect realtime websocket: ";
    let cause = message.strip_prefix(STREAM).unwrap_or(message);
    if let Some(transport) = cause.strip_prefix(CONNECT) {
        if matches!(transport,
            "IO error: no native root CA certificates found (errors: [])"
                | "IO error: invalid peer certificate: UnknownIssuer"
                | "IO error: operation timed out"
                | "IO error: connection reset by peer"
        ) {
            return message.to_owned();
        }
        return "failed to connect realtime websocket (transport details withheld)".into();
    }
    if cause.starts_with("realtime websocket closed unexpectedly without a status code") {
        return "realtime websocket closed unexpectedly without a status code".into();
    }
    if let Some((code, _)) = cause.strip_prefix("realtime websocket closed unexpectedly: code=")
        .and_then(|detail| detail.split_once(" reason="))
    {
        if matches!(code, "Away" | "Protocol" | "Unsupported" | "Abnormal" | "Invalid"
            | "Policy" | "Size" | "Extension" | "Error" | "Restart" | "Again") {
            return format!("realtime websocket closed unexpectedly: code={code}");
        }
        return "realtime websocket closed unexpectedly".into();
    }
    if let Some(status) = cause.strip_prefix("unexpected status ")
        .and_then(|text| text.split_whitespace().next())
        .and_then(|text| text.parse::<u16>().ok())
        .filter(|status| (400..=599).contains(status))
    {
        return format!("unexpected status {status} in realtime voice");
    }
    "realtime voice error (upstream details withheld)".into()
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
