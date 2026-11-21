//! Local frames, v1 (docs/ios-core.md; issue #609): this computer talks to Poki on the phone over
//! the USB cable or the same Wi-Fi, without the relay. usbmuxd forwards TCP port 47100 to the
//! phone (as iproxy does) whether it reaches the phone by cable or by Wi-Fi sync; `POKI_PHONE_ADDRESS`
//! names a phone to reach straight over TCP where usbmuxd lists no network phones (Linux).
//!
//! This computer has its own Ed25519 key, made once; the phone asks its owner the first time, then
//! remembers the key. The phone proves itself back with its relay key, whose label is pinned here
//! (from a connector link, or from the first connection), so poki-mcp never talks to another phone.
use crate::{Error, Result, device, paths};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, oneshot};

pub const PORT: u16 = 47_100;
const MAX_LINE: usize = 17 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Transport {
    Usb,
    Wifi,
    Relay,
}

impl Transport {
    pub fn as_str(self) -> &'static str {
        match self {
            Transport::Usb => "usb",
            Transport::Wifi => "wifi",
            Transport::Relay => "relay",
        }
    }
}

/// RFC 4648 base32, lowercase, no padding: a key's label, as the phone and the relay write it.
pub fn base32(data: &[u8]) -> String {
    const ALPHABET: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";
    let (mut out, mut buffer, mut bits) = (String::new(), 0u32, 0u32);
    for &b in data {
        buffer = (buffer << 8) | b as u32;
        bits += 8;
        while bits >= 5 {
            out.push(ALPHABET[((buffer >> (bits - 5)) & 31) as usize] as char);
            bits -= 5;
        }
    }
    if bits > 0 {
        out.push(ALPHABET[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    out
}

/// This computer's key, made once and kept in Poki Setup's keys folder (owner-only on macOS and Linux).
pub fn computer_key() -> Result<SigningKey> {
    let path = paths::keys_dir()?.join("computer-ed25519.key");
    if let Ok(text) = std::fs::read_to_string(&path) {
        if let Ok(seed) = B64.decode(text.trim()) {
            if let Ok(seed) = <[u8; 32]>::try_from(seed.as_slice()) {
                return Ok(SigningKey::from_bytes(&seed));
            }
        }
    }
    let seed: [u8; 32] = rand::random();
    std::fs::write(&path, B64.encode(seed))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(SigningKey::from_bytes(&seed))
}

/// The phone labels this computer trusts: from the connector links the person added, and the
/// phones it reached before (kept the first time, as SSH keeps a host key).
pub fn pinned_phones() -> Vec<String> {
    let mut labels: Vec<String> = crate::mcp::all().unwrap_or_default().iter().filter_map(|c| crate::mcp::parse(&c.url).ok().map(|p| p.label)).collect();
    labels.extend(remembered());
    labels.sort();
    labels.dedup();
    labels
}

fn remembered_path() -> Result<std::path::PathBuf> { Ok(paths::state_dir()?.join("local-phones.json")) }
fn remembered() -> Vec<String> {
    remembered_path().ok().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}
fn remember(label: &str) -> Result<()> {
    let mut all = remembered();
    if !all.iter().any(|l| l == label) {
        all.push(label.to_string());
        std::fs::write(remembered_path()?, serde_json::to_string_pretty(&all)?)?;
    }
    Ok(())
}

pub struct Hello {
    pub name: String,
    pub version: String,
    pub agent: String,
}

/// The messages each side signs (docs/ios-core.md, "Local frames, v1").
pub fn challenge_message(phone: &str, transport: Transport, nonce: &[u8]) -> Vec<u8> {
    let mut m = format!("poki-local-v1:{phone}:{}:", transport.as_str()).into_bytes();
    m.extend_from_slice(nonce);
    m
}
pub fn answer_message(computer: &str, nonce: &[u8]) -> Vec<u8> {
    let mut m = format!("poki-local-v1-phone:{computer}:").into_bytes();
    m.extend_from_slice(nonce);
    m
}

type Pending = Arc<std::sync::Mutex<HashMap<String, oneshot::Sender<Value>>>>;

/// One proven connection to the phone. Requests go side by side; a reader task hands each `res` to
/// its caller, and a keepalive pings every 25 s.
pub struct Link {
    pub transport: Transport,
    pub phone: String,
    writer: Arc<Mutex<Box<dyn tokio::io::AsyncWrite + Send + Unpin>>>,
    pending: Pending,
    next_id: AtomicU64,
    alive: Arc<std::sync::atomic::AtomicBool>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Drop for Link {
    fn drop(&mut self) {
        for t in &self.tasks {
            t.abort();
        }
    }
}

/// What came back for one request.
pub struct Answer {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: String,
}

impl Link {
    /// The handshake over an open stream. `on_wait` runs when the phone is asking its owner.
    pub async fn open<S>(stream: S, transport: Transport, hello: &Hello, on_wait: impl Fn()) -> Result<Link>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Unpin + 'static,
    {
        let key = computer_key()?;
        let id = base32(key.verifying_key().as_bytes());
        let (read, write) = tokio::io::split(stream);
        let mut reader = BufReader::new(read);
        let mut writer: Box<dyn tokio::io::AsyncWrite + Send + Unpin> = Box::new(write);
        let challenge = read_json(&mut reader, Duration::from_secs(15)).await?;
        if challenge["t"] != "challenge" || challenge["v"] != 1 {
            return Err(Error::msg("The phone did not start the Poki handshake (is Poki 0.5 or later open on it?)."));
        }
        let nonce = B64.decode(challenge["nonce"].as_str().unwrap_or_default()).map_err(|_| Error::msg("The phone's challenge has no nonce."))?;
        let phone = challenge["phone"].as_str().unwrap_or_default().to_string();
        let cnonce: [u8; 32] = rand::random();
        let sig = key.sign(&challenge_message(&phone, transport, &nonce));
        let hello = json!({
            "t": "hello", "v": 1,
            "key": B64.encode(key.verifying_key().as_bytes()),
            "sig": B64.encode(sig.to_bytes()),
            "cnonce": B64.encode(cnonce),
            "client": {"kind": "computer", "id": id, "name": hello.name, "app": "poki-mcp", "version": hello.version, "transport": transport.as_str(), "agent": hello.agent},
        });
        write_line(&mut writer, &hello.to_string()).await?;
        let ready = loop {
            // The owner has up to two minutes to allow a computer the first time.
            let frame = read_json(&mut reader, Duration::from_secs(135)).await?;
            match frame["t"].as_str() {
                Some("waiting") => on_wait(),
                Some("ready") => break frame,
                Some("close") => return Err(Error::NeedsPerson(format!("The phone refused this computer: {}.", frame["reason"].as_str().unwrap_or("no reason")))),
                _ => return Err(Error::msg("The phone answered the handshake with something unexpected.")),
            }
        };
        let phone_key = B64.decode(ready["key"].as_str().unwrap_or_default()).ok().and_then(|k| <[u8; 32]>::try_from(k.as_slice()).ok()).and_then(|k| VerifyingKey::from_bytes(&k).ok())
            .ok_or_else(|| Error::msg("The phone's ready has no key."))?;
        let label = base32(phone_key.as_bytes());
        let sig = B64.decode(ready["sig"].as_str().unwrap_or_default()).ok().and_then(|s| <[u8; 64]>::try_from(s.as_slice()).ok()).map(|s| ed25519_dalek::Signature::from_bytes(&s));
        if label != phone || sig.map(|s| phone_key.verify(&answer_message(&id, &cnonce), &s).is_err()).unwrap_or(true) {
            return Err(Error::msg("The phone did not prove its key; nothing was sent to it."));
        }
        let pinned = pinned_phones();
        if !pinned.is_empty() && !pinned.contains(&label) {
            return Err(Error::msg(format!("This phone ({}…) is not the one Poki Setup knows. Add its connector link with `poki-setup mcp add`, or remove the others.", &label[..8])));
        }
        remember(&label)?;

        let pending: Pending = Arc::default();
        let alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
        let writer = Arc::new(Mutex::new(writer));
        let read_task = {
            let (pending, alive) = (pending.clone(), alive.clone());
            tokio::spawn(async move {
                let mut line = String::new();
                loop {
                    line.clear();
                    match reader.read_line(&mut line).await {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    let text = line.trim_end();
                    if text == "pong" || text == "ping" {
                        continue;
                    }
                    let Ok(frame) = serde_json::from_str::<Value>(text) else { continue };
                    if frame["t"] == "res" {
                        if let Some(id) = frame["id"].as_str() {
                            if let Some(tx) = pending.lock().unwrap().remove(id) {
                                let _ = tx.send(frame);
                            }
                        }
                    } else if frame["t"] == "close" {
                        break;
                    }
                }
                alive.store(false, Ordering::SeqCst);
                pending.lock().unwrap().clear();
            })
        };
        let ping_task = {
            let (writer, alive) = (writer.clone(), alive.clone());
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_secs(25)).await;
                    if write_line(&mut *writer.lock().await, "ping").await.is_err() {
                        alive.store(false, Ordering::SeqCst);
                        return;
                    }
                }
            })
        };
        Ok(Link { transport, phone: label, writer, pending, next_id: AtomicU64::new(1), alive, tasks: vec![read_task, ping_task] })
    }

    pub fn is_alive(&self) -> bool { self.alive.load(Ordering::SeqCst) }

    /// One MCP request. Err(sent: false) means it never left this computer, so it may go another way.
    pub async fn request(&self, headers: &HashMap<String, String>, body: &str, timeout: Duration) -> std::result::Result<Answer, (bool, Error)> {
        if !self.is_alive() {
            return Err((false, Error::msg("The connection to the phone closed.")));
        }
        let id = format!("c{}", self.next_id.fetch_add(1, Ordering::SeqCst));
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id.clone(), tx);
        let frame = json!({"t": "req", "id": id, "method": "POST", "headers": headers, "body": body});
        if let Err(e) = write_line(&mut *self.writer.lock().await, &frame.to_string()).await {
            self.pending.lock().unwrap().remove(&id);
            return Err((false, e));
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(res)) => Ok(Answer {
                status: res["status"].as_u64().unwrap_or(502) as u16,
                headers: res["headers"].as_object().map(|h| h.iter().filter_map(|(k, v)| v.as_str().map(|s| (k.to_lowercase(), s.to_string()))).collect()).unwrap_or_default(),
                body: res["body"].as_str().unwrap_or_default().to_string(),
            }),
            Ok(Err(_)) => Err((true, Error::msg("The connection to the phone dropped during the call; what was done is unknown, so look before trying again."))),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                let _ = write_line(&mut *self.writer.lock().await, &json!({"t": "cancel", "id": id}).to_string()).await;
                Err((true, Error::msg("The phone did not answer in time; what was done is unknown, so look before trying again.")))
            }
        }
    }
}

