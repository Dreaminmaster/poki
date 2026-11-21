//! poki-mcp: the MCP server Poki Setup ships (`poki-setup mcp serve`, stdio). It is a thin front for
//! Poki on the phone (issue #609): `look`, `do`, `skills` and `status` go to the phone's own PokiCore
//! over the USB cable, else the same Wi-Fi, else the relay, so an agent on this computer gets the
//! same engine as one behind the relay. Beside them it adds what only a computer has:
//! - `save` on look and do: the phone's full-size PNG written to a file here;
//! - `setup`: Poki Setup's own steps (`next`, pair, Developer Mode, install, renew…) as a tool, so an
//!   agent can go from a new phone to Poki in use without leaving MCP.
//!
//! `do` arguments go to the phone unchanged (its `intent` and `note` included); only `save` is taken
//! out. Nothing is retried once it may have reached the phone.
use crate::link::{self, Hello, Link, Transport};
use crate::{Error, Result, mcp};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;

const PROTOCOL: &str = "2025-06-18";
/// A `do` can wait about two minutes for the owner's approval on the phone.
const CALL_TIMEOUT: Duration = Duration::from_secs(200);

/// How the phone is reached now, and its MCP session there.
enum Way {
    Local(Link),
    Relay { url: String, token: String },
}

#[derive(Clone)]
struct Phone {
    way: Arc<Way>,
    session: Option<String>,
    tools: Vec<Value>,
    instructions: Option<String>,
}

pub struct Server {
    phone: Mutex<Option<Phone>>,
    agent: Mutex<String>,
    setup_cli: Option<PathBuf>,
    /// For the tests: no USB, no Wi-Fi, no relay.
    offline: bool,
}

/// What an agent sees before the phone answers: the four phone tools as PokiCore describes them are
/// read from the phone; until then (no phone reachable) only the host tools are listed.
fn host_tools() -> Vec<Value> {
    vec![
        json!({
            "name": "setup",
            "description": "Poki Setup's steps on this computer, for getting Poki onto the iPhone and keeping it signed. Start with {command: \"next\"}: it says what is done, what is next, who has to act (agent or person) and the exact command. Commands: next, phones, pair, devmode, install, renew, status, ddi, teams, login_code, support, links. The Apple password never goes through here: ask the person to run `poki-setup login <email> --keep-password` in their own terminal. Exit 2 means a person has to act (tell them `error.message`), 3 means Apple's six-digit code is needed (then {command: \"login_code\", code}).",
            "inputSchema": {"type": "object", "properties": {
                "command": {"type": "string", "enum": ["next", "phones", "pair", "devmode", "install", "renew", "status", "ddi", "teams", "login_code", "support", "links"]},
                "udid": {"type": "string"},
                "code": {"type": "string", "description": "login_code only: Apple's six-digit code."},
                "close_poki": {"type": "boolean", "description": "install only: close Poki on the phone when an update replaces it. Ask the person first."},
                "replace_certificate": {"type": "boolean", "description": "install only, and only after the person said yes to the exact message the last attempt gave."}
            }, "required": ["command"], "additionalProperties": false}
        }),
        json!({
            "name": "connection",
            "description": "How this computer reaches Poki on the phone now: usb, wifi or relay, the phone's label, and what to fix when none works. Changes nothing on the phone.",
            "inputSchema": {"type": "object", "properties": {"reconnect": {"type": "boolean", "description": "Drop the current way and look again (USB, then Wi-Fi, then the relay)."}}, "additionalProperties": false},
            "annotations": {"readOnlyHint": true}
        }),
    ]
}

