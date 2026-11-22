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
        ("features.goals".into(), toml::Value::Boolean(false)),
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

async fn start_app_server(
    home: &std::path::Path,
    overrides: Vec<(String, toml::Value)>,
) -> anyhow::Result<(
    Arc<codex_core::config::Config>,
    in_process::InProcessClientHandle,
)> {
    std::fs::create_dir_all(home).context("app support directory")?;
    let loader = LoaderOverrides::default();
    let mut config = ConfigBuilder::default()
        .codex_home(home.to_path_buf())
        .fallback_cwd(Some(home.to_path_buf()))
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
    let config = Arc::new(config);
    let client = in_process::start(InProcessStartArgs {
        arg0_paths: Default::default(),
        config: Arc::clone(&config),
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
    Ok((config, client))
}

async fn serve(
    home: PathBuf,
    mut incoming: mpsc::Receiver<Value>,
    emit: Event,
) -> anyhow::Result<()> {
    let (_, mut client) = start_app_server(&home, codex_overrides()).await?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use codex_protocol::config_types::WebSearchMode;
    use std::collections::BTreeSet;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc as std_mpsc;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn read_http_request(stream: &mut std::net::TcpStream) -> Option<(String, Vec<u8>)> {
        let mut reader = BufReader::new(stream);
        let mut request_line = String::new();
        if reader.read_line(&mut request_line).ok()? == 0 {
            return None;
        }
        let mut content_length: Option<usize> = None;
        let mut chunked = false;
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).ok()? == 0 {
                break;
            }
            if line == "\r\n" || line == "\n" {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                let name = name.trim().to_ascii_lowercase();
                let value = value.trim();
                if name == "content-length" {
                    content_length = value.parse::<usize>().ok();
                } else if name == "transfer-encoding"
                    && value.to_ascii_lowercase().contains("chunked")
                {
                    chunked = true;
                }
            }
        }
        let body = if chunked {
            let mut decoded = Vec::new();
            loop {
                let mut size_line = String::new();
                if reader.read_line(&mut size_line).ok()? == 0 {
                    break;
                }
                let size_hex = size_line.split(';').next().unwrap_or("").trim();
                let size = usize::from_str_radix(size_hex, 16).ok()?;
                if size == 0 {
                    let mut trailing = String::new();
                    let _ = reader.read_line(&mut trailing);
                    break;
                }
                let mut chunk = vec![0u8; size];
                reader.read_exact(&mut chunk).ok()?;
                decoded.extend_from_slice(&chunk);
                let mut crlf = [0u8; 2];
                let _ = reader.read_exact(&mut crlf);
            }
            decoded
        } else if let Some(len) = content_length {
            let mut buf = vec![0u8; len];
            reader.read_exact(&mut buf).ok()?;
            buf
        } else {
            Vec::new()
        };
        Some((request_line, body))
    }

    fn spawn_mock_responses_server() -> (String, std_mpsc::Receiver<Value>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let addr = listener.local_addr().expect("local addr");
        let (tx, rx) = std_mpsc::channel();
        std::thread::spawn(move || {
            for incoming in listener.incoming() {
                let Ok(mut stream) = incoming else { break };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                let Some((request_line, body)) = read_http_request(&mut stream) else {
                    continue;
                };
                if request_line.starts_with("POST ") && request_line.contains("/responses") {
                    if let Ok(json) = serde_json::from_slice::<Value>(&body) {
                        let _ = tx.send(json);
                    }
                    let sse = concat!(
                        "event: response.completed\n",
                        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\",\"output\":[]}}\n\n"
                    );
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        sse.len(),
                        sse
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.flush();
                    break;
                } else {
                    let payload = "{}";
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        payload.len(),
                        payload
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.flush();
                }
            }
        });
        (format!("http://{addr}/v1"), rx)
    }

    fn collect_tool_names(request_body: &Value) -> BTreeSet<String> {
        fn record_tool(tool: &Value, names: &mut BTreeSet<String>) {
            if let Some(name) = tool.get("name").and_then(Value::as_str) {
                names.insert(name.to_owned());
            } else if let Some(kind) = tool.get("type").and_then(Value::as_str) {
                names.insert(kind.to_owned());
            }
            if let Some(description) = tool.get("description").and_then(Value::as_str) {
                for line in description.lines() {
                    if let Some(rest) = line.strip_prefix("### `")
                        && let Some(declared) = rest.strip_suffix('`')
                    {
                        names.insert(declared.to_owned());
                    }
                }
            }
            if let Some(nested) = tool.get("tools").and_then(Value::as_array) {
                for item in nested {
                    record_tool(item, names);
                }
            }
        }

        let mut names = BTreeSet::new();
        if let Some(tools) = request_body.get("tools").and_then(Value::as_array) {
            for tool in tools {
                record_tool(tool, &mut names);
            }
        }
        if let Some(input) = request_body.get("input").and_then(Value::as_array) {
            for item in input {
                if let Some(tools) = item.get("tools").and_then(Value::as_array) {
                    for tool in tools {
                        record_tool(tool, &mut names);
                    }
                }
            }
        }
        names
    }

    #[test]
    fn subscription_voice_session_disables_unrelated_tools_and_exposes_phone_tools() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_stack_size(16 * 1024 * 1024)
            .enable_all()
            .build()
            .expect("tokio runtime");
        let handle = runtime.spawn(async {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos();
            let home = std::env::temp_dir().join(format!(
                "poki-codex-voice-tools-test-{}-{unique}",
                std::process::id()
            ));
            std::fs::create_dir_all(&home).expect("create temp home");
            let (base_url, captured_rx) = spawn_mock_responses_server();
            std::fs::write(
                home.join("config.toml"),
                format!(
                    concat!(
                        "model = \"gpt-6-luna\"\n",
                        "model_provider = \"mock_provider\"\n\n",
                        "[model_providers.mock_provider]\n",
                        "name = \"Mock provider\"\n",
                        "base_url = \"{base_url}\"\n",
                        "wire_api = \"responses\"\n",
                        "supports_websockets = false\n",
                        "request_max_retries = 0\n",
                        "stream_max_retries = 0\n",
                    ),
                    base_url = base_url
                ),
            )
            .expect("write config.toml");

            let (config, client) = start_app_server(&home, codex_overrides())
                .await
                .expect("start embedded app server");

            let sender = client.sender();
            let instructions = "You are Poki, a voice assistant that operates the user's iPhone with tools.";
            let empty_schema = json!({
                "type": "object",
                "properties": {},
                "additionalProperties": false
            });
            let thread_start: ClientRequest = serde_json::from_value(json!({
                "id": 1,
                "method": "thread/start",
                "params": {
                    "cwd": home.to_string_lossy(),
                    "approvalPolicy": "never",
                    "sandbox": "read-only",
                    "ephemeral": true,
                    "developerInstructions": instructions,
                    "dynamicTools": [
                        {
                            "type": "function",
                            "name": "get_ios_version",
                            "description": "Read the iPhone model and its iOS version.",
                            "inputSchema": empty_schema
                        },
                        {
                            "type": "function",
                            "name": "look",
                            "description": "Read the iPhone screen now.",
                            "inputSchema": empty_schema
                        },
                        {
                            "type": "function",
                            "name": "open_app",
                            "description": "Open an app on this iPhone.",
                            "inputSchema": {
                                "type": "object",
                                "properties": { "app": { "type": "string" } },
                                "required": ["app"],
                                "additionalProperties": false
                            }
                        },
                        {
                            "type": "function",
                            "name": "do",
                            "description": "Run actions on the iPhone.",
                            "inputSchema": {
                                "type": "object",
                                "properties": { "actions": { "type": "array", "items": { "type": "object" } } },
                                "required": ["actions"],
                                "additionalProperties": false
                            }
                        }
                    ]
                }
            }))
            .expect("parse thread/start ClientRequest");

            let thread_result = sender
                .request(thread_start)
                .await
                .expect("thread/start transport")
                .expect("thread/start result");
            let thread_id = thread_result
                .pointer("/thread/id")
                .and_then(Value::as_str)
                .expect("thread id")
                .to_owned();

            let turn_start: ClientRequest = serde_json::from_value(json!({
                "id": 2,
                "method": "turn/start",
                "params": {
                    "threadId": thread_id,
                    "input": [{ "type": "text", "text": "Open Settings" }]
                }
            }))
            .expect("parse turn/start ClientRequest");
            let _ = sender
                .request(turn_start)
                .await
                .expect("turn/start transport")
                .expect("turn/start result");

            let request_body = captured_rx
                .recv_timeout(Duration::from_secs(15))
                .expect("receive /v1/responses request body");
            let tool_names = collect_tool_names(&request_body);

            for expected in ["get_ios_version", "look", "open_app", "do"] {
                assert!(
                    tool_names.contains(expected),
                    "expected phone tool `{expected}` in model request, got {tool_names:?}"
                );
            }
            let leaked: Vec<&str> = [
                "exec_command",
                "write_stdin",
                "shell",
                "shell_command",
                "view_image",
                "request_user_input",
                "request_user_input_async",
                "web_search",
                "spawn_agent",
                "send_input",
                "send_message",
                "followup_task",
                "interrupt_agent",
                "list_agents",
                "wait_agent",
                "resume_agent",
                "close_agent",
                "imagegen",
                "sleep",
                "create_goal",
                "get_goal",
                "update_goal",
                "update_plan",
            ]
            .into_iter()
            .filter(|name| tool_names.contains(*name))
            .collect();
            assert!(
                leaked.is_empty(),
                "unrelated tools {leaked:?} leaked into model request: {tool_names:?}"
            );

            let input_serialized = request_body
                .get("input")
                .map(Value::to_string)
                .unwrap_or_default();
            assert!(
                input_serialized.contains(instructions),
                "developerInstructions missing from model request input"
            );

            let enabled_feature_keys: BTreeSet<&str> = config
                .features
                .get()
                .enabled_features()
                .into_iter()
                .map(|feature| feature.key())
                .collect();
            for disabled in [
                "shell_tool",
                "plugins",
                "apps",
                "tool_suggest",
                "multi_agent",
                "view_image",
                "sleep_tool",
                "image_generation",
                "hooks",
                "goals",
            ] {
                assert!(
                    !enabled_feature_keys.contains(disabled),
                    "expected feature `{disabled}` disabled, enabled: {enabled_feature_keys:?}"
                );
            }
            assert!(
                !config.features.get().apps_enabled_for_auth(true),
                "codex apps must remain disabled even with ChatGPT auth"
            );
            assert!(!config.agents_enabled, "agents must be disabled");
            assert!(
                !config.experimental_request_user_input_enabled,
                "request_user_input must be disabled"
            );
            assert!(
                !config.bundled_skills_enabled(),
                "bundled skills must be disabled"
            );
            assert_eq!(
                config.web_search_mode.value(),
                WebSearchMode::Disabled,
                "web search must be disabled"
            );

            let _ = client.shutdown().await;
            let _ = std::fs::remove_dir_all(&home);
        });
        runtime.block_on(handle).expect("test task");
    }
}