async fn write_line(writer: &mut (dyn tokio::io::AsyncWrite + Send + Unpin), text: &str) -> Result<()> {
    let mut data = text.as_bytes().to_vec();
    data.push(b'\n');
    writer.write_all(&data).await?;
    writer.flush().await?;
    Ok(())
}

async fn read_json<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R, wait: Duration) -> Result<Value> {
    let mut line = String::new();
    let n = tokio::time::timeout(wait, reader.read_line(&mut line)).await.map_err(|_| Error::msg("The phone stopped answering the handshake."))??;
    if n == 0 || line.len() > MAX_LINE {
        return Err(Error::msg("The phone closed the connection."));
    }
    serde_json::from_str(line.trim_end()).map_err(|_| Error::msg("The phone sent something that is not JSON."))
}

/// The ways to the phone that are open right now, best first: each USB phone, then each phone
/// usbmuxd reaches over Wi-Fi, then `POKI_PHONE_ADDRESS`.
pub async fn connect(hello: &Hello, on_wait: impl Fn() + Copy) -> Result<Link> {
    let mut last: Option<Error> = None;
    if let Ok(phones) = device::Phone::list_all_links().await {
        for (phone, mux_id) in phones {
            let transport = if matches!(phone.link, device::Link::Usb) { Transport::Usb } else { Transport::Wifi };
            let opened = async {
                let mux = idevice::usbmuxd::UsbmuxdConnection::default().await?;
                let dev = mux.connect_to_device(mux_id, PORT, device::LABEL).await?;
                let socket = dev.get_socket().ok_or_else(|| Error::msg("usbmuxd gave no socket"))?;
                Link::open(socket, transport, hello, on_wait).await
            };
            match tokio::time::timeout(Duration::from_secs(150), opened).await {
                Ok(Ok(link)) => return Ok(link),
                Ok(Err(e)) => last = Some(e),
                Err(_) => last = Some(Error::msg("The phone did not answer over usbmuxd.")),
            }
        }
    }
    if let Ok(address) = std::env::var("POKI_PHONE_ADDRESS") {
        let addr = if address.contains(':') && !address.starts_with('[') && address.matches(':').count() == 1 { address.clone() } else { format!("{address}:{PORT}") };
        match tokio::time::timeout(Duration::from_secs(5), tokio::net::TcpStream::connect(&addr)).await {
            Ok(Ok(stream)) => return Link::open(stream, Transport::Wifi, hello, on_wait).await,
            Ok(Err(e)) => last = Some(e.into()),
            Err(_) => last = Some(Error::msg(format!("Nothing answered at {addr}."))),
        }
    }
    Err(last.unwrap_or_else(|| Error::msg("No phone with Poki open is on a cable or this Wi-Fi.")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base32_matches_the_phone() {
        // The label PokiCore gives FakeKey (bytes 0 to 31).
        assert_eq!(base32(&(0u8..32).collect::<Vec<_>>()), "aaaqeayeaudaocajbifqydiob4ibceqtcqkrmfyydenbwha5dypq");
        assert_eq!(base32(b"f"), "my");
        assert_eq!(base32(b"foobar"), "mzxw6ytboi");
    }

    /// A stand-in phone: runs the phone's side of the handshake over a duplex pipe.
    async fn phone(mut side: tokio::io::DuplexStream, key: SigningKey, transport_seen: Transport, answer: &'static str) {
        let label = base32(key.verifying_key().as_bytes());
        let nonce = [9u8; 32];
        side.write_all(format!("{}\n", json!({"t": "challenge", "v": 1, "nonce": B64.encode(nonce), "phone": label})).as_bytes()).await.unwrap();
        let mut reader = BufReader::new(side);
        let hello = read_json(&mut reader, Duration::from_secs(5)).await.unwrap();
        let computer = VerifyingKey::from_bytes(&<[u8; 32]>::try_from(B64.decode(hello["key"].as_str().unwrap()).unwrap().as_slice()).unwrap()).unwrap();
        let sig = ed25519_dalek::Signature::from_bytes(&<[u8; 64]>::try_from(B64.decode(hello["sig"].as_str().unwrap()).unwrap().as_slice()).unwrap());
        computer.verify(&challenge_message(&label, transport_seen, &nonce), &sig).expect("signed for this phone and transport");
        assert_eq!(hello["client"]["id"].as_str().unwrap(), base32(computer.as_bytes()));
        let cnonce = B64.decode(hello["cnonce"].as_str().unwrap()).unwrap();
        let id = base32(computer.as_bytes());
        let signer = if answer == "impostor" { SigningKey::from_bytes(&[3u8; 32]) } else { key.clone() };
        let ready = json!({"t": "ready", "v": 1, "phone": label, "key": B64.encode(key.verifying_key().as_bytes()), "sig": B64.encode(signer.sign(&answer_message(&id, &cnonce)).to_bytes())});
        let mut side = reader.into_inner();
        side.write_all(format!("{ready}\n").as_bytes()).await.unwrap();
        let mut reader = BufReader::new(side);
        let req = read_json(&mut reader, Duration::from_secs(5)).await;
        if let Ok(req) = req {
            let res = json!({"t": "res", "id": req["id"], "status": 200, "headers": {"mcp-session-id": "s1"}, "body": "{\"ok\":true}"});
            reader.into_inner().write_all(format!("{res}\n").as_bytes()).await.unwrap();
        }
    }

    #[tokio::test]
    async fn the_handshake_proves_both_sides_and_a_request_comes_back() {
        let (_guard, _home) = paths::test_home();
        let (a, b) = tokio::io::duplex(1 << 16);
        let phone_key = SigningKey::from_bytes(&[5u8; 32]);
        let served = tokio::spawn(phone(b, phone_key.clone(), Transport::Usb, "ok"));
        let link = Link::open(a, Transport::Usb, &Hello { name: "Test".into(), version: "0".into(), agent: "test".into() }, || {}).await.unwrap();
        assert_eq!(link.phone, base32(phone_key.verifying_key().as_bytes()));
        let answer = link.request(&HashMap::new(), "{}", Duration::from_secs(5)).await.map_err(|(_, e)| e).unwrap();
        assert_eq!(answer.status, 200);
        assert_eq!(answer.headers.get("mcp-session-id").map(String::as_str), Some("s1"));
        served.await.unwrap();
        assert_eq!(remembered(), vec![link.phone.clone()], "the phone is pinned after its first connection");
    }

    #[tokio::test]
    async fn a_phone_that_cannot_sign_with_its_key_is_refused() {
        let (_guard, _home) = paths::test_home();
        let (a, b) = tokio::io::duplex(1 << 16);
        let served = tokio::spawn(phone(b, SigningKey::from_bytes(&[5u8; 32]), Transport::Wifi, "impostor"));
        let err = Link::open(a, Transport::Wifi, &Hello { name: "Test".into(), version: "0".into(), agent: "test".into() }, || {}).await.err().unwrap();
        assert!(err.to_string().contains("did not prove"), "{err}");
        drop(served);
        assert!(remembered().is_empty());
    }
}