/// The phone's four tools, for a list made while the phone is out of reach.
fn phone_tools_offline() -> Vec<Value> {
    let picture = json!({"description": "true (default): the screenshot at screen points. false: no picture. \"full\": the phone's own PNG.", "anyOf": [{"type": "boolean"}, {"type": "string", "enum": ["full"]}]});
    vec![
        json!({"name": "look", "description": "Read the iPhone's screen now: the app in front, numbered elements and a screenshot whose pixels are screen points.", "inputSchema": {"type": "object", "properties": {"full": {"type": "boolean"}, "picture": picture}}, "annotations": {"readOnlyHint": true}}),
        json!({"name": "do", "description": "Run actions on the iPhone in order ({tap: n}, {type: \"text\"}, {scroll_to: \"text\"}, {swipe: \"up\"}, {adjust: {ref, value}}, {launch: \"app\"}, {path: {goal, steps}} and more), then read the screen once. The phone's own description comes with the list once it is reachable.", "inputSchema": {"type": "object", "properties": {"actions": {"type": "array", "items": {"type": "object"}, "maxItems": 20}, "full": {"type": "boolean"}, "finish": {"type": "boolean"}, "app": {}, "picture": picture}, "required": ["actions"]}}),
        json!({"name": "skills", "description": "Saved skills and notes on the phone: {action: \"list\"}, \"save\", \"remember\".", "inputSchema": {"type": "object", "properties": {"action": {"type": "string"}}, "required": ["action"]}}),
        json!({"name": "status", "description": "Poki's state without touching the phone.", "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}}),
    ]
}

/// look and do take `save` here: a path for the phone's full-size PNG.
fn with_save(mut tool: Value) -> Value {
    if matches!(tool["name"].as_str(), Some("look") | Some("do")) {
        if let Some(props) = tool["inputSchema"]["properties"].as_object_mut() {
            props.insert("save".into(), json!({"type": "string", "description": "A file path on this computer: the screenshot is saved there at the phone's full pixels (PNG). Relative paths are from where the agent runs. With picture: false the reply carries no image but the file is still written."}));
        }
    }
    tool
}

impl Server {
    pub fn new(setup_cli: Option<PathBuf>) -> Self {
        Server { phone: Mutex::new(None), agent: Mutex::new(String::new()), setup_cli, offline: false }
    }

    #[cfg(test)]
    fn offline() -> Self {
        Server { phone: Mutex::new(None), agent: Mutex::new(String::new()), setup_cli: None, offline: true }
    }

    /// Serves MCP over stdin and stdout, one JSON-RPC message per line, until stdin closes.
    pub async fn serve_stdio(self: Arc<Self>) -> Result<()> {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        let out = Arc::new(Mutex::new(tokio::io::stdout()));
        let mut calls = tokio::task::JoinSet::new();
        while let Some(line) = lines.next_line().await? {
            let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
            let (server, out) = (self.clone(), out.clone());
            // Calls run side by side, so a ping or a status answers while a do waits for approval.
            calls.spawn(async move {
                if let Some(reply) = server.handle(message).await {
                    let mut o = out.lock().await;
                    let _ = o.write_all(format!("{reply}\n").as_bytes()).await;
                    let _ = o.flush().await;
                }
            });
            while calls.try_join_next().is_some() {}
        }
        // stdin closed: the calls already made still answer.
        while calls.join_next().await.is_some() {}
        Ok(())
    }

    pub async fn handle(&self, message: Value) -> Option<Value> {
        let id = message.get("id").cloned();
        let method = message["method"].as_str().unwrap_or_default();
        let result = match method {
            "initialize" => {
                *self.agent.lock().await = message["params"]["clientInfo"]["name"].as_str().unwrap_or_default().chars().take(40).collect();
                let asked = message["params"]["protocolVersion"].as_str().unwrap_or(PROTOCOL).to_string();
                Ok(json!({
                    "protocolVersion": asked,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {"name": "poki-mcp", "version": crate::VERSION},
                    "instructions": "Poki on the iPhone, reached over the USB cable, the same Wi-Fi or the relay (the connection tool says which). look reads the screen; do runs actions and then reads it; both answer with numbered elements and a screenshot (picture: false leaves it out, save: \"file.png\" keeps the full-size one on this computer). If Poki is not on the phone yet, use setup {command: \"next\"} and follow it.",
                }))
            }
            "notifications/initialized" | "notifications/cancelled" => return None,
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({"tools": self.list().await})),
            "tools/call" => Ok(self.call(message["params"]["name"].as_str().unwrap_or_default(), message["params"]["arguments"].clone()).await),
            _ if id.is_none() => return None,
            _ => Err((-32601, format!("Method not found: {method}"))),
        };
        let id = id?;
        Some(match result {
            Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
            Err((code, message)) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}),
        })
    }

    async fn list(&self) -> Vec<Value> {
        let mut tools: Vec<Value> = match self.phone().await {
            Ok(()) => self.phone.lock().await.as_ref().map(|p| p.tools.clone()).unwrap_or_default(),
            Err(_) => vec![],
        };
        // Clients keep the first list they get, so the phone's tools are listed even while it is out
        // of reach; a call then says what to fix, and the phone's own wording comes with the next list.
        if tools.is_empty() {
            tools = phone_tools_offline();
        }
        tools = tools.into_iter().map(with_save).collect();
        tools.extend(host_tools());
        tools
    }

    async fn call(&self, name: &str, args: Value) -> Value {
        match name {
            "setup" => return self.setup(args).await,
            "connection" => return self.connection(args["reconnect"].as_bool().unwrap_or(false)).await,
            _ => {}
        }
        let mut args = if args.is_object() { args } else { json!({}) };
        let save = args.as_object_mut().and_then(|a| a.remove("save")).and_then(|v| v.as_str().map(PathBuf::from));
        let keep_picture = args.get("picture").and_then(Value::as_bool) != Some(false);
        if save.is_some() {
            args["picture"] = json!("full");
        }
        let mut result = match self.forward(name, args).await {
            Ok(r) => r,
            Err(text) => return text_result(&text, true),
        };
        if let Some(path) = save {
            let note = match save_image(&mut result, &path, keep_picture) {
                Ok(p) => format!("saved: {}", p.display()),
                Err(e) => format!("not saved: {e}"),
            };
            if let Some(content) = result["content"].as_array_mut() {
                content.push(json!({"type": "text", "text": note}));
            }
        }
        result
    }

    /// A tools/call to the phone. Err is a sentence for the agent.
    async fn forward(&self, name: &str, args: Value) -> std::result::Result<Value, String> {
        let body = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}});
        for attempt in 0..2 {
            self.phone().await.map_err(|e| format!("error: {e} Nothing was sent to the phone."))?;
            match self.send(&body).await {
                Ok(reply) => {
                    if let Some(err) = reply.get("error") {
                        return Err(format!("error: {}", err["message"].as_str().unwrap_or("the phone refused the call")));
                    }
                    return Ok(reply["result"].clone());
                }
                // Never sent: the way is dropped and the next one is tried once.
                Err((false, _)) if attempt == 0 => {
                    *self.phone.lock().await = None;
                }
                Err((_, e)) => {
                    *self.phone.lock().await = None;
                    return Err(format!("error: {e}"));
                }
            }
        }
        Err("error: the phone could not be reached; nothing was sent.".into())
    }

    /// Opens a way to the phone when there is none (or the last one closed), with its MCP session.
    async fn phone(&self) -> Result<()> {
        let mut guard = self.phone.lock().await;
        if let Some(p) = guard.as_ref() {
            if !matches!(p.way.as_ref(), Way::Local(l) if !l.is_alive()) {
                return Ok(());
            }
        }
        *guard = None;
        if self.offline {
            return Err(Error::msg("No phone with Poki open is on a cable, this Wi-Fi or a relay link."));
        }
        let agent = self.agent.lock().await.clone();
        let hello = Hello { name: computer_name(), version: crate::VERSION.into(), agent };
        let way = match link::connect(&hello, || eprintln!("poki-mcp: waiting for the owner to allow this computer on the phone")).await {
            Ok(l) => Way::Local(l),
            Err(local) => match relay_way().await {
                Ok(w) => w,
                Err(relay) => return Err(Error::msg(format!("{local} The relay did not work either: {relay}"))),
            },
        };
        let mut phone = Phone { way: Arc::new(way), session: None, tools: vec![], instructions: None };
        let init = json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": PROTOCOL, "capabilities": {}, "clientInfo": {"name": if hello.agent.is_empty() { "poki-mcp".to_string() } else { format!("{} via poki-mcp", hello.agent) }, "version": crate::VERSION}}});
        let (reply, session) = send_on(&phone, &init).await.map_err(|(_, e)| e)?;
        phone.session = session;
        phone.instructions = reply["result"]["instructions"].as_str().map(String::from);
        let (list, _) = send_on(&phone, &json!({"jsonrpc": "2.0", "id": 0, "method": "tools/list", "params": {}})).await.map_err(|(_, e)| e)?;
        phone.tools = list["result"]["tools"].as_array().cloned().unwrap_or_default();
        *guard = Some(phone);
        Ok(())
    }

    async fn send(&self, body: &Value) -> std::result::Result<Value, (bool, Error)> {
        // The lock is held only to take the way: calls run side by side (a status while a do waits).
        let phone = self.phone.lock().await.clone().ok_or((false, Error::msg("not connected")))?;
        send_on(&phone, body).await.map(|(r, _)| r)
    }

    async fn connection(&self, reconnect: bool) -> Value {
        if reconnect {
            *self.phone.lock().await = None;
        }
        let state = match self.phone().await {
            Ok(()) => {
                let guard = self.phone.lock().await;
                match guard.as_ref().map(|p| p.way.as_ref()) {
                    Some(Way::Local(l)) => json!({"connected": true, "transport": l.transport, "phone": l.phone}),
                    Some(Way::Relay { url, .. }) => json!({"connected": true, "transport": Transport::Relay, "link": mcp::redact(url)}),
                    None => json!({"connected": false}),
                }
            }
            Err(e) => json!({"connected": false, "error": e.to_string(), "fix": "Open Poki on the iPhone and turn it on. Plug the phone in with a cable, or keep it on this Wi-Fi, or add its connector link with setup {command: \"links\"}. If Poki is not installed yet, run setup {command: \"next\"}."}),
        };
        text_result(&state.to_string(), false)
    }

    async fn setup(&self, args: Value) -> Value {
        let Some(cli) = self.setup_cli.clone().or_else(crate::agent::cli_path) else {
            return text_result("error: poki-setup was not found next to poki-mcp; install Poki Setup from the newest Beta release.", true);
        };
        let command = args["command"].as_str().unwrap_or_default();
        let udid = args["udid"].as_str().map(|u| vec!["--udid".to_string(), u.to_string()]).unwrap_or_default();
        let mut argv: Vec<String> = match command {
            "next" | "pair" | "devmode" | "renew" => [vec![command.to_string()], udid].concat(),
            "phones" | "status" | "ddi" | "teams" | "support" => vec![command.to_string()],
            "links" => vec!["mcp".into(), "list".into()],
            "login_code" => match args["code"].as_str() {
                Some(code) if code.len() == 6 && code.chars().all(|c| c.is_ascii_digit()) => vec!["login".into(), "--code".into(), code.into()],
                _ => return text_result("error: login_code needs code, Apple's six digits.", true),
            },
            "install" => {
                let mut a = [vec!["install".to_string()], udid].concat();
                if args["close_poki"].as_bool() == Some(true) { a.push("--close-poki".into()); }
                if args["replace_certificate"].as_bool() == Some(true) { a.push("--replace-certificate".into()); }
                a
            }
            _ => return text_result("error: unknown setup command.", true),
        };
        argv.push("--json".into());
        let output = tokio::process::Command::new(&cli).args(&argv).stdin(std::process::Stdio::null()).output().await;
        match output {
            Ok(o) => {
                let code = o.status.code().unwrap_or(1);
                let stdout = String::from_utf8_lossy(&o.stdout).trim().to_string();
                let progress: Vec<String> = String::from_utf8_lossy(&o.stderr).lines().rev().take(8).map(String::from).collect::<Vec<_>>().into_iter().rev().collect();
                let text = json!({"exit": code, "result": serde_json::from_str::<Value>(&stdout).unwrap_or(Value::String(stdout)), "progress": progress});
                // A person to act (2) or a code to wait for (3) is not a failure of the tool.
                text_result(&text.to_string(), code == 1)
            }
            Err(e) => text_result(&format!("error: could not run poki-setup: {e}"), true),
        }
    }
}

