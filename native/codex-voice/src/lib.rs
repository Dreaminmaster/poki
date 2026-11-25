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
        (
            "features.code_mode_only_strict_3p_tools".into(),
            toml::Value::Boolean(false),
        ),
        (
            "features.code_mode.direct_only_tool_namespaces".into(),
            toml::Value::Array(vec![toml::Value::String("functions".into())]),
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
    incoming: mpsc::Receiver<Value>,
    emit: Event,
) -> anyhow::Result<()> {
    serve_with_overrides(
        home,
        codex_overrides(),
        incoming,
        Arc::new(move |value| publish(emit, value)),
    )
    .await
}

async fn serve_with_overrides(
    home: PathBuf,
    overrides: Vec<(String, toml::Value)>,
    mut incoming: mpsc::Receiver<Value>,
    publish_event: Arc<dyn Fn(Value) + Send + Sync>,
) -> anyhow::Result<()> {
    let (_, mut client) = start_app_server(&home, overrides.clone()).await?;
    let mut sender = client.sender();

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
                if method == "poki/account/reload" {
                    let _ = client.shutdown().await;
                    match start_app_server(&home, overrides.clone()).await {
                        Ok((_, next_client)) => {
                            client = next_client;
                            sender = client.sender();
                            publish_event(json!({"id": id, "result": {}}));
                        }
                        Err(error) => {
                            publish_event(json!({"id": id, "error": {"code": -32000}}));
                            return Err(error);
                        }
                    }
                    continue;
                }
                if !matches!(
                    method,
                    "account/read"
                        | "account/login/start"
                        | "account/login/cancel"
                        | "account/logout"
                        | "thread/start"
                        | "thread/realtime/start"
                        | "thread/realtime/appendSpeech"
                        | "thread/realtime/stop"
                )
                    || method == "account/login/start" && !matches!(
                        message.pointer("/params/type").and_then(Value::as_str),
                        Some("chatgpt" | "chatgptDeviceCode")
                    )
                {
                    publish_event(json!({"id": id, "error": {"code": -32601}}));
                    continue;
                }
                let Ok(request) = serde_json::from_value::<ClientRequest>(message) else {
                    publish_event(json!({"id": id, "error": {"code": -32602}}));
                    continue;
                };
                let sender = sender.clone();
                let publish_event = Arc::clone(&publish_event);
                tokio::spawn(async move {
                    let response = match sender.request(request).await {
                        Ok(Ok(result)) => json!({"id": id, "result": result}),
                        Ok(Err(error)) => json!({"id": id, "error": {
                            "code": error.code,
                            "kind": auth_failure_kind(&error.message),
                        }}),
                        Err(_) => json!({"id": id, "error": {"code": -32000}}),
                    };
                    publish_event(response);
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
                        publish_event(value);
                    } else if let Some(summary) = backend_diagnostic_notification(&method, &value) {
                        publish_event(summary);
                    }
                }
                Some(InProcessServerEvent::ServerRequest(event)) => {
                    let Ok(value) = serde_json::to_value(event) else { continue; };
                    let method = value
                        .get("method")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    if method == "item/tool/call" {
                        publish_event(value);
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
                            publish_event(json!({
                                "method": "poki/tool/rejected",
                                "params": {
                                    "threadId": thread_id,
                                    "requestMethod": method,
                                    "reason": "unsupportedServerRequest",
                                }
                            }));
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

fn extract_codex_error_fields(error: Option<&Value>) -> (&str, Option<u16>, Option<&'static str>, Option<String>) {
    let Some(error) = error else {
        return ("unknown", None, None, None);
    };
    let (code, http_status) = match error.get("codexErrorInfo") {
        Some(Value::String(name)) => (name.as_str(), None),
        Some(Value::Object(map)) => {
            if let Some((name, detail)) = map.iter().next() {
                let status = detail
                    .get("httpStatusCode")
                    .and_then(Value::as_u64)
                    .and_then(|status| u16::try_from(status).ok())
                    .filter(|status| (400..=599).contains(status));
                (name.as_str(), status)
            } else {
                ("unknown", None)
            }
        }
        _ => ("unknown", None),
    };
    let message = error.get("message").and_then(Value::as_str);
    let details = error.get("additionalDetails").and_then(Value::as_str);
    let kind = message
        .and_then(auth_failure_kind)
        .or_else(|| details.and_then(auth_failure_kind));
    let diagnostic = backend_error_diagnostic(message, details);
    (code, http_status, kind, diagnostic)
}

fn extract_final_agent_message(items: Option<&Value>) -> Option<String> {
    let items = items?.as_array()?;
    for item in items.iter().rev() {
        let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
        if item_type == "agentMessage" {
            let phase = item.get("phase").and_then(Value::as_str);
            if matches!(phase, Some("final_answer") | None)
                && let Some(text) = item
                    .get("text")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|text| !text.is_empty())
            {
                return Some(text.to_owned());
            }
            continue;
        }
        if matches!(
            item_type,
            "dynamicToolCall"
                | "mcpToolCall"
                | "commandExecution"
                | "fileChange"
                | "collabAgentToolCall"
        ) {
            break;
        }
    }
    None
}

fn backend_diagnostic_notification(method: &str, value: &Value) -> Option<Value> {
    let thread_id = value.pointer("/params/threadId").and_then(Value::as_str)?;
    match method {
        "turn/started" => {
            let mut params = json!({ "threadId": thread_id });
            if let (Some(turn_id), Some(obj)) = (
                value.pointer("/params/turn/id").and_then(Value::as_str),
                params.as_object_mut(),
            ) {
                obj.insert("turnId".into(), json!(turn_id));
            }
            Some(json!({
                "method": "poki/backend/turnStarted",
                "params": params
            }))
        }
        "item/completed" => {
            let item = value.pointer("/params/item")?;
            if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
                return None;
            }
            let text = item.get("text").and_then(Value::as_str)?.trim();
            if text.is_empty() {
                return None;
            }
            let mut params = json!({
                "threadId": thread_id,
                "text": text,
            });
            if let Some(obj) = params.as_object_mut() {
                if let Some(turn_id) = value.pointer("/params/turnId").and_then(Value::as_str) {
                    obj.insert("turnId".into(), json!(turn_id));
                }
                if let Some(item_id) = item.get("id").and_then(Value::as_str) {
                    obj.insert("itemId".into(), json!(item_id));
                }
                if let Some(phase) = item.get("phase").and_then(Value::as_str) {
                    obj.insert("phase".into(), json!(phase));
                }
            }
            Some(json!({
                "method": "poki/backend/agentMessage",
                "params": params
            }))
        }
        "turn/completed" => {
            let status = value
                .pointer("/params/turn/status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let mut params = json!({ "threadId": thread_id, "status": status });
            if let Some(obj) = params.as_object_mut() {
                if let Some(turn_id) = value.pointer("/params/turn/id").and_then(Value::as_str) {
                    obj.insert("turnId".into(), json!(turn_id));
                }
                if status == "completed"
                    && let Some(final_text) =
                        extract_final_agent_message(value.pointer("/params/turn/items"))
                {
                    obj.insert("finalText".into(), json!(final_text));
                }
                if let Some(turn_error) =
                    value.pointer("/params/turn/error").filter(|v| !v.is_null())
                {
                    let (code, http_status, kind, diagnostic) =
                        extract_codex_error_fields(Some(turn_error));
                    obj.insert("code".into(), json!(code));
                    if let Some(http_status) = http_status {
                        obj.insert("httpStatusCode".into(), json!(http_status));
                    }
                    if let Some(kind) = kind {
                        obj.insert("kind".into(), json!(kind));
                    }
                    if let Some(diagnostic) = diagnostic {
                        obj.insert("diagnostic".into(), json!(diagnostic));
                    }
                }
            }
            Some(json!({
                "method": "poki/backend/turnCompleted",
                "params": params
            }))
        }
        "error" => {
            let will_retry = value
                .pointer("/params/willRetry")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let (code, http_status, kind, diagnostic) =
                extract_codex_error_fields(value.pointer("/params/error"));
            let mut params = json!({
                "threadId": thread_id,
                "willRetry": will_retry,
                "code": code,
            });
            if let Some(obj) = params.as_object_mut() {
                if let Some(http_status) = http_status {
                    obj.insert("httpStatusCode".into(), json!(http_status));
                }
                if let Some(kind) = kind {
                    obj.insert("kind".into(), json!(kind));
                }
                if let Some(diagnostic) = diagnostic {
                    obj.insert("diagnostic".into(), json!(diagnostic));
                }
            }
            Some(json!({
                "method": "poki/backend/error",
                "params": params
            }))
        }
        "warning" => {
            let message = value.pointer("/params/message").and_then(Value::as_str)?;
            let diagnostic = backend_warning_diagnostic(message)?;
            Some(json!({
                "method": "poki/backend/warning",
                "params": {
                    "threadId": thread_id,
                    "diagnostic": diagnostic,
                }
            }))
        }
        _ => None,
    }
}

fn backend_error_diagnostic(message: Option<&str>, details: Option<&str>) -> Option<String> {
    let combined = match (details, message) {
        (Some(d), Some(m)) => format!("{d}\n{m}"),
        (Some(d), None) => d.to_owned(),
        (None, Some(m)) => m.to_owned(),
        (None, None) => return None,
    };
    let lower = combined.to_ascii_lowercase();
    if lower.contains("no native root ca certificates found") {
        return Some("tls no native root CA certificates found".into());
    }
    if lower.contains("unknownissuer") || lower.contains("unknown issuer") {
        return Some("tls invalid peer certificate: UnknownIssuer".into());
    }
    if lower.contains("invalid peer certificate") || lower.contains("certificate verify failed") {
        return Some("tls invalid peer certificate".into());
    }
    if lower.contains("failed to configure websocket tls") || lower.contains("tls handshake") {
        return Some("tls handshake failed".into());
    }
    if lower.contains("operation timed out") || lower.contains("timed out") {
        return Some("operation timed out".into());
    }
    if lower.contains("connection reset by peer") {
        return Some("connection reset by peer".into());
    }
    if lower.contains("connection refused") {
        return Some("connection refused".into());
    }
    if lower.contains("dns error") || lower.contains("failed to lookup address") {
        return Some("dns resolution failed".into());
    }
    if lower.contains("websocket closed") {
        return Some("websocket closed unexpectedly".into());
    }
    if let Some(status) = extract_http_status(&lower) {
        return Some(format!("unexpected status {status}"));
    }
    if lower.contains("stream disconnected before completion") {
        return Some("stream disconnected before completion".into());
    }
    None
}

fn backend_warning_diagnostic(message: &str) -> Option<String> {
    let lower = message.to_ascii_lowercase();
    if lower.contains("falling back from websockets to https") {
        if let Some(cause) = backend_error_diagnostic(Some(message), None) {
            return Some(format!(
                "falling back from WebSockets to HTTPS transport ({cause})"
            ));
        }
        return Some("falling back from WebSockets to HTTPS transport".into());
    }
    if lower.contains("code mode is unavailable") {
        if lower.contains("fail closed") {
            return Some("code mode unavailable (fail closed)".into());
        }
        return Some("code mode unavailable (falling back to direct tools)".into());
    }
    None
}

fn extract_http_status(lower: &str) -> Option<u16> {
    for prefix in ["unexpected status ", "status code ", "status: ", "http status "] {
        if let Some((_, rest)) = lower.split_once(prefix)
            && let Some(status) = rest
                .split(|c: char| !c.is_ascii_digit())
                .next()
                .and_then(|digits| digits.parse::<u16>().ok())
                .filter(|status| (400..=599).contains(status))
        {
            return Some(status);
        }
    }
    None
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

    fn collect_declared_tools(request_body: &Value) -> Vec<&Value> {
        fn push_tool<'a>(tool: &'a Value, out: &mut Vec<&'a Value>) {
            if tool.get("type").and_then(Value::as_str) == Some("namespace")
                && let Some(nested) = tool.get("tools").and_then(Value::as_array)
            {
                for item in nested {
                    push_tool(item, out);
                }
                return;
            }
            out.push(tool);
        }

        let mut declared = Vec::new();
        if let Some(tools) = request_body.get("tools").and_then(Value::as_array) {
            for tool in tools {
                push_tool(tool, &mut declared);
            }
        }
        if let Some(input) = request_body.get("input").and_then(Value::as_array) {
            for item in input {
                if let Some(tools) = item.get("tools").and_then(Value::as_array) {
                    for tool in tools {
                        push_tool(tool, &mut declared);
                    }
                }
            }
        }
        declared
    }

    fn collect_direct_function_tool_names(request_body: &Value) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        for tool in collect_declared_tools(request_body) {
            if tool.get("type").and_then(Value::as_str) == Some("function")
                && let Some(name) = tool.get("name").and_then(Value::as_str)
            {
                names.insert(name.to_owned());
            }
        }
        names
    }

    fn collect_top_level_tool_names(request_body: &Value) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        for tool in collect_declared_tools(request_body) {
            if let Some(name) = tool.get("name").and_then(Value::as_str) {
                names.insert(name.to_owned());
            } else if let Some(kind) = tool.get("type").and_then(Value::as_str) {
                names.insert(kind.to_owned());
            }
        }
        names
    }

    fn spawn_mock_tool_call_responses_server() -> (String, std_mpsc::Receiver<Value>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let addr = listener.local_addr().expect("local addr");
        let (tx, rx) = std_mpsc::channel();
        std::thread::spawn(move || {
            let mut responses_turn = 0usize;
            for incoming in listener.incoming() {
                let Ok(mut stream) = incoming else { break };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                let Some((request_line, body)) = read_http_request(&mut stream) else {
                    continue;
                };
                if request_line.starts_with("POST ") && request_line.contains("/responses") {
                    responses_turn += 1;
                    if let Ok(json) = serde_json::from_slice::<Value>(&body) {
                        let _ = tx.send(json);
                    }
                    let sse = if responses_turn == 1 {
                        concat!(
                            "event: response.created\n",
                            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n",
                            "event: response.output_item.done\n",
                            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_open_wechat\",\"name\":\"open_app\",\"arguments\":\"{\\\"app\\\":\\\"微信\\\"}\"}}\n\n",
                            "event: response.completed\n",
                            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_open_wechat\",\"name\":\"open_app\",\"arguments\":\"{\\\"app\\\":\\\"微信\\\"}\"}]}}\n\n"
                        )
                    } else {
                        concat!(
                            "event: response.created\n",
                            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_2\"}}\n\n",
                            "event: response.output_item.done\n",
                            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"已为你打开微信。\"}]}}\n\n",
                            "event: response.completed\n",
                            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"已为你打开微信。\"}]}]}}\n\n"
                        )
                    };
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        sse.len(),
                        sse
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.flush();
                    if responses_turn >= 2 {
                        break;
                    }
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
                                "properties": {
                                    "app": { "type": "string" },
                                    "page": { "type": "string", "enum": ["wifi", "bluetooth"] }
                                },
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
            let direct_tool_names = collect_direct_function_tool_names(&request_body);
            let tool_names = collect_top_level_tool_names(&request_body);

            for expected in ["get_ios_version", "look", "open_app", "do"] {
                assert!(
                    direct_tool_names.contains(expected),
                    "expected direct top-level function tool `{expected}` in model request, got direct={direct_tool_names:?}, all={tool_names:?}"
                );
            }
            let leaked: Vec<&str> = [
                "exec",
                "wait",
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
                "unrelated or unavailable code-mode tools {leaked:?} leaked into model request: {tool_names:?}"
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

    #[test]
    fn subscription_voice_dispatches_open_app_dynamic_tool_call() {
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
                "poki-codex-voice-dispatch-test-{}-{unique}",
                std::process::id()
            ));
            std::fs::create_dir_all(&home).expect("create temp home");
            let (base_url, captured_rx) = spawn_mock_tool_call_responses_server();
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

            let (_, mut client) = start_app_server(&home, codex_overrides())
                .await
                .expect("start embedded app server");
            let sender = client.sender();
            let thread_start: ClientRequest = serde_json::from_value(json!({
                "id": 1,
                "method": "thread/start",
                "params": {
                    "cwd": home.to_string_lossy(),
                    "approvalPolicy": "never",
                    "sandbox": "read-only",
                    "ephemeral": true,
                    "developerInstructions": "Open apps with open_app.",
                    "dynamicTools": [{
                        "type": "function",
                        "name": "open_app",
                        "description": "Open an app on this iPhone.",
                        "inputSchema": {
                            "type": "object",
                            "properties": { "app": { "type": "string" } },
                            "required": ["app"],
                            "additionalProperties": false
                        }
                    }]
                }
            }))
            .expect("parse thread/start");
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
                    "input": [{ "type": "text", "text": "打开微信" }]
                }
            }))
            .expect("parse turn/start");
            let _ = sender
                .request(turn_start)
                .await
                .expect("turn/start transport")
                .expect("turn/start result");

            let mut dispatched_tool = None;
            let mut completed_status = None;
            let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
            while tokio::time::Instant::now() < deadline {
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                let Ok(event) = tokio::time::timeout(remaining, client.next_event()).await else {
                    break;
                };
                match event {
                    Some(InProcessServerEvent::ServerRequest(request)) => {
                        let value = serde_json::to_value(request).expect("serialize request");
                        if value.get("method").and_then(Value::as_str) == Some("item/tool/call") {
                            dispatched_tool = Some((
                                value
                                    .pointer("/params/tool")
                                    .and_then(Value::as_str)
                                    .unwrap_or_default()
                                    .to_owned(),
                                value.pointer("/params/arguments/app").cloned(),
                            ));
                            let id: RequestId = serde_json::from_value(
                                value.get("id").cloned().expect("request id"),
                            )
                            .expect("parse request id");
                            sender
                                .respond_to_server_request(
                                    id,
                                    json!({
                                        "success": true,
                                        "contentItems": [{ "type": "inputText", "text": "Opened WeChat" }]
                                    }),
                                )
                                .expect("respond to tool call");
                        }
                    }
                    Some(InProcessServerEvent::ServerNotification(notification)) => {
                        let value = serde_json::to_value(notification).expect("serialize notif");
                        if value.get("method").and_then(Value::as_str) == Some("turn/completed") {
                            completed_status = value
                                .pointer("/params/turn/status")
                                .and_then(Value::as_str)
                                .map(str::to_owned);
                            break;
                        }
                    }
                    _ => {}
                }
            }

            let first_request = captured_rx
                .recv_timeout(Duration::from_secs(5))
                .expect("first /responses request");
            assert!(
                collect_direct_function_tool_names(&first_request).contains("open_app"),
                "open_app must be directly callable"
            );
            assert_eq!(
                dispatched_tool,
                Some(("open_app".to_owned(), Some(json!("微信")))),
                "expected item/tool/call for open_app"
            );
            assert_eq!(completed_status.as_deref(), Some("completed"));

            let _ = client.shutdown().await;
            let _ = std::fs::remove_dir_all(&home);
        });
        runtime.block_on(handle).expect("test task");
    }

    #[test]
    fn backend_diagnostic_notification_exposes_sanitized_transport_and_warning_details() {
        let tls_error = json!({
            "params": {
                "threadId": "thr_1",
                "willRetry": true,
                "error": {
                    "message": "Reconnecting... 2/5",
                    "codexErrorInfo": {
                        "responseStreamDisconnected": { "httpStatusCode": 502 }
                    },
                    "additionalDetails": "stream disconnected before completion: invalid peer certificate: UnknownIssuer at wss://chatgpt.com/secret?token=Bearer sk-secret123456"
                }
            }
        });
        let summary = backend_diagnostic_notification("error", &tls_error)
            .expect("error summary");
        assert_eq!(summary["method"], "poki/backend/error");
        assert_eq!(summary["params"]["code"], "responseStreamDisconnected");
        assert_eq!(summary["params"]["httpStatusCode"], 502);
        let diagnostic = summary["params"]["diagnostic"]
            .as_str()
            .expect("sanitized diagnostic");
        assert!(
            diagnostic.contains("UnknownIssuer"),
            "expected TLS diagnostic, got {diagnostic}"
        );
        assert!(
            !diagnostic.contains("sk-secret123456") && !diagnostic.contains("chatgpt.com"),
            "diagnostic must not leak URLs or tokens: {diagnostic}"
        );

        let failed_turn = json!({
            "params": {
                "threadId": "thr_1",
                "turn": {
                    "status": "failed",
                    "error": {
                        "message": "stream disconnected before completion: operation timed out",
                        "codexErrorInfo": "responseStreamDisconnected",
                        "additionalDetails": "IO error: operation timed out"
                    }
                }
            }
        });
        let completed = backend_diagnostic_notification("turn/completed", &failed_turn)
            .expect("turn completed summary");
        assert_eq!(completed["method"], "poki/backend/turnCompleted");
        assert_eq!(completed["params"]["status"], "failed");
        assert_eq!(completed["params"]["code"], "responseStreamDisconnected");
        assert!(
            completed["params"]["diagnostic"]
                .as_str()
                .is_some_and(|d| d.contains("timed out")),
            "expected failed turn diagnostic, got {completed}"
        );

        let fallback_warning = json!({
            "params": {
                "threadId": "thr_1",
                "message": "Falling back from WebSockets to HTTPS transport. invalid peer certificate: UnknownIssuer"
            }
        });
        let warning = backend_diagnostic_notification("warning", &fallback_warning)
            .expect("warning summary");
        assert_eq!(warning["method"], "poki/backend/warning");
        assert!(
            warning["params"]["diagnostic"]
                .as_str()
                .is_some_and(|d| d.contains("WebSockets") && d.contains("HTTPS")),
            "expected transport fallback warning, got {warning}"
        );
    }

    #[test]
    fn account_reload_recovers_chatgpt_account_after_empty_startup() {
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
                "poki-codex-voice-reload-test-{}-{unique}",
                std::process::id()
            ));
            std::fs::create_dir_all(&home).expect("create temp home");

            let mut overrides = codex_overrides();
            for (key, value) in &mut overrides {
                if key == "cli_auth_credentials_store" {
                    *value = toml::Value::String("file".into());
                }
            }

            let (req_tx, req_rx) = mpsc::channel(16);
            let (out_tx, mut out_rx) = mpsc::unbounded_channel();
            let server_home = home.clone();
            let server_task = tokio::spawn(async move {
                serve_with_overrides(
                    server_home,
                    overrides,
                    req_rx,
                    Arc::new(move |value| {
                        let _ = out_tx.send(value);
                    }),
                )
                .await
            });

            async fn wait_for_id(
                out_rx: &mut mpsc::UnboundedReceiver<Value>,
                target: i64,
            ) -> Value {
                let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
                loop {
                    let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                    let msg = tokio::time::timeout(remaining, out_rx.recv())
                        .await
                        .expect("timed out waiting for rpc response")
                        .expect("output channel closed");
                    if msg.get("id").and_then(Value::as_i64) == Some(target) {
                        return msg;
                    }
                }
            }

            fn assert_rpc_ok(reply: &Value, context: &str) {
                assert!(
                    reply.get("result").is_some(),
                    "expected {context} response to include result, got {reply}"
                );
                assert!(
                    reply.get("error").is_none(),
                    "expected {context} response to have no error, got {reply}"
                );
            }

            req_tx
                .send(json!({"id": 1, "method": "account/read", "params": {"refreshToken": false}}))
                .await
                .expect("send initial account/read");
            let initial = wait_for_id(&mut out_rx, 1).await;
            assert_rpc_ok(&initial, "initial account/read");
            assert!(
                initial.pointer("/result/account").is_none_or(Value::is_null),
                "expected empty initial account, got {initial}"
            );

            // Simulate Swift migrating a valid ChatGPT AuthDotJson after the runtime already started empty.
            // Omit chatgpt_account_id so account/read stays completely offline without contacting chatgpt.com.
            let id_token = concat!(
                "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.",
                "eyJzdWIiOiJ1c2VyLTEiLCJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20ifQ.",
                "sig"
            );
            let auth_json = json!({
                "auth_mode": "chatgpt",
                "tokens": {
                    "id_token": id_token,
                    "access_token": id_token,
                    "refresh_token": "refresh-fixture"
                },
                "last_refresh": "2026-11-23T10:00:00Z"
            });
            std::fs::write(home.join("auth.json"), auth_json.to_string()).expect("write auth.json");

            // Confirm refreshToken: true alone does not transition cached None -> Some(chatgpt).
            req_tx
                .send(json!({"id": 2, "method": "account/read", "params": {"refreshToken": true}}))
                .await
                .expect("send refresh account/read");
            let after_refresh_only = wait_for_id(&mut out_rx, 2).await;
            assert_rpc_ok(&after_refresh_only, "refreshToken:true account/read");
            assert!(
                after_refresh_only
                    .pointer("/result/account")
                    .is_none_or(Value::is_null),
                "expected refreshToken:true alone to keep None cache, got {after_refresh_only}"
            );

            req_tx
                .send(json!({"id": 3, "method": "poki/account/reload", "params": {}}))
                .await
                .expect("send poki/account/reload");
            let reload_reply = wait_for_id(&mut out_rx, 3).await;
            assert_rpc_ok(&reload_reply, "poki/account/reload");

            req_tx
                .send(json!({"id": 4, "method": "account/read", "params": {"refreshToken": false}}))
                .await
                .expect("send reloaded account/read");
            let reloaded = wait_for_id(&mut out_rx, 4).await;
            assert_rpc_ok(&reloaded, "reloaded account/read");
            assert_eq!(
                reloaded.pointer("/result/account/type").and_then(Value::as_str),
                Some("chatgpt"),
                "expected chatgpt account after poki/account/reload, got {reloaded}"
            );
            assert_eq!(
                reloaded.pointer("/result/account/email").and_then(Value::as_str),
                Some("test@example.com"),
                "expected email from reloaded id_token, got {reloaded}"
            );

            drop(req_tx);
            let _ = tokio::time::timeout(Duration::from_secs(10), server_task).await;
            let _ = std::fs::remove_dir_all(&home);
        });
        runtime.block_on(handle).expect("test task");
    }

    #[test]
    fn backend_agent_message_and_append_speech_sync_contract() {
        let commentary_item = json!({
            "params": {
                "threadId": "thr_sync",
                "turnId": "turn_1",
                "item": {
                    "type": "agentMessage",
                    "id": "msg_commentary",
                    "phase": "commentary",
                    "text": "Opening 12306 now."
                }
            }
        });
        let commentary = backend_diagnostic_notification("item/completed", &commentary_item)
            .expect("commentary agentMessage must be forwarded for client-managed sync");
        assert_eq!(commentary["method"], "poki/backend/agentMessage");
        assert_eq!(commentary["params"]["threadId"], "thr_sync");
        assert_eq!(commentary["params"]["turnId"], "turn_1");
        assert_eq!(commentary["params"]["itemId"], "msg_commentary");
        assert_eq!(commentary["params"]["phase"], "commentary");
        assert_eq!(commentary["params"]["text"], "Opening 12306 now.");

        let final_item = json!({
            "params": {
                "threadId": "thr_sync",
                "turnId": "turn_1",
                "item": {
                    "type": "agentMessage",
                    "id": "msg_final",
                    "phase": "final_answer",
                    "text": "Sent the departure time to File Transfer."
                }
            }
        });
        let final_msg = backend_diagnostic_notification("item/completed", &final_item)
            .expect("final agentMessage must be forwarded");
        assert_eq!(final_msg["method"], "poki/backend/agentMessage");
        assert_eq!(final_msg["params"]["phase"], "final_answer");
        assert_eq!(
            final_msg["params"]["text"],
            "Sent the departure time to File Transfer."
        );

        let completed_turn = json!({
            "params": {
                "threadId": "thr_sync",
                "turn": {
                    "id": "turn_1",
                    "status": "completed",
                    "items": [
                        {
                            "type": "agentMessage",
                            "id": "msg_commentary",
                            "phase": "commentary",
                            "text": "Opening WeChat..."
                        },
                        {
                            "type": "agentMessage",
                            "id": "msg_final",
                            "phase": "final_answer",
                            "text": "Sent the departure time to File Transfer."
                        }
                    ]
                }
            }
        });
        let turn_done = backend_diagnostic_notification("turn/completed", &completed_turn)
            .expect("turn/completed summary");
        assert_eq!(turn_done["method"], "poki/backend/turnCompleted");
        assert_eq!(turn_done["params"]["turnId"], "turn_1");
        assert_eq!(
            turn_done["params"]["finalText"],
            "Sent the departure time to File Transfer."
        );

        let interrupted_turn = json!({
            "params": {
                "threadId": "thr_sync",
                "turn": {
                    "id": "turn_2",
                    "status": "interrupted",
                    "items": [
                        {
                            "type": "agentMessage",
                            "id": "msg_interrupted",
                            "phase": "final_answer",
                            "text": "Should not be spoken."
                        }
                    ]
                }
            }
        });
        let interrupted_done = backend_diagnostic_notification("turn/completed", &interrupted_turn)
            .expect("interrupted turn/completed summary");
        assert_eq!(interrupted_done["params"]["status"], "interrupted");
        assert!(
            interrupted_done["params"].get("finalText").is_none(),
            "non-completed turn must never carry finalText: {interrupted_done}"
        );

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
                "poki-codex-voice-sync-test-{}-{unique}",
                std::process::id()
            ));
            std::fs::create_dir_all(&home).expect("create temp home");

            let mut overrides = codex_overrides();
            for (key, value) in &mut overrides {
                if key == "cli_auth_credentials_store" {
                    *value = toml::Value::String("file".into());
                }
            }

            let (req_tx, req_rx) = mpsc::channel(16);
            let (out_tx, mut out_rx) = mpsc::unbounded_channel();
            let server_home = home.clone();
            let server_task = tokio::spawn(async move {
                serve_with_overrides(
                    server_home,
                    overrides,
                    req_rx,
                    Arc::new(move |value| {
                        let _ = out_tx.send(value);
                    }),
                )
                .await
            });

            req_tx
                .send(json!({
                    "id": 77,
                    "method": "thread/realtime/appendSpeech",
                    "params": {
                        "threadId": "019eb97d-8e9a-7ff3-94b0-ea019babd5d7",
                        "text": "Done after action completed."
                    }
                }))
                .await
                .expect("send appendSpeech");

            let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
            let reply = loop {
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                let msg = tokio::time::timeout(remaining, out_rx.recv())
                    .await
                    .expect("timed out waiting for appendSpeech reply")
                    .expect("output channel closed");
                if msg.get("id").and_then(Value::as_i64) == Some(77) {
                    break msg;
                }
            };
            assert_ne!(
                reply.pointer("/error/code").and_then(Value::as_i64),
                Some(-32601),
                "thread/realtime/appendSpeech must be allowed by poki-codex-voice, got {reply}"
            );

            drop(req_tx);
            let _ = tokio::time::timeout(Duration::from_secs(10), server_task).await;
            let _ = std::fs::remove_dir_all(&home);
        });
        runtime.block_on(handle).expect("test task");
    }
}