fn text_result(text: &str, is_error: bool) -> Value { json!({"content": [{"type": "text", "text": text}], "isError": is_error}) }

fn computer_name() -> String {
    std::env::var("POKI_COMPUTER_NAME").ok()
        .or_else(|| std::process::Command::new(if cfg!(target_os = "macos") { "scutil" } else { "hostname" }).args(if cfg!(target_os = "macos") { &["--get", "ComputerName"][..] } else { &[][..] }).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()))
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "A computer".into())
}

/// Writes the reply's image to `path` and, unless the caller said picture: false, keeps it in the reply.
fn save_image(result: &mut Value, path: &std::path::Path, keep: bool) -> Result<PathBuf> {
    use base64::Engine;
    let content = result["content"].as_array_mut().ok_or_else(|| Error::msg("the reply has no content"))?;
    let index = content.iter().position(|c| c["type"] == "image").ok_or_else(|| Error::msg("the reply has no picture"))?;
    let data = base64::engine::general_purpose::STANDARD.decode(content[index]["data"].as_str().unwrap_or_default()).map_err(|_| Error::msg("the picture is not base64"))?;
    let mime = content[index]["mimeType"].as_str().unwrap_or("image/png").to_string();
    let mut path = path.to_path_buf();
    if mime == "image/jpeg" && path.extension().map(|e| e == "png").unwrap_or(false) {
        // An older Poki sends no full-size PNG: the point-sized JPEG is kept under its own name.
        path.set_extension("jpg");
    }
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(&path, &data)?;
    if !keep {
        content.remove(index);
    }
    Ok(std::fs::canonicalize(&path).unwrap_or(path))
}

async fn send_on(phone: &Phone, body: &Value) -> std::result::Result<(Value, Option<String>), (bool, Error)> {
    let mut headers: HashMap<String, String> = HashMap::from([
        ("content-type".into(), "application/json".into()),
        ("accept".into(), "application/json, text/event-stream".into()),
        ("mcp-protocol-version".into(), PROTOCOL.into()),
    ]);
    if let Some(s) = &phone.session {
        headers.insert("mcp-session-id".into(), s.clone());
    }
    let (status, session, text) = match phone.way.as_ref() {
        Way::Local(link) => {
            let a = link.request(&headers, &body.to_string(), CALL_TIMEOUT).await?;
            (a.status, a.headers.get("mcp-session-id").cloned(), a.body)
        }
        Way::Relay { url, token } => {
            let http = reqwest::Client::builder().timeout(CALL_TIMEOUT).build().map_err(|e| (false, e.into()))?;
            let mut req = http.post(url).bearer_auth(token).body(body.to_string());
            for (k, v) in &headers { req = req.header(k.as_str(), v.as_str()); }
            let res = req.send().await.map_err(|e| (e.is_connect(), Error::from(e)))?;
            let session = res.headers().get("mcp-session-id").and_then(|v| v.to_str().ok()).map(String::from);
            let status = res.status().as_u16();
            // The relay's own 503 (phone offline) means nothing reached the phone.
            if status == 503 { return Err((false, Error::msg("The relay says the phone is offline."))); }
            (status, session, res.text().await.map_err(|e| (true, e.into()))?)
        }
    };
    let value: Value = serde_json::from_str(&text).map_err(|_| (true, Error::msg(format!("The phone answered HTTP {status} with no JSON."))))?;
    Ok((value, session))
}

/// The relay, through the first connector link the person added, signed in as Poki Setup does in
/// `mcp check` (the phone may ask its owner once).
async fn relay_way() -> Result<Way> {
    let link = mcp::all()?.into_iter().next().ok_or_else(|| Error::msg("No connector link is saved on this computer."))?;
    let token = mcp::access_token(&link.url, "poki-mcp").await?;
    Ok(Way::Relay { url: link.url, token })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn without_a_phone_the_host_tools_are_listed_and_a_phone_call_says_nothing_was_sent() {
        let server = Server::offline();
        let init = server.handle(json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": PROTOCOL, "clientInfo": {"name": "claude-code"}}})).await.unwrap();
        assert_eq!(init["result"]["serverInfo"]["name"], "poki-mcp");
        let list = server.handle(json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})).await.unwrap();
        let names: Vec<&str> = list["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, vec!["look", "do", "skills", "status", "setup", "connection"]);
        assert!(list["result"]["tools"][0]["inputSchema"]["properties"]["save"].is_object());
        let look = server.handle(json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "look", "arguments": {}}})).await.unwrap();
        assert_eq!(look["result"]["isError"], true);
        assert!(look["result"]["content"][0]["text"].as_str().unwrap().contains("Nothing was sent"));
        assert!(server.handle(json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await.is_none());
    }

    #[test]
    fn look_and_do_take_save_and_the_others_do_not() {
        let look = with_save(json!({"name": "look", "inputSchema": {"type": "object", "properties": {"full": {"type": "boolean"}}}}));
        assert!(look["inputSchema"]["properties"]["save"].is_object());
        let status = with_save(json!({"name": "status", "inputSchema": {"type": "object", "properties": {}}}));
        assert!(status["inputSchema"]["properties"]["save"].is_null());
    }

    #[test]
    fn save_writes_the_png_and_keeps_the_picture_unless_told_not_to() {
        use base64::Engine;
        let dir = tempfile::tempdir().unwrap();
        let png = base64::engine::general_purpose::STANDARD.encode(b"\x89PNG fake");
        let reply = json!({"content": [{"type": "text", "text": "screen"}, {"type": "image", "data": png, "mimeType": "image/png"}]});
        let mut kept = reply.clone();
        let path = save_image(&mut kept, &dir.path().join("shots/a.png"), true).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"\x89PNG fake");
        assert_eq!(kept["content"].as_array().unwrap().len(), 2);
        let mut dropped = reply.clone();
        save_image(&mut dropped, &dir.path().join("b.png"), false).unwrap();
        assert_eq!(dropped["content"].as_array().unwrap().len(), 1);
        let mut jpeg = json!({"content": [{"type": "image", "data": png, "mimeType": "image/jpeg"}]});
        let path = save_image(&mut jpeg, &dir.path().join("c.png"), true).unwrap();
        assert_eq!(path.extension().unwrap(), "jpg");
    }
}
