//! GrandSlam Authentication: Apple ID sign-in with SRP, two-factor, and the Xcode app token.
//!
//! Protocol as in SideStore's icloud-auth (MPL-2.0) and Dadoum's Sideloader (GPL-3.0), written
//! again here in Rust against the plist shapes those projects document.
use super::anisette::{Headers as Anisette, Provider};
use super::srp;
use crate::{Error, Result};
use aes_gcm::aead::{Aead, Payload};
use aes_gcm::KeyInit;
use base64::Engine;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

const GS_SERVICE: &str = "https://gsa.apple.com/grandslam/GsService2";
const TRUSTED_DEVICE: &str = "https://gsa.apple.com/auth/verify/trusteddevice";
const VALIDATE: &str = "https://gsa.apple.com/grandslam/GsService2/validate";
const AUTH_INFO: &str = "https://gsa.apple.com/auth";
const SMS_START: &str = "https://gsa.apple.com/auth/verify/phone";
const SMS_CODE: &str = "https://gsa.apple.com/auth/verify/phone/securitycode";
const GSA_AGENT: &str = "akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0";
const PENDING_CODE_TTL_SECS: i64 = 600;
const PENDING_SESSION_TTL_SECS: i64 = 3600;
pub const RESEND_COOLDOWN_SECS: i64 = 60;

pub const CODE_REQUEST_LOG_TARGET: &str = "poki_setup_core::apple::code_request";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodeCaller {
    SignIn,
    IosSignIn,
    ResendCode,
    TokenRefresh,
    KeeperRenew,
    IosMaintain,
    IosPrepare,
}

impl CodeCaller {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SignIn => "sign_in",
            Self::IosSignIn => "ios_sign_in",
            Self::ResendCode => "resend_code",
            Self::TokenRefresh => "token_refresh",
            Self::KeeperRenew => "keeper_renew",
            Self::IosMaintain => "ios_maintain",
            Self::IosPrepare => "ios_prepare",
        }
    }
}

static CODE_REQUEST_HOOK: std::sync::OnceLock<fn(&str)> = std::sync::OnceLock::new();

pub fn set_code_request_hook(hook: fn(&str)) {
    let _ = CODE_REQUEST_HOOK.set(hook);
}

fn log_code_request(path: &'static str, caller: CodeCaller) {
    let line = format!("2fa-code-request path={path} caller={}", caller.as_str());
    tracing::info!(target: CODE_REQUEST_LOG_TARGET, "{line}");
    if let Some(hook) = CODE_REQUEST_HOOK.get() {
        hook(&line);
    }
}

#[derive(Debug, Clone)]
pub(crate) struct Endpoints {
    pub gs_service: String,
    pub trusted_device: String,
    pub validate: String,
    pub auth_info: String,
    pub sms_start: String,
    pub sms_code: String,
}

impl Endpoints {
    pub fn apple() -> Self {
        Self {
            gs_service: GS_SERVICE.into(),
            trusted_device: TRUSTED_DEVICE.into(),
            validate: VALIDATE.into(),
            auth_info: AUTH_INFO.into(),
            sms_start: SMS_START.into(),
            sms_code: SMS_CODE.into(),
        }
    }

    #[cfg(test)]
    pub fn local(base: &str) -> Self {
        Self {
            gs_service: format!("{base}/grandslam/GsService2"),
            trusted_device: format!("{base}/auth/verify/trusteddevice"),
            validate: format!("{base}/grandslam/GsService2/validate"),
            auth_info: format!("{base}/auth"),
            sms_start: format!("{base}{}", SMS_START.trim_start_matches("https://gsa.apple.com")),
            sms_code: format!("{base}/auth/verify/phone/securitycode"),
        }
    }
}

/// What a sign-in leaves behind. `gs_idms_token` + `adsid` identify the session to Apple;
/// `sk`/`c` let us ask for app tokens again without the password.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub apple_id: String,
    pub adsid: String,
    pub gs_idms_token: String,
    pub first_name: String,
    pub last_name: String,
    #[serde(with = "b64")]
    pub sk: Vec<u8>,
    #[serde(with = "b64")]
    pub c: Vec<u8>,
}

mod b64 {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(v: &Vec<u8>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(v))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD.decode(s).map_err(serde::de::Error::custom)
    }
}

/// A token for one app (we only ever ask for Xcode's).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppToken {
    pub app: String,
    pub token: String,
    /// Unix seconds.
    pub expires_at: i64,
}

impl AppToken {
    pub fn valid_for(&self, secs: i64) -> bool { self.expires_at - time::OffsetDateTime::now_utc().unix_timestamp() > secs }
}

/// How the sign-in ended.
#[derive(Debug)]
pub enum Outcome {
    SignedIn(Session),
    /// Apple wants a second factor. Keep the [`Pending`] and call `trusted_device_code` or `sms_code`.
    NeedsCode(Pending),
}

/// A sign-in waiting for the 2FA code. Serializable so the command line can finish it in a
/// second run (`poki-setup login --code`); it is kept in the keychain, never in a file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pending {
    pub apple_id: String,
    password: String,
    #[serde(default)]
    pub keep_password: bool,
    session: Session,
    pub via: Factor,
    /// The trusted phone number Apple texted (its id in Apple's list), for an SMS sign-in.
    phone_id: u64,
    #[serde(default)]
    pub anisette: Option<super::anisette::Source>,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub last_sent_at: i64,
    #[serde(default)]
    pub failed_attempts: u32,
    #[serde(default)]
    cookies: Vec<(String, String)>,
    #[serde(default)]
    idms_session_id: Option<String>,
    #[serde(default)]
    scnt: Option<String>,
}

impl Pending {
    pub fn is_fresh(&self, now: i64) -> bool {
        self.created_at == 0 || (now >= self.created_at && now - self.created_at < PENDING_SESSION_TTL_SECS)
    }

    pub fn is_code_fresh(&self, now: i64) -> bool {
        let sent = self.last_sent_at.max(self.created_at);
        sent == 0 || (now >= sent && now - sent < PENDING_CODE_TTL_SECS)
    }

    pub fn is_fresh_for(&self, apple_id: &str, now: i64) -> bool {
        self.is_code_fresh(now) && self.apple_id.eq_ignore_ascii_case(apple_id.trim())
    }

    pub fn resend_available_at(&self) -> i64 {
        let sent = self.last_sent_at.max(self.created_at);
        if sent == 0 { 0 } else { sent + RESEND_COOLDOWN_SECS }
    }

    pub fn resend_wait_secs(&self, now: i64) -> i64 {
        (self.resend_available_at() - now).max(0)
    }

    pub(crate) fn password_str(&self) -> &str {
        &self.password
    }

    pub(crate) fn same_challenge(&self, other: &Pending) -> bool {
        self.session.gs_idms_token == other.session.gs_idms_token
            && self.apple_id.eq_ignore_ascii_case(&other.apple_id)
    }

    fn record_headers(&mut self, headers: &reqwest::header::HeaderMap) {
        if let Some(id) = headers.get("x-apple-id-session-id").and_then(|v| v.to_str().ok()) {
            if !id.is_empty() {
                self.idms_session_id = Some(id.to_string());
            }
        }
        if let Some(scnt) = headers.get("scnt").and_then(|v| v.to_str().ok()) {
            if !scnt.is_empty() {
                self.scnt = Some(scnt.to_string());
            }
        }
        for raw in headers.get_all(reqwest::header::SET_COOKIE) {
            let Ok(text) = raw.to_str() else { continue };
            let Some(pair) = text.split(';').next() else { continue };
            let Some((name, val)) = pair.split_once('=') else { continue };
            let (name, val) = (name.trim().to_string(), val.trim().to_string());
            if name.is_empty() {
                continue;
            }
            if let Some(existing) = self.cookies.iter_mut().find(|(k, _)| k == &name) {
                existing.1 = val;
            } else {
                self.cookies.push((name, val));
            }
        }
    }

    fn cookie_header(&self) -> Option<String> {
        format_cookies(&self.cookies)
    }

    fn wrong_code_error(&mut self) -> Error {
        self.failed_attempts = self.failed_attempts.saturating_add(1);
        wrong_code_message(self.failed_attempts)
    }
}

fn format_cookies(cookies: &[(String, String)]) -> Option<String> {
    if cookies.is_empty() {
        return None;
    }
    Some(cookies.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; "))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Factor {
    TrustedDevice,
    Sms,
}

pub struct Client {
    http: reqwest::Client,
    anisette: Provider,
    endpoints: Endpoints,
}

type HmacSha256 = Hmac<Sha256>;

fn dict<'a>(v: &'a plist::Value, key: &str) -> Option<&'a plist::Value> { v.as_dictionary()?.get(key) }
fn s<'a>(v: &'a plist::Value, key: &str) -> Option<&'a str> { dict(v, key)?.as_string() }
fn data<'a>(v: &'a plist::Value, key: &str) -> Option<&'a [u8]> { dict(v, key)?.as_data() }

struct Status {
    ec: i64,
    em: String,
    hsc: i64,
    au: Option<String>,
}

fn status(response: &plist::Value) -> Status {
    let st = dict(response, "Status");
    let int = |k: &str| st.and_then(|s| dict(s, k)).and_then(|v| v.as_signed_integer()).unwrap_or(0);
    Status {
        ec: int("ec"),
        em: st.and_then(|s0| s(s0, "em")).unwrap_or("").to_string(),
        hsc: int("hsc"),
        au: st.and_then(|s0| s(s0, "au")).map(|a| a.to_string()),
    }
}

fn apple_error(st: &Status) -> Error {
    tracing::warn!("Apple sign-in status ec={} hsc={} em={:?}", st.ec, st.hsc, st.em);
    // -22411 is a rate limit only with 503. With 401 Apple turned the session away: after a
    // verified code, an app token asked for with the 409 session from before the code gets this.
    if st.ec == -22411 && st.hsc != 503 {
        return Error::NeedsPerson(SESSION_REJECTED.into());
    }
    if is_rate_limit_code_or_text(st.ec, &st.em) {
        return rate_limited();
    }
    let text = match st.ec {
        -20101 | -22406 | -20970 => "Apple ID or password is wrong.".to_string(),
        -20209 | -20751 => "This Apple ID is locked. Unlock it at iforgot.apple.com and try again.".to_string(),
        -22421 => "Apple refused the sign-in from this computer's identity (anisette). Try again in a minute, or choose another anisette server in Settings.".to_string(),
        -23782 => "Apple refused the Mac identity Poki signs in with (it asks for macOS 10.13 or later). Update Poki and Poki Setup to the latest version, then try again.".to_string(),
        -20283 => "Apple asked for a passcode or trusted device that this computer cannot provide. Enable two-factor authentication on this Apple ID and try again.".to_string(),
        _ if st.em.is_empty() => format!("Apple's sign-in failed with code {}.", st.ec),
        _ => st.em.clone(),
    };
    Error::apple(st.ec, text)
}

impl Client {
    pub fn new(anisette: Provider) -> Result<Client> { Self::with_endpoints(anisette, Endpoints::apple()) }

    pub(crate) fn with_endpoints(anisette: Provider, endpoints: Endpoints) -> Result<Client> {
        Ok(Client { http: super::http_client()?, anisette, endpoints })
    }

    pub fn anisette(&mut self) -> &mut Provider { &mut self.anisette }

    async fn gs_request(&self, headers: &Anisette, request: plist::Dictionary) -> Result<plist::Value> {
        self.gs_request_with_cookies(headers, request, &[]).await
    }

    async fn gs_request_with_cookies(&self, headers: &Anisette, request: plist::Dictionary, cookies: &[(String, String)]) -> Result<plist::Value> {
        let mut header = plist::Dictionary::new();
        header.insert("Version".into(), "1.0.1".into());
        let mut root = plist::Dictionary::new();
        root.insert("Header".into(), plist::Value::Dictionary(header));
        root.insert("Request".into(), plist::Value::Dictionary(request));
        let mut body = Vec::new();
        plist::to_writer_xml(&mut body, &plist::Value::Dictionary(root))?;
        let mut req = self
            .http
            .post(&self.endpoints.gs_service)
            .header("Content-Type", "text/x-xml-plist")
            .header("Accept", "text/x-xml-plist")
            .header("X-Apple-App-Info", super::XCODE_APP_ID)
            .header("X-Xcode-Version", super::XCODE_VERSION)
            .header("Connection", "close")
            .header("User-Agent", headers.get("User-Agent").unwrap_or(GSA_AGENT))
            .header("X-MMe-Client-Info", headers.get("X-Mme-Client-Info").unwrap_or(""));
        if let Some(cookie) = format_cookies(cookies) {
            req = req.header(reqwest::header::COOKIE, cookie);
        }
        let res = req.body(body).send().await?;
        let http_status = res.status();
        if http_status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(rate_limited());
        }
        let bytes = res.bytes().await?;
        if let Ok(v) = plist::from_bytes::<plist::Value>(&bytes) {
            if let Some(resp) = dict(&v, "Response").cloned() {
                if http_status.is_success() || status(&resp).ec != 0 {
                    return Ok(resp);
                }
            }
            let root_st = status(&v);
            if root_st.ec != 0 {
                return Err(apple_error(&root_st));
            }
        }
        if http_status == reqwest::StatusCode::SERVICE_UNAVAILABLE {
            return Err(Error::msg("Apple's sign-in service is temporarily unavailable (HTTP 503). Wait a few minutes, then try signing in again."));
        }
        if !http_status.is_success() {
            return Err(Error::msg(format!("Apple's sign-in service answered HTTP {http_status}.")));
        }
        let v: plist::Value = plist::from_bytes(&bytes)?;
        dict(&v, "Response").cloned().ok_or_else(|| Error::msg("Apple's sign-in service gave an answer without a Response"))
    }

    /// Signs in. Returns `NeedsCode` when Apple wants a second factor.
    ///
    /// When Apple refuses the anisette identity (-80045/-80046) the next fallback server is tried.
    /// That is a different "Mac" to Apple, so it is only done here, before any code was asked for.
    pub async fn sign_in(&mut self, apple_id: &str, password: &str) -> Result<Outcome> {
        self.sign_in_with_caller(apple_id, password, CodeCaller::SignIn).await
    }

    pub async fn sign_in_with_caller(&mut self, apple_id: &str, password: &str, caller: CodeCaller) -> Result<Outcome> {
        loop {
            match self.sign_in_once(apple_id, password, caller).await {
                Err(Error::Apple { code: -80045, .. }) | Err(Error::Apple { code: -80046, .. }) if self.anisette.rotate() => continue,
                other => return other,
            }
        }
    }

    async fn sign_in_once(
        &mut self,
        apple_id: &str,
        password: &str,
        caller: CodeCaller,
    ) -> Result<Outcome> {
        let anisette = self.anisette.headers().await?;
        let (session, st) = self.srp_sign_in(apple_id, password, &anisette).await?;
        tracing::info!("sign-in answered hsc {} au {:?}", st.hsc, st.au);
        let now = time::OffsetDateTime::now_utc().unix_timestamp();
        let make_pending = |via: Factor, phone_id: u64, session: Session| Pending {
            apple_id: apple_id.trim().into(),
            password: password.into(),
            keep_password: false,
            session,
            via,
            phone_id,
            anisette: Some(self.anisette.source().clone()),
            created_at: now,
            last_sent_at: now,
            failed_attempts: 0,
            cookies: Vec::new(),
            idms_session_id: None,
            scnt: None,
        };
        match next_step(st.hsc, st.au.as_deref()) {
            Step::SignedIn => Ok(Outcome::SignedIn(session)),
            Step::CodeAlreadySent => {
                log_code_request("auto_push_409", caller);
                tracing::info!("Apple sent the code to the trusted devices by itself (hsc 409, no au)");
                Ok(Outcome::NeedsCode(make_pending(Factor::TrustedDevice, 0, session)))
            }
            Step::AskTrustedDevice => {
                let mut pending = make_pending(Factor::TrustedDevice, 0, session);
                self.start_trusted_device(&mut pending, caller).await?;
                Ok(Outcome::NeedsCode(pending))
            }
            Step::AskSms => {
                let mut pending = make_pending(Factor::Sms, 1, session);
                let phone_id = self.start_sms(&mut pending, caller).await?;
                pending.phone_id = phone_id;
                Ok(Outcome::NeedsCode(pending))
            }
            Step::Repair if !session.sk.is_empty() && !session.c.is_empty() => {
                tracing::warn!("Apple asked to repair the account (au repair); continuing with the session");
                Ok(Outcome::SignedIn(session))
            }
            Step::Repair => Err(Error::NeedsPerson("Apple wants something on this Apple Account fixed before it can be used here. Sign in at account.apple.com, turn on two-factor authentication and accept any new terms, then sign in again.".into())),
            Step::Unsupported(other) => Err(Error::msg(format!("Apple asked for a verification step this app does not support ({other})."))),
        }
    }

    /// The password step (SRP init and complete) with the given anisette headers. It only reads
    /// Apple's answer and never asks for a code.
    async fn srp_sign_in(&self, apple_id: &str, password: &str, anisette: &Anisette) -> Result<(Session, Status)> {
        let apple_id_clean = apple_id.trim().to_lowercase();
        let mut client = srp::Client::new();

        let mut init = plist::Dictionary::new();
        init.insert("A2k".into(), plist::Value::Data(client.a_pub.clone()));
        init.insert("cpd".into(), plist::Value::Dictionary(anisette.cpd()));
        init.insert("o".into(), "init".into());
        init.insert("ps".into(), plist::Value::Array(vec!["s2k".into(), "s2k_fo".into()]));
        init.insert("u".into(), apple_id_clean.clone().into());
        let r1 = self.gs_request(anisette, init).await?;
        let st = status(&r1);
        if st.ec != 0 {
            return Err(apple_error(&st));
        }
        let sp = s(&r1, "sp").unwrap_or("s2k");
        let salt = data(&r1, "s").ok_or_else(|| Error::msg("sign-in: no salt"))?.to_vec();
        let iterations = dict(&r1, "i").and_then(|v| v.as_signed_integer()).ok_or_else(|| Error::msg("sign-in: no iteration count"))? as u32;
        let b_pub = data(&r1, "B").ok_or_else(|| Error::msg("sign-in: no B"))?.to_vec();
        let c_value = dict(&r1, "c").cloned().unwrap_or(plist::Value::String(String::new()));

        let derived = srp::Client::derive_password(password, &salt, iterations, sp == "s2k_fo");
        let m1 = client.process(&apple_id_clean, &derived, &salt, &b_pub).map_err(Error::msg)?;

        let mut complete = plist::Dictionary::new();
        complete.insert("c".into(), c_value);
        complete.insert("M1".into(), plist::Value::Data(m1));
        complete.insert("cpd".into(), plist::Value::Dictionary(anisette.cpd()));
        complete.insert("o".into(), "complete".into());
        complete.insert("u".into(), apple_id_clean.clone().into());
        let r2 = self.gs_request(anisette, complete).await?;
        let st = status(&r2);
        if st.ec != 0 {
            return Err(apple_error(&st));
        }
        let m2 = data(&r2, "M2").ok_or_else(|| Error::msg("sign-in: no M2"))?;
        if !client.verify_server(m2) {
            return Err(Error::msg("Apple's sign-in answer did not verify (M2 mismatch). Check the clock on this computer and try again."));
        }
        let spd = data(&r2, "spd").ok_or_else(|| Error::msg("sign-in: no spd"))?;
        let spd = decrypt_spd(client.key(), spd)?;
        let session = Session {
            apple_id: apple_id.trim().to_string(),
            adsid: s(&spd, "adsid").unwrap_or("").to_string(),
            gs_idms_token: s(&spd, "GsIdmsToken").unwrap_or("").to_string(),
            first_name: s(&spd, "fn").unwrap_or("").to_string(),
            last_name: s(&spd, "ln").unwrap_or("").to_string(),
            sk: data(&spd, "sk").unwrap_or(&[]).to_vec(),
            c: data(&spd, "c").unwrap_or(&[]).to_vec(),
        };
        if session.adsid.is_empty() || session.gs_idms_token.is_empty() {
            return Err(Error::msg("Apple's sign-in answer had no account token."));
        }
        Ok((session, st))
    }

    fn twofa_request(&self, rb: reqwest::RequestBuilder, pending: &Pending, anisette: &Anisette) -> reqwest::RequestBuilder {
        self.twofa_request_as(rb, pending, anisette, "text/x-xml-plist")
    }

    /// The 2FA headers with one Content-Type and Accept (`kind`). Uses the same `User-Agent` and
    /// `X-MMe-Client-Info` as `gs_request` so Apple sees one consistent client identity throughout.
    fn twofa_request_as(&self, rb: reqwest::RequestBuilder, pending: &Pending, anisette: &Anisette, kind: &str) -> reqwest::RequestBuilder {
        let identity = base64::engine::general_purpose::STANDARD.encode(format!("{}:{}", pending.session.adsid, pending.session.gs_idms_token));
        let mut rb = rb
            .header("X-Apple-Identity-Token", identity)
            .header("X-Apple-App-Info", super::XCODE_APP_ID)
            .header("X-Xcode-Version", super::XCODE_VERSION)
            .header("Content-Type", kind)
            .header("Accept", kind)
            .header("Accept-Language", "en-us")
            .header("Connection", "close")
            .header("User-Agent", anisette.get("User-Agent").unwrap_or(GSA_AGENT));
        for (k, v) in &anisette.map {
            if k.eq_ignore_ascii_case("User-Agent") {
                continue;
            }
            rb = rb.header(k.as_str(), v.as_str());
        }
        if let Some(loc) = anisette.map.get("X-Apple-Locale") {
            rb = rb.header("Loc", loc.as_str());
        }
        if let Some(id) = &pending.idms_session_id {
            rb = rb.header("X-Apple-ID-Session-Id", id.as_str());
        }
        if let Some(scnt) = &pending.scnt {
            rb = rb.header("scnt", scnt.as_str());
        }
        if let Some(cookie) = pending.cookie_header() {
            rb = rb.header(reqwest::header::COOKIE, cookie);
        }
        rb
    }

    async fn start_trusted_device(&mut self, pending: &mut Pending, caller: CodeCaller) -> Result<()> {
        let anisette = self.anisette.headers_pinned().await?;
        log_code_request("ask_trusted_device", caller);
        let res = self.twofa_request(self.http.get(&self.endpoints.trusted_device), pending, &anisette).send().await?;
        pending.record_headers(res.headers());
        let status = res.status();
        let bytes = res.bytes().await.unwrap_or_default();
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(rate_limited());
        }
        if let Ok(v) = plist::from_bytes::<plist::Value>(&bytes) {
            let ec = dict(&v, "ec").and_then(|e| e.as_signed_integer()).unwrap_or(0);
            let em = s(&v, "em").unwrap_or("");
            if is_rate_limit_code_or_text(ec, em) {
                return Err(rate_limited());
            }
            if ec != 0 {
                return Err(Error::apple(ec, format!("Apple could not send a code to your devices: {} ({ec}).", if em.is_empty() { "no reason given" } else { em })));
            }
        }
        if !status.is_success() {
            return Err(Error::msg(format!("Apple could not send a code to your devices (HTTP {status}). Wait a moment before trying again, or get a code on a device: Settings > [your name] > Sign-In & Security > Two-Factor Authentication > Get Verification Code.")));
        }
        tracing::info!("trusted-device code requested (HTTP {status}, {} bytes)", bytes.len());
        Ok(())
    }

    async fn start_sms(&mut self, pending: &mut Pending, caller: CodeCaller) -> Result<u64> {
        let anisette = self.anisette.headers_pinned().await?;
        let mut phone_id = 1u64;
        let info_res = self.twofa_request_as(self.http.get(&self.endpoints.auth_info), pending, &anisette, "application/json").send().await?;
        pending.record_headers(info_res.headers());
        let info_status = info_res.status();
        if info_status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(rate_limited());
        }
        let already_sent = info_status.as_u16() == 201;
        tracing::info!("2FA info answered HTTP {info_status}");
        if let Ok(v) = info_res.json::<serde_json::Value>().await {
            if json_indicates_rate_limit(&v) {
                return Err(rate_limited());
            }
            if let Some(id) = first_phone_id(&v) {
                phone_id = id;
            }
        }
        if already_sent {
            log_code_request("ask_sms", caller);
            return Ok(phone_id);
        }
        self.send_sms_to_phone(pending, phone_id, caller).await?;
        Ok(phone_id)
    }

    async fn send_sms_to_phone(&mut self, pending: &mut Pending, phone_id: u64, caller: CodeCaller) -> Result<()> {
        let anisette = self.anisette.headers_pinned().await?;
        log_code_request("ask_sms", caller);
        let body = serde_json::json!({ "phoneNumber": { "id": phone_id }, "mode": "sms" });
        let res = self
            .twofa_request_as(self.http.put(&self.endpoints.sms_start), pending, &anisette, "application/json")
            .body(body.to_string())
            .send()
            .await?;
        pending.record_headers(res.headers());
        let status = res.status();
        if status.is_success() {
            tracing::info!("SMS code requested (PUT, HTTP {status})");
            return Ok(());
        }
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(rate_limited());
        }
        let text = res.text().await.unwrap_or_default();
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
            if json_indicates_rate_limit(&v) {
                return Err(rate_limited());
            }
            if status.as_u16() == 412 || json_service_error_code(&v).is_some_and(|c| matches!(c, "-22979" | "-22981")) {
                tracing::info!("SMS challenge already active on Apple's side; waiting for the code already sent");
                return Ok(());
            }
        }
        tracing::warn!("SMS request PUT answered {status}");
        Err(Error::msg(format!(
            "Apple could not text a code to your phone number (HTTP {status}). Use a code from one of your Apple devices instead: on an iPhone, iPad or Mac signed in to this Apple Account, open Settings > [your name] > Sign-In & Security > Two-Factor Authentication > Get Verification Code."
        )))
    }

    pub async fn resend(&mut self, pending: &mut Pending, now: i64) -> Result<()> {
        pending.last_sent_at = now;
        if let Some(src) = &pending.anisette {
            self.anisette.pin_source(src.clone());
        }
        match pending.via {
            Factor::TrustedDevice => self.start_trusted_device(pending, CodeCaller::ResendCode).await?,
            Factor::Sms => self.send_sms_to_phone(pending, pending.phone_id.max(1), CodeCaller::ResendCode).await?,
        }
        pending.failed_attempts = 0;
        Ok(())
    }

    async fn check_device_code(&self, pending: &mut Pending, anisette: &Anisette, code: &str) -> Result<()> {
        let res = self.twofa_request(self.http.get(&self.endpoints.validate), pending, anisette).header("security-code", code).send().await?;
        pending.record_headers(res.headers());
        let status = res.status().as_u16();
        let bytes = res.bytes().await?;
        device_code_answer(status, &bytes)
    }

    async fn check_sms_code(&self, pending: &mut Pending, anisette: &Anisette, code: &str) -> Result<()> {
        let body = serde_json::json!({ "phoneNumber": { "id": pending.phone_id }, "securityCode": { "code": code }, "mode": "sms" });
        let res = self
            .twofa_request_as(self.http.post(&self.endpoints.sms_code), pending, anisette, "application/json")
            .body(body.to_string())
            .send()
            .await?;
        pending.record_headers(res.headers());
        let status = res.status().as_u16();
        let bytes = res.bytes().await.unwrap_or_default();
        sms_code_answer(status, &bytes)
    }

    /// Finishes a 2FA sign-in with the code the person typed.
    pub async fn finish(&mut self, pending: &mut Pending, code: &str) -> Result<Session> {
        let code = code.trim();
        if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
            return Err(Error::NeedsPerson("The code is six digits.".into()));
        }
        let now = time::OffsetDateTime::now_utc().unix_timestamp();
        if !pending.is_code_fresh(now) {
            return Err(expired_code());
        }
        if let Some(src) = &pending.anisette {
            self.anisette.pin_source(src.clone());
        }
        let anisette = self.anisette.headers_pinned().await?;
        let check = match pending.via {
            Factor::TrustedDevice => self.check_device_code(pending, &anisette, code).await,
            Factor::Sms => self.check_sms_code(pending, &anisette, code).await,
        };
        if let Err(err) = check {
            if is_wrong_code(&err) {
                return Err(pending.wrong_code_error());
            }
            return Err(err);
        }
        if pending.session.sk.is_empty() || pending.session.c.is_empty() {
            return Err(incomplete_session());
        }
        // Apple has checked the code, so this anisette identity is trusted now. Sign in once more
        // with it to get the full session: Apple turns away app-token requests made with the 409
        // session from before the code (hsc 401, ec -22411). This sign-in only reads Apple's
        // answer and never asks for a code, so a sign-in still costs at most one code.
        let anisette = self.anisette.headers_pinned().await?;
        match self.srp_sign_in(&pending.apple_id, &pending.password, &anisette).await {
            Ok((session, st)) if signed_in_with_keys(&session, &st) => {
                tracing::info!("signed in again after the code: hsc {}", st.hsc);
                Ok(session)
            }
            Ok((_, st)) => {
                tracing::warn!("Apple still asked for a second factor after the code (hsc {} au {:?}); using the session from before the code", st.hsc, st.au);
                Ok(pending.session.clone())
            }
            Err(e) if is_rate_limit(&e) => Err(e),
            Err(e) => {
                tracing::warn!("signing in again after the code failed ({e}); using the session from before the code");
                Ok(pending.session.clone())
            }
        }
    }

    /// The app token for Xcode's services, which the developer portal wants.
    pub async fn xcode_token(&mut self, session: &Session) -> Result<AppToken> {
        self.app_token(session, super::XCODE_APP_ID).await
    }

    pub async fn app_token(&mut self, session: &Session, app: &str) -> Result<AppToken> {
        let anisette = self.anisette.headers().await?;
        let mut mac = <HmacSha256 as Mac>::new_from_slice(&session.sk).map_err(|_| Error::msg("session key is empty; sign in again"))?;
        mac.update(b"apptokens");
        mac.update(session.adsid.as_bytes());
        mac.update(app.as_bytes());
        let checksum = mac.finalize().into_bytes().to_vec();
        let mut req = plist::Dictionary::new();
        req.insert("app".into(), plist::Value::Array(vec![app.into()]));
        req.insert("c".into(), plist::Value::Data(session.c.clone()));
        req.insert("checksum".into(), plist::Value::Data(checksum));
        req.insert("cpd".into(), plist::Value::Dictionary(anisette.cpd()));
        req.insert("o".into(), "apptokens".into());
        req.insert("t".into(), session.gs_idms_token.clone().into());
        req.insert("u".into(), session.adsid.clone().into());
        let r = self.gs_request(&anisette, req).await?;
        let st = status(&r);
        if st.ec != 0 {
            return Err(match st.ec {
                -20101 | -22406 | -21212 => Error::NeedsPerson(SESSION_EXPIRED.into()),
                _ => apple_error(&st),
            });
        }
        let et = data(&r, "et").ok_or_else(|| Error::msg("Apple gave no app token"))?;
        let tokens = decrypt_gcm(&session.sk, et)?;
        let entry = dict(&tokens, "t").and_then(|t| dict(t, app)).ok_or_else(|| Error::msg("Apple's app token answer had no Xcode token"))?;
        let token = s(entry, "token").ok_or_else(|| Error::msg("app token without a token"))?.to_string();
        let expiry = dict(entry, "expiry").and_then(|e| e.as_signed_integer()).unwrap_or(0);
        // Apple sends milliseconds since 1970.
        let expires_at = if expiry > 10_000_000_000 { expiry / 1000 } else { expiry };
        Ok(AppToken { app: app.to_string(), token, expires_at })
    }
}

/// What a finished password step asks for next.
#[derive(Debug, PartialEq, Eq)]
enum Step<'a> {
    SignedIn,
    /// 409 with no `au`: Apple pushed a code to the trusted devices on its own.
    CodeAlreadySent,
    /// `trustedDeviceSecondaryAuth`: ask once for a trusted-device push, never SMS.
    AskTrustedDevice,
    /// `secondaryAuth`: ask once for an SMS code, never a trusted-device push.
    AskSms,
    /// `repair`: Apple wants the account fixed (often two-factor authentication turned on).
    Repair,
    Unsupported(&'a str),
}

/// A password step that opened a session good for app tokens: signed in, or the repair answer
/// that still carries the session keys.
fn signed_in_with_keys(session: &Session, st: &Status) -> bool {
    let keys = !session.sk.is_empty() && !session.c.is_empty();
    match next_step(st.hsc, st.au.as_deref()) {
        Step::SignedIn | Step::Repair => keys,
        _ => false,
    }
}

fn next_step(hsc: i64, au: Option<&str>) -> Step<'_> {
    match au {
        Some("trustedDeviceSecondaryAuth") => Step::AskTrustedDevice,
        Some("secondaryAuth") => Step::AskSms,
        Some("repair") => Step::Repair,
        Some(other) => Step::Unsupported(other),
        None if hsc == 409 => Step::CodeAlreadySent,
        None => Step::SignedIn,
    }
}

pub const RATE_LIMITED: &str = "Apple has had too many sign-in attempts or codes for this Apple Account. Wait about an hour before you sign in again, because each new try asks Apple for another code.";
pub const SESSION_EXPIRED: &str = "Your Apple session has expired. Sign in again.";
const WRONG_CODE_MARKER: &str = "That verification code is incorrect.";
pub const WRONG_CODE_FIRST: &str = "That verification code is incorrect. Check the 6-digit code and enter the newest code you received.";
pub const WRONG_CODE_WAIT: &str = "That verification code is incorrect. Stop and wait a few minutes before trying again so Apple does not lock this Apple Account, then enter the newest 6-digit code.";
pub const EXPIRED_CODE: &str = "That verification code has expired. Enter the newest 6-digit code, or request a new code.";
/// Apple's -22411 with any status but 503: it turned this session away, which is not a rate limit.
pub const SESSION_REJECTED: &str = "Apple did not accept this sign-in (error -22411). Sign out, then sign in again.";
pub const INCOMPLETE_SESSION: &str = "Apple verified the code, but did not finish opening the session. Sign in again to start a fresh session.";

pub fn rate_limited() -> Error { Error::NeedsPerson(RATE_LIMITED.into()) }

pub fn expired_code() -> Error { Error::NeedsPerson(EXPIRED_CODE.into()) }

pub fn incomplete_session() -> Error { Error::NeedsPerson(INCOMPLETE_SESSION.into()) }

pub fn is_incomplete_session(e: &Error) -> bool {
    matches!(e, Error::NeedsPerson(m) if m == INCOMPLETE_SESSION)
}

pub fn is_rate_limit(e: &Error) -> bool {
    match e {
        Error::NeedsPerson(m) => m == RATE_LIMITED || m.to_ascii_lowercase().contains("too many sign-in attempts or codes"),
        Error::Apple { code, message } => is_rate_limit_code_or_text(*code, message),
        _ => false,
    }
}

pub fn is_session_expired(e: &Error) -> bool {
    matches!(e, Error::NeedsPerson(m) if m == SESSION_EXPIRED)
        || matches!(e, Error::Apple { code: -20101 | -22406 | -21212, .. })
}

fn is_wrong_code(e: &Error) -> bool {
    matches!(e, Error::NeedsPerson(m) if m.starts_with(WRONG_CODE_MARKER))
}

fn wrong_code_message(failed_attempts: u32) -> Error {
    if failed_attempts >= 2 {
        Error::NeedsPerson(WRONG_CODE_WAIT.into())
    } else {
        Error::NeedsPerson(WRONG_CODE_FIRST.into())
    }
}

fn is_expired_code_or_text(ec: i64, em: &str) -> bool {
    let lower = em.to_ascii_lowercase();
    matches!(ec, -21670 | -22980 | -20554) || lower.contains("expired") || lower.contains("timed out")
}

fn is_rate_limit_code_or_text(ec: i64, em: &str) -> bool {
    let lower = em.to_ascii_lowercase();
    matches!(ec, -22411 | -36607)
        || lower.contains("too many")
        || lower.contains("verification codes") && lower.contains("try again later")
}

fn json_service_error_code(v: &serde_json::Value) -> Option<&str> {
    v.get("serviceErrors")?.as_array()?.first()?.get("code")?.as_str()
}

fn json_indicates_expired_code(v: &serde_json::Value) -> bool {
    if v.get("securityCode").and_then(|sc| sc.get("codeExpired")).and_then(|b| b.as_bool()) == Some(true) {
        return true;
    }
    if let Some(err) = v.get("serviceErrors").and_then(|a| a.as_array()).and_then(|a| a.first()) {
        let code = err.get("code").and_then(|c| c.as_str()).unwrap_or("");
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("");
        let code_num = code.parse::<i64>().unwrap_or(0);
        if is_expired_code_or_text(code_num, msg) {
            return true;
        }
    }
    false
}

fn json_indicates_rate_limit(v: &serde_json::Value) -> bool {
    if let Some(sc) = v.get("securityCode") {
        let flag = |k: &str| sc.get(k).and_then(|b| b.as_bool()).unwrap_or(false);
        if flag("tooManyCodesSent") || flag("tooManyCodesValidated") || flag("securityCodeLocked") || flag("securityCodeCooldown") {
            return true;
        }
    }
    if let Some(err) = v.get("serviceErrors").and_then(|a| a.as_array()).and_then(|a| a.first()) {
        let code = err.get("code").and_then(|c| c.as_str()).unwrap_or("");
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("");
        let code_num = code.parse::<i64>().unwrap_or(0);
        if is_rate_limit_code_or_text(code_num, msg) {
            return true;
        }
    }
    false
}

/// Reads Apple's answer to a device code. Only an answer that says `ec` 0 (at the top or under
/// `Status`) counts as accepted; an error page or an empty answer is not.
fn device_code_answer(status: u16, bytes: &[u8]) -> Result<()> {
    if status == 429 {
        return Err(rate_limited());
    }
    if status == 410 {
        return Err(expired_code());
    }
    let v = plist::from_bytes::<plist::Value>(bytes).ok();
    let ec_of = |d: &plist::Value| dict(d, "ec").and_then(|e| e.as_signed_integer());
    let ec = v.as_ref().and_then(|v| ec_of(v).or_else(|| dict(v, "Status").and_then(ec_of)));
    let em = v.as_ref().and_then(|v| s(v, "em").or_else(|| dict(v, "Status").and_then(|st| s(st, "em")))).unwrap_or("");
    if let Some(ec) = ec {
        if is_rate_limit_code_or_text(ec, em) {
            return Err(rate_limited());
        }
        if is_expired_code_or_text(ec, em) {
            return Err(expired_code());
        }
    }
    match ec {
        Some(0) if (200..300).contains(&status) => Ok(()),
        Some(-21669) => Err(wrong_code_message(1)),
        Some(0) | None => Err(Error::msg(format!("Apple's answer to the code could not be read (HTTP {status}). Try the code again, or sign in again."))),
        Some(ec) => Err(Error::apple(ec, if em.is_empty() { format!("Apple rejected the code ({ec}).") } else { em.to_string() })),
    }
}

/// Reads Apple's answer to a texted code from its HTTP status and JSON body.
fn sms_code_answer(status: u16, bytes: &[u8]) -> Result<()> {
    if status == 429 {
        return Err(rate_limited());
    }
    if status == 410 {
        return Err(expired_code());
    }
    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(bytes) {
        if json_indicates_rate_limit(&v) {
            return Err(rate_limited());
        }
        if json_indicates_expired_code(&v) {
            return Err(expired_code());
        }
        if let Some(code) = json_service_error_code(&v) {
            if code == "-21669" {
                return Err(wrong_code_message(1));
            }
        }
    }
    match status {
        200..=299 => Ok(()),
        403 => Err(Error::NeedsPerson("Apple turned away text-message codes for this sign-in. Use a code from one of your Apple devices instead. On a device signed in to this Apple Account, open Settings > [your name] > Sign-In & Security > Get Verification Code.".into())),
        _ => Err(wrong_code_message(1)),
    }
}

fn decrypt_spd(key: &[u8], spd: &[u8]) -> Result<plist::Value> {
    use aes::cipher::{BlockDecryptMut, KeyIvInit};
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key).unwrap();
    mac.update(b"extra data key:");
    let k = mac.finalize().into_bytes();
    let mut mac = <HmacSha256 as Mac>::new_from_slice(key).unwrap();
    mac.update(b"extra data iv:");
    let iv = mac.finalize().into_bytes();
    let dec = cbc::Decryptor::<aes::Aes256>::new_from_slices(&k, &iv[..16]).map_err(|_| Error::msg("spd key"))?;
    let plain = dec.decrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(spd).map_err(|_| Error::msg("Apple's session data did not decrypt. Check the password and try again."))?;
    Ok(plist::from_bytes(&plain)?)
}

fn decrypt_gcm(sk: &[u8], et: &[u8]) -> Result<plist::Value> {
    // "XYZ" | 16-byte IV | ciphertext | 16-byte tag, AES-256-GCM with the header as AAD.
    use aes_gcm::aead::generic_array::{GenericArray, typenum::U16};
    if et.len() < 3 + 16 + 16 || &et[..3] != b"XYZ" {
        return Err(Error::msg("Apple's app token has an unknown shape"));
    }
    let cipher = aes_gcm::AesGcm::<aes::Aes256, U16>::new_from_slice(sk).map_err(|_| Error::msg("session key length"))?;
    let plain = cipher
        .decrypt(GenericArray::from_slice(&et[3..19]), Payload { msg: &et[19..], aad: b"XYZ" })
        .map_err(|_| Error::msg("Apple's app token did not decrypt. Sign in again."))?;
    Ok(plist::from_bytes(&plain)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authentication_request_values_never_enter_trace_events() {
        use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
        use tracing::{Event, Metadata, Subscriber, field::{Field, Visit}, span::{Attributes, Id, Record}};

        const CANARY: &str = "synthetic-private-request-value";
        struct TraceCapture { events: Arc<AtomicUsize>, leaks: Arc<AtomicUsize> }
        impl Visit for TraceCapture {
            fn record_debug(&mut self, _: &Field, value: &dyn std::fmt::Debug) {
                if format!("{value:?}").contains(CANARY) {
                    self.leaks.fetch_add(1, Ordering::SeqCst);
                }
            }
        }
        impl Subscriber for TraceCapture {
            fn enabled(&self, _: &Metadata<'_>) -> bool { true }
            fn new_span(&self, _: &Attributes<'_>) -> Id { Id::from_u64(1) }
            fn record(&self, _: &Id, _: &Record<'_>) {}
            fn record_follows_from(&self, _: &Id, _: &Id) {}
            fn event(&self, event: &Event<'_>) {
                self.events.fetch_add(1, Ordering::SeqCst);
                event.record(&mut TraceCapture { events: self.events.clone(), leaks: self.leaks.clone() });
            }
            fn enter(&self, _: &Id) {}
            fn exit(&self, _: &Id) {}
        }
        let events = Arc::new(AtomicUsize::new(0));
        let leaks = Arc::new(AtomicUsize::new(0));
        let capture = TraceCapture { events: events.clone(), leaks: leaks.clone() };
        tracing::subscriber::with_default(capture, || {
            tracing::trace!("trace capture enabled");
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            runtime.block_on(async {
                let client = Client::new(Provider::new(super::super::anisette::Source::System)).unwrap();
                // Invalid HTTP headers fail before any network I/O, after request serialization.
                let headers = Anisette {
                    map: [("User-Agent".into(), "invalid\nheader".into())].into(),
                    made_at: std::time::Instant::now(),
                };
                let mut request = plist::Dictionary::new();
                request.insert("test-value".into(), CANARY.into());
                let error = client.gs_request(&headers, request).await.unwrap_err();
                assert!(error.to_string().contains("builder error"));
            });
        });
        assert!(events.load(Ordering::SeqCst) > 0, "TRACE must be enabled for this check");
        assert_eq!(leaks.load(Ordering::SeqCst), 0, "authentication request value reached a trace event");
    }

    #[test]
    fn spd_round_trip() {
        use aes::cipher::{BlockEncryptMut, KeyIvInit};
        let key = [7u8; 32];
        let mut d = plist::Dictionary::new();
        d.insert("adsid".into(), "000-1".into());
        let mut plain = Vec::new();
        plist::to_writer_xml(&mut plain, &plist::Value::Dictionary(d)).unwrap();
        let mut mac = <HmacSha256 as Mac>::new_from_slice(&key).unwrap();
        mac.update(b"extra data key:");
        let k = mac.finalize().into_bytes();
        let mut mac = <HmacSha256 as Mac>::new_from_slice(&key).unwrap();
        mac.update(b"extra data iv:");
        let iv = mac.finalize().into_bytes();
        let enc = cbc::Encryptor::<aes::Aes256>::new_from_slices(&k, &iv[..16]).unwrap();
        let ct = enc.encrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(&plain);
        let v = decrypt_spd(&key, &ct).unwrap();
        assert_eq!(s(&v, "adsid"), Some("000-1"));
    }

    #[test]
    fn gcm_round_trip_16_byte_iv() {
        use aes_gcm::aead::generic_array::typenum::U16;
        let sk = [3u8; 32];
        let mut t = plist::Dictionary::new();
        let mut app = plist::Dictionary::new();
        app.insert("token".into(), "tok".into());
        app.insert("expiry".into(), plist::Value::Integer(1_800_000_000_000i64.into()));
        t.insert(super::super::XCODE_APP_ID.into(), plist::Value::Dictionary(app));
        let mut root = plist::Dictionary::new();
        root.insert("t".into(), plist::Value::Dictionary(t));
        let mut plain = Vec::new();
        plist::to_writer_xml(&mut plain, &plist::Value::Dictionary(root)).unwrap();
        let c = aes_gcm::AesGcm::<aes::Aes256, U16>::new_from_slice(&sk).unwrap();
        let iv = [9u8; 16];
        let ct = c.encrypt(aes_gcm::aead::generic_array::GenericArray::from_slice(&iv), Payload { msg: &plain, aad: b"XYZ" }).unwrap();
        let mut et = b"XYZ".to_vec();
        et.extend_from_slice(&iv);
        et.extend_from_slice(&ct);
        let v = decrypt_gcm(&sk, &et).unwrap();
        assert_eq!(s(dict(dict(&v, "t").unwrap(), super::super::XCODE_APP_ID).unwrap(), "token"), Some("tok"));
    }
}

/// The id of the trusted phone number to text: the one Apple marks for SMS, else the first.
fn first_phone_id(v: &serde_json::Value) -> Option<u64> {
    let phones = v.get("trustedPhoneNumbers").and_then(|p| p.as_array())?;
    let pick = phones.iter().find(|p| p.get("pushMode").and_then(|m| m.as_str()) == Some("sms")).or_else(|| phones.first())?;
    pick.get("id").and_then(|i| i.as_u64())
}

#[cfg(test)]
mod sms_tests {
    #[test]
    fn picks_the_sms_phone() {
        let v = serde_json::json!({ "trustedPhoneNumbers": [ { "id": 3, "pushMode": "voice" }, { "id": 7, "pushMode": "sms" } ] });
        assert_eq!(super::first_phone_id(&v), Some(7));
        assert_eq!(super::first_phone_id(&serde_json::json!({ "trustedPhoneNumbers": [ { "id": 2 } ] })), Some(2));
        assert_eq!(super::first_phone_id(&serde_json::json!({})), None);
    }
}

#[cfg(test)]
mod step_tests {
    use super::*;

    #[test]
    fn a_409_without_au_waits_for_the_code_apple_pushed() {
        assert_eq!(next_step(409, None), Step::CodeAlreadySent);
        assert_eq!(next_step(200, None), Step::SignedIn);
        assert_eq!(next_step(0, None), Step::SignedIn);
        assert_eq!(next_step(409, Some("trustedDeviceSecondaryAuth")), Step::AskTrustedDevice);
        assert_eq!(next_step(409, Some("secondaryAuth")), Step::AskSms);
        assert_eq!(next_step(409, Some("repair")), Step::Repair);
        assert_eq!(next_step(409, Some("somethingNew")), Step::Unsupported("somethingNew"));
    }

    fn answer(d: plist::Dictionary) -> Vec<u8> {
        let mut out = Vec::new();
        plist::to_writer_xml(&mut out, &plist::Value::Dictionary(d)).unwrap();
        out
    }

    #[test]
    fn a_device_code_counts_only_with_an_explicit_ec_0() {
        let mut ok = plist::Dictionary::new();
        ok.insert("ec".into(), 0.into());
        assert!(device_code_answer(200, &answer(ok.clone())).is_ok());
        let mut nested = plist::Dictionary::new();
        nested.insert("Status".into(), plist::Value::Dictionary(ok.clone()));
        assert!(device_code_answer(200, &answer(nested)).is_ok());
        assert!(device_code_answer(503, &answer(ok)).is_err());
        assert!(device_code_answer(200, b"<html>Service Unavailable</html>").is_err());
        assert!(device_code_answer(200, &answer(plist::Dictionary::new())).is_err());
        let mut wrong = plist::Dictionary::new();
        wrong.insert("ec".into(), (-21669).into());
        assert!(matches!(device_code_answer(400, &answer(wrong)), Err(Error::NeedsPerson(_))));
        assert!(is_rate_limit(&device_code_answer(429, b"").unwrap_err()));
    }

    #[test]
    fn a_texted_code_reports_why_it_was_turned_away() {
        assert!(sms_code_answer(200, b"{}").is_ok());
        assert!(is_rate_limit(&sms_code_answer(429, b"").unwrap_err()));
        assert!(sms_code_answer(403, b"").unwrap_err().to_string().contains("Get Verification Code"));
        assert!(sms_code_answer(400, b"").unwrap_err().to_string().contains("incorrect"));
        let rate_json = br#"{"securityCode":{"tooManyCodesValidated":true}}"#;
        assert!(is_rate_limit(&sms_code_answer(400, rate_json).unwrap_err()));
    }
}

#[cfg(test)]
mod rate_limit_regressions {
    use super::*;
    use crate::apple::anisette::Source;
    use crate::apple::store;
    use crate::setup::Signer;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[derive(Clone, Default)]
    struct Counts {
        srp_init: usize,
        srp_complete: usize,
        complete_409_auto_push: usize,
        apptokens: usize,
        trusted_device_push: usize,
        sms_auth_info: usize,
        sms_201_auto_send: usize,
        sms_send: usize,
        sms_send_with_slash: usize,
        device_validate: usize,
        sms_validate: usize,
        list_teams: usize,
    }

    impl Counts {
        fn total_codes_sent(&self) -> usize {
            self.complete_409_auto_push + self.trusted_device_push + self.sms_201_auto_send + self.sms_send
        }
    }

    #[derive(Clone)]
    struct MockBehavior {
        apple_id: String,
        password: String,
        srp_status: u16,
        hsc: i64,
        au: Option<String>,
        include_session_keys_on_409: bool,
        trusted_device_status: u16,
        sms_auth_status: u16,
        sms_send_status: u16,
        accepted_code: String,
        expired_code: String,
        apptokens_status: u16,
        apptokens_ec: i64,
        apptokens_em: String,
        second_apptokens: Option<(u16, i64, String)>,
        /// Runs while an apptokens request is in flight, before the answer goes back.
        on_apptokens: Option<fn()>,
        /// What Apple does once a code is checked: the next password step answers 200 with a
        /// new session, and app tokens asked for with the 409 session from before the code get
        /// hsc 401 with ec -22411.
        apple_after_code: bool,
        /// How many listTeams calls the developer portal answers with 1100 ("Your session has
        /// expired. Please log in.") before it lists the team.
        portal_turns_away: usize,
    }

    impl Default for MockBehavior {
        fn default() -> Self {
            Self {
                apple_id: "person@example.com".into(),
                password: "correct-horse-battery".into(),
                srp_status: 200,
                hsc: 409,
                au: Some("trustedDeviceSecondaryAuth".into()),
                include_session_keys_on_409: true,
                trusted_device_status: 200,
                sms_auth_status: 200,
                sms_send_status: 200,
                accepted_code: "654321".into(),
                expired_code: "999999".into(),
                apptokens_status: 200,
                apptokens_ec: 0,
                apptokens_em: String::new(),
                second_apptokens: None,
                on_apptokens: None,
                apple_after_code: false,
                portal_turns_away: 0,
            }
        }
    }

    struct MockGsa {
        base_url: String,
        counts: Arc<Mutex<Counts>>,
        behavior: Arc<Mutex<MockBehavior>>,
    }

    fn plist_xml(d: plist::Dictionary) -> Vec<u8> {
        let mut out = Vec::new();
        plist::to_writer_xml(&mut out, &plist::Value::Dictionary(d)).unwrap();
        out
    }

    fn gs_response(mut resp: plist::Dictionary, ec: i64, hsc: i64, au: Option<&str>) -> Vec<u8> {
        let mut st = plist::Dictionary::new();
        st.insert("ec".into(), ec.into());
        st.insert("hsc".into(), hsc.into());
        if let Some(au) = au {
            st.insert("au".into(), au.into());
        }
        resp.insert("Status".into(), plist::Value::Dictionary(st));
        let mut root = plist::Dictionary::new();
        root.insert("Response".into(), plist::Value::Dictionary(resp));
        plist_xml(root)
    }

    const TOKEN_BEFORE_CODE: &str = "idms-tok-1";
    const TOKEN_AFTER_CODE: &str = "idms-tok-after-code";

    fn encrypt_spd_for_test(srp_key: &[u8], include_keys: bool, idms_token: &str) -> Vec<u8> {
        use aes::cipher::{BlockEncryptMut, KeyIvInit};
        let mut spd = plist::Dictionary::new();
        spd.insert("adsid".into(), "000123-abc".into());
        spd.insert("GsIdmsToken".into(), idms_token.into());
        spd.insert("fn".into(), "Test".into());
        spd.insert("ln".into(), "Person".into());
        if include_keys {
            spd.insert("sk".into(), plist::Value::Data(vec![7u8; 32]));
            spd.insert("c".into(), plist::Value::Data(b"cookie-bytes".to_vec()));
        }
        let plain = plist_xml(spd);
        let mut mac = <HmacSha256 as Mac>::new_from_slice(srp_key).unwrap();
        mac.update(b"extra data key:");
        let k = mac.finalize().into_bytes();
        let mut mac = <HmacSha256 as Mac>::new_from_slice(srp_key).unwrap();
        mac.update(b"extra data iv:");
        let iv = mac.finalize().into_bytes();
        let enc = cbc::Encryptor::<aes::Aes256>::new_from_slices(&k, &iv[..16]).unwrap();
        enc.encrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(&plain)
    }

    fn encrypt_apptoken_for_test(sk: &[u8]) -> Vec<u8> {
        use aes_gcm::aead::generic_array::typenum::U16;
        let mut app = plist::Dictionary::new();
        app.insert("token".into(), "xcode-auth-token-ok".into());
        let future_ms = (time::OffsetDateTime::now_utc().unix_timestamp() + 7200) * 1000;
        app.insert("expiry".into(), plist::Value::Integer(future_ms.into()));
        let mut t = plist::Dictionary::new();
        t.insert(super::super::XCODE_APP_ID.into(), plist::Value::Dictionary(app));
        let mut root = plist::Dictionary::new();
        root.insert("t".into(), plist::Value::Dictionary(t));
        let plain = plist_xml(root);
        let cipher = aes_gcm::AesGcm::<aes::Aes256, U16>::new_from_slice(sk).unwrap();
        let iv = [5u8; 16];
        let ct = cipher.encrypt(aes_gcm::aead::generic_array::GenericArray::from_slice(&iv), Payload { msg: &plain, aad: b"XYZ" }).unwrap();
        let mut et = b"XYZ".to_vec();
        et.extend_from_slice(&iv);
        et.extend_from_slice(&ct);
        et
    }

    async fn return_gs(stream: &mut tokio::net::TcpStream, body: Vec<u8>) {
        let head = format!("HTTP/1.1 200 OK\r\nContent-Type: text/x-xml-plist\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
        let _ = stream.write_all(head.as_bytes()).await;
        let _ = stream.write_all(&body).await;
    }

    async fn start_mock_gsa(initial: MockBehavior) -> MockGsa {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let counts = Arc::new(Mutex::new(Counts::default()));
        let behavior = Arc::new(Mutex::new(initial));
        let last_a_pub: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));

        let counts_bg = counts.clone();
        let behavior_bg = behavior.clone();
        let last_a_bg = last_a_pub.clone();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let counts = counts_bg.clone();
                let behavior = behavior_bg.clone();
                let last_a = last_a_bg.clone();
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut tmp = [0u8; 4096];
                    let header_end = loop {
                        let n = match stream.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => n,
                        };
                        buf.extend_from_slice(&tmp[..n]);
                        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            break pos + 4;
                        }
                    };
                    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
                    let mut lines = head.lines();
                    let req_line = lines.next().unwrap_or("");
                    let mut parts = req_line.split_whitespace();
                    let method = parts.next().unwrap_or("");
                    let path = parts.next().unwrap_or("");
                    let mut headers = HashMap::new();
                    for line in lines {
                        if let Some((k, v)) = line.split_once(':') {
                            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                        }
                    }
                    let content_len: usize = headers.get("content-length").and_then(|s| s.parse().ok()).unwrap_or(0);
                    while buf.len() < header_end + content_len {
                        let n = match stream.read(&mut tmp).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => n,
                        };
                        buf.extend_from_slice(&tmp[..n]);
                    }
                    let body = &buf[header_end..buf.len().min(header_end + content_len)];

                    let (status, content_type, resp_body) = {
                        let b = behavior.lock().unwrap().clone();
                        match (method, path) {
                            ("POST", "/grandslam/GsService2") => {
                                let root: plist::Value = plist::from_bytes(body).unwrap();
                                let req = dict(&root, "Request").unwrap();
                                let op = s(req, "o").unwrap_or("");
                                let srp_srv = srp::TestServer::new(&b.apple_id, &b.password);
                                match op {
                                    "init" => {
                                        counts.lock().unwrap().srp_init += 1;
                                        if b.srp_status == 503 {
                                            (503, "text/html", b"<h1>503 Service Unavailable</h1>".to_vec())
                                        } else if b.srp_status != 200 {
                                            (b.srp_status, "text/plain", b"rate limited".to_vec())
                                        } else {
                                            *last_a.lock().unwrap() = data(req, "A2k").unwrap().to_vec();
                                            let mut r = plist::Dictionary::new();
                                            r.insert("sp".into(), "s2k".into());
                                            r.insert("s".into(), plist::Value::Data(srp_srv.salt));
                                            r.insert("i".into(), plist::Value::Integer((srp_srv.iterations as i64).into()));
                                            r.insert("B".into(), plist::Value::Data(srp_srv.b_pub));
                                            r.insert("c".into(), "srv-c".into());
                                            (200u16, "text/x-xml-plist", gs_response(r, 0, 200, None))
                                        }
                                    }
                                    "complete" => {
                                        let already_validated = {
                                            let mut c = counts.lock().unwrap();
                                            c.srp_complete += 1;
                                            c.device_validate + c.sms_validate > 0
                                        };
                                        let a_pub = last_a.lock().unwrap().clone();
                                        let m1 = data(req, "M1").unwrap();
                                        if let Some((key, m2)) = srp_srv.verify_and_m2(&a_pub, m1) {
                                            let mut r = plist::Dictionary::new();
                                            r.insert("M2".into(), plist::Value::Data(m2));
                                            if b.apple_after_code && already_validated {
                                                r.insert("spd".into(), plist::Value::Data(encrypt_spd_for_test(&key, true, TOKEN_AFTER_CODE)));
                                                return_gs(&mut stream, gs_response(r, 0, 200, None)).await;
                                                return;
                                            }
                                            let include_keys = b.hsc != 409 || b.include_session_keys_on_409;
                                            r.insert("spd".into(), plist::Value::Data(encrypt_spd_for_test(&key, include_keys, TOKEN_BEFORE_CODE)));
                                            let eff_au = if b.hsc == 409 && already_validated && !b.include_session_keys_on_409 {
                                                None
                                            } else {
                                                b.au.as_deref()
                                            };
                                            if b.hsc == 409 && eff_au.is_none() {
                                                counts.lock().unwrap().complete_409_auto_push += 1;
                                            }
                                            (200, "text/x-xml-plist", gs_response(r, 0, b.hsc, eff_au))
                                        } else {
                                            (200, "text/x-xml-plist", gs_response(plist::Dictionary::new(), -22406, 200, None))
                                        }
                                    }
                                    "apptokens" => {
                                        let call_num = {
                                            let mut c = counts.lock().unwrap();
                                            c.apptokens += 1;
                                            c.apptokens
                                        };
                                        if let Some(hook) = b.on_apptokens {
                                            hook();
                                        }
                                        let before_code = s(req, "t") == Some(TOKEN_BEFORE_CODE);
                                        let (app_status, app_ec, app_em) = match (call_num, &b.second_apptokens) {
                                            _ if b.apple_after_code && before_code => (401, -22411, "This action cannot be completed at this time".to_string()),
                                            (n, Some((st, ec, em))) if n >= 2 => (*st, *ec, em.clone()),
                                            _ => (b.apptokens_status, b.apptokens_ec, b.apptokens_em.clone()),
                                        };
                                        if app_ec != 0 {
                                            let mut st = plist::Dictionary::new();
                                            st.insert("ec".into(), app_ec.into());
                                            st.insert("hsc".into(), (app_status as i64).into());
                                            if !app_em.is_empty() {
                                                st.insert("em".into(), app_em.into());
                                            }
                                            let mut r = plist::Dictionary::new();
                                            r.insert("Status".into(), plist::Value::Dictionary(st));
                                            let mut root = plist::Dictionary::new();
                                            root.insert("Response".into(), plist::Value::Dictionary(r));
                                            (app_status, "text/x-xml-plist", plist_xml(root))
                                        } else if app_status != 200 {
                                            (app_status, "text/plain", b"rate limited".to_vec())
                                        } else {
                                            let mut r = plist::Dictionary::new();
                                            r.insert("et".into(), plist::Value::Data(encrypt_apptoken_for_test(&[7u8; 32])));
                                            (200, "text/x-xml-plist", gs_response(r, 0, 200, None))
                                        }
                                    }
                                    _ => (400, "text/plain", b"bad op".to_vec()),
                                }
                            }
                            ("GET", "/auth/verify/trusteddevice") => {
                                counts.lock().unwrap().trusted_device_push += 1;
                                let mut d = plist::Dictionary::new();
                                d.insert("ec".into(), 0.into());
                                (b.trusted_device_status, "text/x-xml-plist", plist_xml(d))
                            }
                            ("GET", "/auth") => {
                                let mut c = counts.lock().unwrap();
                                c.sms_auth_info += 1;
                                if b.sms_auth_status == 201 {
                                    c.sms_201_auto_send += 1;
                                }
                                drop(c);
                                let j = serde_json::json!({ "trustedPhoneNumbers": [{ "id": 1, "pushMode": "sms" }] });
                                (b.sms_auth_status, "application/json", j.to_string().into_bytes())
                            }
                            ("PUT" | "POST", "/auth/verify/phone/") => {
                                let mut c = counts.lock().unwrap();
                                c.sms_send += 1;
                                c.sms_send_with_slash += 1;
                                if method == "PUT" {
                                    (405, "application/json", b"{}".to_vec())
                                } else {
                                    (b.sms_send_status, "application/json", b"{}".to_vec())
                                }
                            }
                            ("PUT", "/auth/verify/phone") => {
                                counts.lock().unwrap().sms_send += 1;
                                (b.sms_send_status, "application/json", b"{}".to_vec())
                            }
                            ("GET", "/grandslam/GsService2/validate") => {
                                counts.lock().unwrap().device_validate += 1;
                                let code = headers.get("security-code").cloned().unwrap_or_default();
                                let mut d = plist::Dictionary::new();
                                if code == b.accepted_code {
                                    d.insert("ec".into(), 0.into());
                                    (200, "text/x-xml-plist", plist_xml(d))
                                } else if code == b.expired_code {
                                    d.insert("ec".into(), (-21670).into());
                                    d.insert("em".into(), "The verification code has expired.".into());
                                    (400, "text/x-xml-plist", plist_xml(d))
                                } else {
                                    d.insert("ec".into(), (-21669).into());
                                    d.insert("em".into(), "Incorrect verification code.".into());
                                    (400, "text/x-xml-plist", plist_xml(d))
                                }
                            }
                            ("POST", "/auth/verify/phone/securitycode") => {
                                counts.lock().unwrap().sms_validate += 1;
                                let v: serde_json::Value = serde_json::from_slice(body).unwrap_or_default();
                                let code = v.get("securityCode").and_then(|s| s.get("code")).and_then(|c| c.as_str()).unwrap_or("");
                                if code == b.accepted_code {
                                    (200, "application/json", b"{}".to_vec())
                                } else if code == b.expired_code {
                                    let err = serde_json::json!({
                                        "securityCode": { "codeExpired": true },
                                        "serviceErrors": [{ "code": "-21670", "title": "Expired Code", "message": "The verification code has expired." }]
                                    });
                                    (400, "application/json", err.to_string().into_bytes())
                                } else {
                                    let err = serde_json::json!({
                                        "serviceErrors": [{ "code": "-21669", "title": "Incorrect Code", "message": "Incorrect verification code." }]
                                    });
                                    (400, "application/json", err.to_string().into_bytes())
                                }
                            }
                            ("POST", p) if p.starts_with("/services/QH65B2/listTeams.action") => {
                                let call_num = {
                                    let mut c = counts.lock().unwrap();
                                    c.list_teams += 1;
                                    c.list_teams
                                };
                                let mut d = plist::Dictionary::new();
                                if call_num <= b.portal_turns_away {
                                    d.insert("resultCode".into(), 1100.into());
                                    d.insert("userString".into(), "Your session has expired. Please log in.".into());
                                } else {
                                    let mut membership = plist::Dictionary::new();
                                    membership.insert("name".into(), "Free Developer Program".into());
                                    let mut team = plist::Dictionary::new();
                                    team.insert("teamId".into(), "TEAM123".into());
                                    team.insert("name".into(), "Test Team".into());
                                    team.insert("type".into(), "Individual".into());
                                    team.insert("memberships".into(), plist::Value::Array(vec![plist::Value::Dictionary(membership)]));
                                    d.insert("resultCode".into(), 0.into());
                                    d.insert("teams".into(), plist::Value::Array(vec![plist::Value::Dictionary(team)]));
                                }
                                (200, "text/x-xml-plist", plist_xml(d))
                            }
                            _ => (404, "text/plain", b"not found".to_vec()),
                        }
                    };

                    let reason = match status {
                        200 => "OK",
                        201 => "Created",
                        400 => "Bad Request",
                        403 => "Forbidden",
                        405 => "Method Not Allowed",
                        429 => "Too Many Requests",
                        503 => "Service Unavailable",
                        _ => "Error",
                    };
                    let head = format!(
                        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        resp_body.len()
                    );
                    let _ = stream.write_all(head.as_bytes()).await;
                    let _ = stream.write_all(&resp_body).await;
                });
            }
        });

        MockGsa { base_url: format!("http://{addr}"), counts, behavior }
    }

    fn test_client(base_url: &str) -> Client {
        let headers = Anisette {
            map: HashMap::from([
                ("X-Apple-I-MD".into(), "otp-1".into()),
                ("X-Apple-I-MD-M".into(), "mid-1".into()),
                ("X-Apple-I-MD-LU".into(), "lu-1".into()),
                ("X-Apple-I-MD-RINFO".into(), "17106176".into()),
                ("X-Mme-Device-Id".into(), "DEV-1".into()),
                ("X-Mme-Client-Info".into(), "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>".into()),
                ("User-Agent".into(), "akd/1.0 CFNetwork/811.5.4".into()),
                ("X-Apple-I-Client-Time".into(), "2026-11-17T08:00:00Z".into()),
                ("X-Apple-Locale".into(), "en_US".into()),
                ("X-Apple-I-TimeZone".into(), "UTC".into()),
            ]),
            made_at: std::time::Instant::now(),
        };
        let provider = Provider::for_test(Source::Remote { url: "https://new.ani.sidestore.io".into() }, headers);
        Client::with_endpoints(provider, Endpoints::local(base_url)).unwrap()
    }

    fn run_in_vault<F: std::future::Future<Output = ()>>(f: F) {
        let vault = Arc::new(crate::vault::memory::Memory::default());
        store::with_test_vault(vault, || {
            let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            rt.block_on(f);
        });
    }

    #[test]
    fn one_code_per_sign_in_without_cross_channel_fallback() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                trusted_device_status: 500,
                ..MockBehavior::default()
            })
            .await;
            let mut client = test_client(&mock.base_url);
            let res = client.sign_in("person@example.com", "correct-horse-battery").await;
            assert!(res.is_err(), "failed trusted-device push must report error rather than silently texting");
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.trusted_device_push, 1, "at most 1 trusted-device code request");
            assert_eq!(c.sms_auth_info + c.sms_send, 0, "must never fall back to SMS after trusted-device failure");

            let mock_sms = start_mock_gsa(MockBehavior {
                au: Some("secondaryAuth".into()),
                ..MockBehavior::default()
            })
            .await;
            let mut client_sms = test_client(&mock_sms.base_url);
            let out = client_sms.sign_in("person@example.com", "correct-horse-battery").await.unwrap();
            assert!(matches!(out, Outcome::NeedsCode(ref p) if p.via == Factor::Sms));
            let c_sms = mock_sms.counts.lock().unwrap().clone();
            assert_eq!(c_sms.trusted_device_push, 0, "secondaryAuth must not request a trusted-device push first");
            assert_eq!(c_sms.sms_send_with_slash, 0, "SMS endpoint must not use trailing slash");
            assert_eq!(c_sms.sms_send, 1, "secondaryAuth must send exactly 1 SMS request");
        });
    }

    #[test]
    fn no_new_code_request_before_user_enters_code() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                apptokens_ec: -22406,
                ..MockBehavior::default()
            })
            .await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            signer.account.session = Some(Session {
                apple_id: "person@example.com".into(),
                adsid: "000123-abc".into(),
                gs_idms_token: "expired-tok".into(),
                first_name: "Test".into(),
                last_name: "Person".into(),
                sk: vec![7u8; 32],
                c: b"cookie-bytes".to_vec(),
            });
            signer.account.password = Some("correct-horse-battery".into());
            store::save(&signer.account).unwrap();

            let p1 = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            assert_eq!(mock.counts.lock().unwrap().srp_complete, 1);
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 1);

            let p2 = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("reused pending");
            assert_eq!(p1.session.gs_idms_token, p2.session.gs_idms_token);
            let tok_err = signer.token().await.unwrap_err();
            assert!(matches!(tok_err, Error::NeedsCode(_)), "background token() while waiting for code must return NeedsCode without re-signing in");
            assert_eq!(mock.counts.lock().unwrap().srp_complete, 1, "must not run SRP again while waiting for code");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 1, "must not ask Apple for another code while waiting");
        });
    }

    #[test]
    fn verified_code_signs_in_again_without_a_second_code() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior::default()).await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let pending = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            assert_eq!(mock.counts.lock().unwrap().srp_complete, 1);
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 1);

            signer.finish_sign_in(pending, "654321").await.unwrap();
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.device_validate, 1, "validated code once");
            assert_eq!(c.srp_complete, 2, "signs in once more after the code");
            assert_eq!(c.total_codes_sent(), 1, "total codes requested in one sign-in must be 1");

            let token = signer.token().await.unwrap();
            assert_eq!(token.token, "xcode-auth-token-ok");
        });
    }

    /// Apple turns away app tokens for the 409 session from before the code (hsc 401, ec -22411)
    /// and answers the next password step with 200. A sign-in with a code must still end with an
    /// app token, which is what the team list and every signing step need, after one code.
    #[test]
    fn sign_in_with_a_code_gets_an_app_token_after_one_code() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior { apple_after_code: true, ..MockBehavior::default() }).await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let pending = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            signer.finish_sign_in(pending, "654321").await.unwrap();

            let token = signer.token().await.expect("an app token after the code");
            assert_eq!(token.token, "xcode-auth-token-ok");
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.total_codes_sent(), 1, "one code for the whole sign-in");
            assert_eq!(c.apptokens, 1);
            assert!(!signer.is_rate_limited(), "no cooldown");
        });
    }

    /// -22411 with hsc 401 is Apple turning the session away, not a rate limit: the person is asked
    /// to sign in again, and nothing is locked for an hour.
    #[test]
    fn apptokens_401_with_ec_22411_asks_to_sign_in_again_without_cooldown() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                hsc: 200,
                au: None,
                apptokens_status: 401,
                apptokens_ec: -22411,
                apptokens_em: "This action cannot be completed at this time".into(),
                ..MockBehavior::default()
            })
            .await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            assert!(signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().is_none());

            let err = signer.token().await.unwrap_err();
            assert!(!is_rate_limit(&err), "401 with -22411 is not a rate limit, got: {err}");
            assert!(err.to_string().to_lowercase().contains("sign in again"), "asks to sign in again, got: {err}");
            assert!(!signer.is_rate_limited(), "no one-hour cooldown");
            assert_eq!(mock.counts.lock().unwrap().total_codes_sent(), 0);
        });
    }

    #[test]
    fn keyless_409_session_never_requests_second_code_after_validation() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                include_session_keys_on_409: false,
                ..MockBehavior::default()
            })
            .await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let pending = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            assert_eq!(mock.counts.lock().unwrap().total_codes_sent(), 1);

            let err = signer.finish_sign_in(pending, "654321").await.unwrap_err().to_string();
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.total_codes_sent(), 1, "total codes sent (including second complete 409 auto-push) must be at most 1");
            assert_eq!(c.complete_409_auto_push, 0, "must never trigger a 409 server auto-push after validation");
            assert_eq!(c.srp_complete, 1, "must never run a second SRP complete exchange after validation");
            assert!(
                err.to_lowercase().contains("sign in again") || err.to_lowercase().contains("signing in again"),
                "keyless 409 validation must explicitly ask user to sign in again, got: {err}"
            );
            assert!(signer.pending().is_none(), "consumed keyless Pending must be cleared in memory");
            assert!(store::load_pending().is_none(), "consumed keyless Pending must be cleared in vault");
        });
    }

    #[test]
    fn wrong_code_reuses_same_pending_session_and_warns_after_two_failures() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                au: Some("secondaryAuth".into()),
                ..MockBehavior::default()
            })
            .await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let pending = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            assert_eq!(mock.counts.lock().unwrap().sms_send, 1);

            let e1 = signer.finish_sign_in(pending.clone(), "000000").await.unwrap_err().to_string();
            assert!(e1.to_lowercase().contains("newest") || e1.to_lowercase().contains("latest"), "expected newest-code hint, got: {e1}");
            assert_eq!(mock.counts.lock().unwrap().device_validate, 0, "wrong SMS code must not also hit device validate");
            assert_eq!(mock.counts.lock().unwrap().srp_complete, 1);
            assert_eq!(mock.counts.lock().unwrap().sms_send, 1);

            let e2 = signer.finish_sign_in(pending.clone(), "111111").await.unwrap_err().to_string();
            assert!(e2.to_lowercase().contains("wait") && e2.to_lowercase().contains("lock"), "expected wait/lock warning after 2 failures, got: {e2}");
            assert_eq!(mock.counts.lock().unwrap().srp_complete, 1);
            assert_eq!(mock.counts.lock().unwrap().sms_send, 1);

            signer.finish_sign_in(pending, "654321").await.unwrap();
            assert_eq!(mock.counts.lock().unwrap().srp_complete, 2, "signs in once more after the code");
            assert_eq!(mock.counts.lock().unwrap().sms_send, 1);
        });
    }

    #[test]
    fn sign_in_with_http_503_tells_the_user_to_try_again_later() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior { srp_status: 503, ..MockBehavior::default() }).await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();

            let error = signer.sign_in_as("person@example.com", "correct-horse-battery", false, CodeCaller::IosSignIn).await.unwrap_err();

            assert_eq!(error.to_string(), "Apple's sign-in service is temporarily unavailable (HTTP 503). Wait a few minutes, then try signing in again.");
            assert!(!signer.account.is_rate_limited(time::OffsetDateTime::now_utc().unix_timestamp()));
            assert_eq!(mock.counts.lock().unwrap().total_codes_sent(), 0);
        });
    }

    #[test]
    fn rate_limit_stops_immediately_without_auto_retry() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                apptokens_status: 429,
                ..MockBehavior::default()
            })
            .await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            signer.account.session = Some(Session {
                apple_id: "person@example.com".into(),
                adsid: "000123-abc".into(),
                gs_idms_token: "valid-tok".into(),
                first_name: "Test".into(),
                last_name: "Person".into(),
                sk: vec![7u8; 32],
                c: b"cookie-bytes".to_vec(),
            });
            signer.account.password = Some("correct-horse-battery".into());
            store::save(&signer.account).unwrap();

            let err = signer.token().await.unwrap_err();
            assert!(is_rate_limit(&err), "expected rate-limit error, got: {err}");
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.apptokens, 1);
            assert_eq!(c.srp_init + c.srp_complete + c.trusted_device_push, 0, "rate limit on apptokens must never trigger sign_in or ask for a code");

            let err2 = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap_err();
            assert!(is_rate_limit(&err2), "expected cooldown to block immediate retry, got: {err2}");
            let c2 = mock.counts.lock().unwrap().clone();
            assert_eq!(c2.apptokens, 1);
            assert_eq!(c2.srp_init + c2.srp_complete + c2.trusted_device_push, 0);
        });
    }

    #[test]
    fn sequential_gsa_replay_requests_at_most_one_code_and_logs_without_secrets() {
        run_in_vault(async {
            code_requests_on_this_thread();
            let mock = start_mock_gsa(MockBehavior {
                au: None,
                ..MockBehavior::default()
            })
            .await;

            let mut s1 = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let p1 = s1.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("409 without au");
            s1.finish_sign_in(p1, "654321").await.unwrap();
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.trusted_device_push + c.sms_send, 0, "409 without au already pushed 1 code on complete");
            assert_eq!(code_requests_on_this_thread().iter().filter(|l| l.contains("2fa-code-request")).count(), 1);

            s1.sign_out().unwrap();
            *mock.behavior.lock().unwrap() = MockBehavior {
                au: Some("secondaryAuth".into()),
                ..MockBehavior::default()
            };
            let mut s2 = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let p2 = s2.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("409 secondaryAuth");
            s2.finish_sign_in(p2, "654321").await.unwrap();
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.trusted_device_push, 0, "secondaryAuth must never touch trusteddevice");
            assert_eq!(c.sms_send, 1, "secondaryAuth sends at most 1 SMS code");
            assert_eq!(code_requests_on_this_thread().iter().filter(|l| l.contains("2fa-code-request")).count(), 2);

            s2.sign_out().unwrap();
            *mock.behavior.lock().unwrap() = MockBehavior {
                au: Some("trustedDeviceSecondaryAuth".into()),
                trusted_device_status: 500,
                ..MockBehavior::default()
            };
            let mut s3 = Signer::for_test(test_client(&mock.base_url)).unwrap();
            assert!(s3.sign_in("person@example.com", "correct-horse-battery", true).await.is_err());
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.trusted_device_push, 1, "device push tried once");
            assert_eq!(c.sms_send, 1, "device push failure must not fall back to SMS");
            assert_eq!(code_requests_on_this_thread().iter().filter(|l| l.contains("2fa-code-request")).count(), 3);

            *mock.behavior.lock().unwrap() = MockBehavior {
                srp_status: 429,
                apptokens_status: 429,
                ..MockBehavior::default()
            };
            let mut s4 = Signer::for_test(test_client(&mock.base_url)).unwrap();
            s4.account.session = Some(Session {
                apple_id: "person@example.com".into(),
                adsid: "000123-abc".into(),
                gs_idms_token: "idms-tok-1".into(),
                first_name: "Test".into(),
                last_name: "Person".into(),
                sk: vec![7u8; 32],
                c: b"cookie-bytes".to_vec(),
            });
            s4.account.password = Some("correct-horse-battery".into());
            store::save(&s4.account).unwrap();
            let before_429 = mock.counts.lock().unwrap().clone();
            let e429 = s4.token().await.unwrap_err();
            assert!(is_rate_limit(&e429));
            let after_429 = mock.counts.lock().unwrap().clone();
            assert_eq!(after_429.apptokens, before_429.apptokens + 1);
            assert_eq!(after_429.srp_init, before_429.srp_init);
            assert!(s4.token().await.is_err(), "background token renewal must stop during cooldown");
            let after_bg = mock.counts.lock().unwrap().clone();
            assert_eq!(after_bg.apptokens, after_429.apptokens, "no HTTP requests during rate-limit cooldown");
            assert_eq!(after_bg.srp_init, after_429.srp_init);
            assert_eq!(code_requests_on_this_thread().iter().filter(|l| l.contains("2fa-code-request")).count(), 3);

            s4.sign_out().unwrap();
            *mock.behavior.lock().unwrap() = MockBehavior {
                au: Some("trustedDeviceSecondaryAuth".into()),
                include_session_keys_on_409: false,
                ..MockBehavior::default()
            };
            let mut s5 = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let before_s5 = mock.counts.lock().unwrap().clone();
            let p5 = s5.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("keyless 409");
            assert!(s5.finish_sign_in(p5, "654321").await.is_err());
            let after_s5 = mock.counts.lock().unwrap().clone();
            assert_eq!(after_s5.srp_complete - before_s5.srp_complete, 1, "keyless 409 must not send a second SRP complete");
            assert_eq!(after_s5.total_codes_sent() - before_s5.total_codes_sent(), 1, "keyless 409 must emit at most 1 code in total");

            let code_logs: Vec<String> = code_requests_on_this_thread()
                .iter()
                .filter(|l| l.contains("2fa-code-request"))
                .cloned()
                .collect();
            assert_eq!(code_logs.len(), 4, "expected 4 logged code events (at most 1 per sign-in across s1, s2, s3, s5), got: {code_logs:?}");
            for line in &code_logs {
                for secret in ["person@example.com", "correct-horse-battery", "654321", "000123-abc", "idms-tok-1", "xcode-auth-token-ok"] {
                    assert!(!line.contains(secret), "2fa-code-request leaked {secret}: {line}");
                }
            }
        });
    }

    #[test]
    fn apptokens_503_with_ec_22411_enters_cooldown_without_sign_in() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                apptokens_status: 503,
                apptokens_ec: -22411,
                apptokens_em: "This action cannot be completed at this time".into(),
                ..MockBehavior::default()
            })
            .await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            signer.account.session = Some(Session {
                apple_id: "person@example.com".into(),
                adsid: "000123-abc".into(),
                gs_idms_token: "valid-tok".into(),
                first_name: "Test".into(),
                last_name: "Person".into(),
                sk: vec![7u8; 32],
                c: b"cookie-bytes".to_vec(),
            });
            signer.account.password = Some("correct-horse-battery".into());
            store::save(&signer.account).unwrap();

            let err = signer.token().await.unwrap_err();
            assert!(is_rate_limit(&err), "HTTP 503 with ec=-22411 must be classified as rate limit, got: {err}");
            assert!(err.to_string().contains("Wait about an hour"), "UI error must tell user to wait: {err}");
            assert!(signer.is_rate_limited(), "Signer must record rate-limit cooldown");

            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.apptokens, 1);
            assert_eq!(c.srp_init + c.srp_complete + c.trusted_device_push + c.sms_send, 0, "must not call sign_in or request a code");

            let err_again = signer.token().await.unwrap_err();
            assert!(is_rate_limit(&err_again));
            assert_eq!(mock.counts.lock().unwrap().apptokens, 1, "cooldown must block subsequent apptokens requests");
        });
    }

    #[test]
    fn distinguishes_wrong_code_from_expired_code() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior::default()).await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let pending = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");

            let wrong_err = signer.finish_sign_in(pending.clone(), "000000").await.unwrap_err().to_string();
            assert!(wrong_err.to_lowercase().contains("incorrect"), "wrong code must say incorrect, got: {wrong_err}");
            assert!(!wrong_err.to_lowercase().contains("expired"), "wrong code must not claim expired, got: {wrong_err}");

            let exp_err = signer.finish_sign_in(pending, "999999").await.unwrap_err().to_string();
            assert!(exp_err.to_lowercase().contains("expired"), "expired code must say expired, got: {exp_err}");
            assert!(exp_err.to_lowercase().contains("newest"), "expired code must ask for newest code, got: {exp_err}");
        });
    }

    #[test]
    fn finish_sign_in_applies_pending_keep_password_choice() {
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior::default()).await;

            // Case 1: Existing saved password must be cleared when signing in with keep_password=false.
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            signer.account.password = Some("old-saved-password".into());
            store::save(&signer.account).unwrap();

            let p1 = signer.sign_in("person@example.com", "correct-horse-battery", false).await.unwrap().expect("needs code");
            signer.finish_sign_in(p1, "654321").await.unwrap();
            assert_eq!(signer.account.password, None, "keep_password=false must clear previously saved password in memory");
            assert_eq!(store::load().unwrap().password, None, "keep_password=false must clear previously saved password in vault");

            // Case 2: Toggling keep_password from true to false while waiting for code must clear old password across reload.
            signer.account.password = Some("old-saved-password".into());
            store::save(&signer.account).unwrap();
            let _ = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            let _ = signer.sign_in("person@example.com", "correct-horse-battery", false).await.unwrap().expect("reused pending with keep=false");
            let mut reloaded = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let p_reloaded = reloaded.pending().cloned().expect("pending persisted");
            reloaded.finish_sign_in(p_reloaded, "654321").await.unwrap();
            assert_eq!(reloaded.account.password, None, "toggled keep_password=false must clear saved password on completion");
            assert_eq!(store::load().unwrap().password, None, "toggled keep_password=false must clear saved password in vault");

            // Case 3: Existing old password must be replaced by the new password when keep_password=true across reload.
            reloaded.account.password = Some("stale-old-password".into());
            store::save(&reloaded.account).unwrap();
            let _ = reloaded.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            let mut reloaded2 = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let p_keep = reloaded2.pending().cloned().expect("pending persisted");
            reloaded2.finish_sign_in(p_keep, "654321").await.unwrap();
            assert_eq!(reloaded2.account.password.as_deref(), Some("correct-horse-battery"), "keep_password=true must replace stale password");
            assert_eq!(store::load().unwrap().password.as_deref(), Some("correct-horse-battery"));
        });
    }

    #[test]
    fn cooldown_and_pending_guards_cover_relogin_cached_token_and_renew_due() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            // 1. Second xcode_token() after automatic session-expired re-login hitting 503 + -22411 must record cooldown.
            let mock = start_mock_gsa(MockBehavior {
                hsc: 200,
                au: None,
                apptokens_status: 200,
                apptokens_ec: -22406,
                second_apptokens: Some((503, -22411, "This action cannot be completed at this time".into())),
                ..MockBehavior::default()
            })
            .await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            signer.account.session = Some(Session {
                apple_id: "person@example.com".into(),
                adsid: "000123-abc".into(),
                gs_idms_token: "expired-tok".into(),
                first_name: "Test".into(),
                last_name: "Person".into(),
                sk: vec![7u8; 32],
                c: b"cookie-bytes".to_vec(),
            });
            signer.account.password = Some("correct-horse-battery".into());
            store::save(&signer.account).unwrap();

            let err = signer.token().await.unwrap_err();
            assert!(is_rate_limit(&err), "second xcode_token 503/-22411 must be classified as rate limit, got: {err}");
            assert!(signer.is_rate_limited(), "second xcode_token 503/-22411 after re-login must record cooldown on Signer");
            let now = time::OffsetDateTime::now_utc().unix_timestamp();
            assert!(store::load().unwrap().is_rate_limited(now), "cooldown after re-login must persist to store");

            // 2. token() must check rate-limit and Pending BEFORE returning a valid cached xcode_token.
            signer.account.xcode_token = Some(AppToken {
                app: crate::apple::XCODE_APP_ID.into(),
                token: "cached-still-valid-token".into(),
                expires_at: now + 7200,
            });
            store::save(&signer.account).unwrap();
            let cached_rl_err = signer.token().await.unwrap_err();
            assert!(is_rate_limit(&cached_rl_err), "token() must refuse cached token while rate-limited");

            signer.account.clear_rate_limit();
            store::save(&signer.account).unwrap();
            *mock.behavior.lock().unwrap() = MockBehavior::default();
            let _pending = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            signer.account.xcode_token = Some(AppToken {
                app: crate::apple::XCODE_APP_ID.into(),
                token: "cached-still-valid-token".into(),
                expires_at: now + 7200,
            });
            let cached_pending_err = signer.token().await.unwrap_err();
            assert!(matches!(cached_pending_err, Error::NeedsCode(_)), "token() must refuse cached token while Pending is active");

            // 3. renew_due() must stop at its entry guard when Pending is active or account is rate-limited.
            #[cfg(feature = "device")]
            {
                let due_rec = crate::keeper::Record {
                    udid: "00008150-DUE-TEST-UDID".into(),
                    phone_name: "Test iPhone".into(),
                    ios: "27.0".into(),
                    apple_id: "person@example.com".into(),
                    team_id: "TEAM123".into(),
                    team_name: "Test Team".into(),
                    team_is_free: true,
                    bundle_id: "nz.zheha.poki.TEAM123".into(),
                    app_group: "group.nz.zheha.poki.TEAM123".into(),
                    version: "0.4.5".into(),
                    build: "1".into(),
                    release_tag: "app-0.4.5".into(),
                    signed_at: now - 6 * 86_400,
                    profile_expires_at: now + 86_400,
                    last_checked_at: None,
                    last_error: None,
                    wifi_address: None,
                    pairing_handed_off: false,
                    test_build: None,
                };
                crate::keeper::put(due_rec).unwrap();
                assert_eq!(crate::keeper::due().unwrap().len(), 1);

                let pending_runs = crate::setup::renew_due(&mut signer, &crate::Reporter::silent()).await;
                assert!(pending_runs.is_empty(), "renew_due must not attempt renewal while Pending is waiting for a code");
                assert_eq!(crate::keeper::get("00008150-DUE-TEST-UDID").unwrap().unwrap().last_error, None);

                signer.cancel_sign_in().unwrap();
                signer.account.mark_rate_limited(now);
                store::save(&signer.account).unwrap();
                let rl_runs = crate::setup::renew_due(&mut signer, &crate::Reporter::silent()).await;
                assert!(rl_runs.is_empty(), "renew_due must not attempt renewal during rate-limit cooldown");
                assert_eq!(crate::keeper::get("00008150-DUE-TEST-UDID").unwrap().unwrap().last_error, None);
            }
        });
    }

    thread_local! {
        static CODE_REQUESTS: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
    }

    /// Code requests logged on this test's thread. Unlike a scoped tracing subscriber, the hook
    /// never depends on callsite interest that tests running in parallel cache for each other.
    fn code_requests_on_this_thread() -> Vec<String> {
        super::set_code_request_hook(|line| CODE_REQUESTS.with(|c| c.borrow_mut().push(line.to_string())));
        CODE_REQUESTS.with(|c| c.borrow().clone())
    }

    #[test]
    fn cancel_sign_in_and_resend_code_respect_cooldown_and_rate_limits() {
        run_in_vault(async {
            code_requests_on_this_thread();
            let mock = start_mock_gsa(MockBehavior::default()).await;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let mut p = signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 1);

            let cooldown_err = signer.resend_code().await.unwrap_err().to_string();
            assert!(cooldown_err.contains("seconds"), "expected 60s cooldown refusal, got: {cooldown_err}");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 1, "60s cooldown must prevent resend");

            // Failed resend must also record timestamp BEFORE sending, persisting across Signer reload.
            p.created_at -= 61;
            p.last_sent_at -= 61;
            store::save_pending(&p).unwrap();
            mock.behavior.lock().unwrap().trusted_device_status = 500;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            assert!(signer.resend_code().await.is_err(), "HTTP 500 resend must fail");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 2, "failed resend hit endpoint once");

            let mut reopened = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let retry_after_fail = reopened.resend_code().await.unwrap_err().to_string();
            assert!(retry_after_fail.contains("seconds"), "failed resend must still enforce 60s cooldown after reload, got: {retry_after_fail}");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 2, "cooldown after failed resend must block immediate retry");

            // Successful resend after 61s sends 1 code on same channel and logs without secrets.
            let mut p_after_fail = store::load_pending().unwrap();
            p_after_fail.created_at -= 61;
            p_after_fail.last_sent_at -= 61;
            store::save_pending(&p_after_fail).unwrap();
            mock.behavior.lock().unwrap().trusted_device_status = 200;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let resent = signer.resend_code().await.unwrap();
            assert!(resent.resend_wait_secs(time::OffsetDateTime::now_utc().unix_timestamp()) > 0);
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 3, "one manual resend sends exactly 1 code");
            assert_eq!(mock.counts.lock().unwrap().sms_send, 0, "resend must never cross channels");
            assert!(code_requests_on_this_thread().iter().any(|l| l.contains("2fa-code-request path=ask_trusted_device caller=resend_code")));

            // Rate-limited resend enters 1h cooldown and blocks further resends even after 61s, while cancel_sign_in still clears Pending.
            let mut p_for_rl = store::load_pending().unwrap();
            p_for_rl.created_at -= 61;
            p_for_rl.last_sent_at -= 61;
            store::save_pending(&p_for_rl).unwrap();
            mock.behavior.lock().unwrap().trusted_device_status = 429;
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let rl_err = signer.resend_code().await.unwrap_err();
            assert!(is_rate_limit(&rl_err), "429 on resend must return rate limit, got: {rl_err}");
            assert!(signer.is_rate_limited(), "429 on resend must mark account rate-limited");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 4);

            let mut p_aged = store::load_pending().unwrap();
            p_aged.created_at -= 61;
            p_aged.last_sent_at -= 61;
            store::save_pending(&p_aged).unwrap();
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let blocked_err = signer.resend_code().await.unwrap_err();
            assert!(is_rate_limit(&blocked_err), "account rate-limit cooldown must block resend even after 60s");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 4, "no HTTP request when account is rate-limited");

            signer.cancel_sign_in().unwrap();
            assert!(signer.pending().is_none(), "cancel_sign_in must clear Pending in memory even during rate limit");
            assert!(store::load_pending().is_none(), "cancel_sign_in must clear Pending in vault even during rate limit");
        });
    }

    #[test]
    fn expired_saved_session_after_keyless_409_blocks_teams_and_renewal_until_manual_sign_in() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                apptokens_ec: -22406,
                include_session_keys_on_409: false,
                ..MockBehavior::default()
            })
            .await;

            let now = time::OffsetDateTime::now_utc().unix_timestamp();
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            signer.account.session = Some(Session {
                apple_id: "person@example.com".into(),
                adsid: "000123-abc".into(),
                gs_idms_token: "expired-tok".into(),
                first_name: "Test".into(),
                last_name: "Person".into(),
                sk: vec![7u8; 32],
                c: b"cookie-bytes".to_vec(),
            });
            signer.account.password = Some("correct-horse-battery".into());
            store::save(&signer.account).unwrap();

            #[cfg(feature = "device")]
            {
                let due_rec = crate::keeper::Record {
                    udid: "00008150-KEYLESS-DUE".into(),
                    phone_name: "Test iPhone".into(),
                    ios: "27.0".into(),
                    apple_id: "person@example.com".into(),
                    team_id: "TEAM123".into(),
                    team_name: "Test Team".into(),
                    team_is_free: true,
                    bundle_id: "nz.zheha.poki.TEAM123".into(),
                    app_group: "group.nz.zheha.poki.TEAM123".into(),
                    version: "0.4.5".into(),
                    build: "1".into(),
                    release_tag: "app-0.4.5".into(),
                    signed_at: now - 6 * 86_400,
                    profile_expires_at: now + 86_400,
                    last_checked_at: None,
                    last_error: None,
                    wifi_address: None,
                    pairing_handed_off: false,
                    test_build: None,
                };
                crate::keeper::put(due_rec).unwrap();
            }

            // 1. Expired saved session + saved password triggers 2FA challenge with no sk/c.
            let Err(Error::NeedsCode(pending)) = signer.token().await else {
                panic!("expired session renewal must ask for a 2FA code");
            };
            assert_eq!(mock.counts.lock().unwrap().srp_complete, 1);
            assert_eq!(mock.counts.lock().unwrap().total_codes_sent(), 1);

            // 2. Person enters the valid 6-digit code; finish_sign_in asks to sign in again and clears Pending.
            let finish_err = signer.finish_sign_in(*pending, "654321").await.unwrap_err().to_string();
            assert!(
                finish_err.to_lowercase().contains("sign in again"),
                "keyless 409 verification must explicitly ask user to sign in again, got: {finish_err}"
            );
            assert!(signer.pending().is_none(), "consumed Pending must be cleared in memory");
            assert!(store::load_pending().is_none(), "consumed Pending must be cleared in vault");

            let baseline = mock.counts.lock().unwrap().clone();

            // 3. Subsequent teams(), token(), and background renewal (in-memory and reloaded) must do 0 SRP or code requests.
            let teams_res = signer.teams().await;
            let token_res = signer.token().await;
            let mut reloaded = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let reloaded_teams_res = reloaded.teams().await;
            #[cfg(feature = "device")]
            let (due_runs, direct_renew_res) = (
                crate::setup::renew_due(&mut reloaded, &crate::Reporter::silent()).await,
                crate::setup::renew(&mut reloaded, "00008150-KEYLESS-DUE", &crate::Reporter::silent()).await,
            );

            let after = mock.counts.lock().unwrap().clone();
            assert_eq!(
                after.srp_init - baseline.srp_init,
                0,
                "teams/token/renewal after keyless 409 must trigger 0 SRP init exchanges"
            );
            assert_eq!(
                after.srp_complete - baseline.srp_complete,
                0,
                "teams/token/renewal after keyless 409 must trigger 0 SRP complete exchanges"
            );
            assert_eq!(
                after.total_codes_sent() - baseline.total_codes_sent(),
                0,
                "teams/token/renewal after keyless 409 must trigger 0 2FA code requests"
            );
            assert!(!signer.signed_in(), "account must not appear signed in before user manually signs in");
            assert!(!reloaded.signed_in(), "reloaded account must persist manual sign-in requirement");
            assert!(teams_res.unwrap_err().to_string().to_lowercase().contains("sign in again"));
            assert!(token_res.unwrap_err().to_string().to_lowercase().contains("sign in again"));
            assert!(reloaded_teams_res.unwrap_err().to_string().to_lowercase().contains("sign in again"));
            #[cfg(feature = "device")]
            {
                assert!(due_runs.is_empty(), "renew_due must stay quiet while manual sign-in is required");
                assert!(direct_renew_res.unwrap_err().to_string().to_lowercase().contains("sign in again"));
                assert_eq!(crate::keeper::get("00008150-KEYLESS-DUE").unwrap().unwrap().last_error, None);
            }

            // 4. Cancelling an unfinished manual sign-in keeps reauth required; completing manual sign-in restores normal operation.
            *mock.behavior.lock().unwrap() = MockBehavior::default();
            let _cancelled = reloaded.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            reloaded.cancel_sign_in().unwrap();
            let after_cancel = mock.counts.lock().unwrap().clone();
            assert!(!reloaded.signed_in(), "cancelling an unfinished manual sign-in must keep reauth required");
            assert!(reloaded.teams().await.is_err());
            assert_eq!(mock.counts.lock().unwrap().srp_complete - after_cancel.srp_complete, 0);

            let manual_pending = reloaded.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            reloaded.finish_sign_in(manual_pending, "654321").await.unwrap();
            assert!(reloaded.signed_in(), "completing manual sign-in must clear reauth requirement");
            assert_eq!(reloaded.token().await.unwrap().token, "xcode-auth-token-ok");
        });
    }

    #[test]
    fn signer_opened_before_another_client_hit_keyless_409_does_not_sign_in_again() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                apptokens_ec: -22406,
                include_session_keys_on_409: false,
                ..MockBehavior::default()
            })
            .await;
            let mut seeded = store::Account::default();
            seeded.session = Some(Session {
                apple_id: "person@example.com".into(),
                adsid: "000123-abc".into(),
                gs_idms_token: "expired-tok".into(),
                first_name: "Test".into(),
                last_name: "Person".into(),
                sk: vec![7u8; 32],
                c: b"cookie-bytes".to_vec(),
            });
            seeded.password = Some("correct-horse-battery".into());
            store::save(&seeded).unwrap();

            // Poki Setup is already open with this account loaded, and so is a second window of it.
            let mut running = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let mut idle = Signer::for_test(test_client(&mock.base_url)).unwrap();
            assert!(running.signed_in());

            // Meanwhile the CLI hits the expired session and Apple takes the code without session keys.
            let mut cli = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let Err(Error::NeedsCode(pending)) = cli.token().await else { panic!("expired session must ask for a code") };
            assert!(super::is_incomplete_session(&cli.finish_sign_in(*pending, "654321").await.unwrap_err()));
            let baseline = mock.counts.lock().unwrap().clone();

            let teams = running.teams().await;
            #[cfg(feature = "device")]
            let due = crate::setup::renew_due(&mut running, &crate::Reporter::silent()).await;
            let after = mock.counts.lock().unwrap().clone();
            assert_eq!(after.srp_init - baseline.srp_init, 0, "the open client must not sign in with the kept password");
            assert_eq!(after.total_codes_sent() - baseline.total_codes_sent(), 0, "the open client must not ask Apple for a code");
            assert!(super::is_incomplete_session(&teams.unwrap_err()), "the open client must ask the person to sign in again");
            #[cfg(feature = "device")]
            assert!(due.is_empty());
            assert!(!running.signed_in(), "the open client must show the account as signed out");

            idle.choose_team("TEAM123").unwrap();
            assert!(store::load().unwrap().needs_reauth, "a save from the open client must keep the sign-in-again state");
            assert!(!idle.signed_in());
        });
    }

    fn seed_expired_session_with_kept_password() {
        let mut seeded = store::Account::default();
        seeded.session = Some(Session {
            apple_id: "person@example.com".into(),
            adsid: "000123-abc".into(),
            gs_idms_token: "expired-tok".into(),
            first_name: "Test".into(),
            last_name: "Person".into(),
            sk: vec![7u8; 32],
            c: b"cookie-bytes".to_vec(),
        });
        seeded.password = Some("correct-horse-battery".into());
        store::save(&seeded).unwrap();
    }

    /// A stored account whose GSA session Apple no longer takes, with this Xcode token and password.
    fn seed_account_for_teams(xcode_token: Option<AppToken>, password: Option<&str>) {
        seed_expired_session_with_kept_password();
        let mut stored = store::load().unwrap();
        stored.xcode_token = xcode_token;
        stored.password = password.map(str::to_string);
        store::save(&stored).unwrap();
    }

    fn xcode_token_until(expires_at: i64) -> AppToken {
        AppToken { app: super::super::XCODE_APP_ID.into(), token: "saved-xcode-token".into(), expires_at }
    }

    fn point_portal_at(mock: &MockGsa) {
        super::super::portal::TEST_BASE.with(|b| *b.borrow_mut() = Some(format!("{}/services/QH65B2", mock.base_url)));
    }

    #[test]
    fn teams_tries_a_kept_password_apple_turns_away_only_once() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            // The password was changed on another device: the kept one is wrong now, and the stored
            // Xcode token and the GSA session have both run out.
            let mock = start_mock_gsa(MockBehavior { apptokens_ec: -22406, ..MockBehavior::default() }).await;
            point_portal_at(&mock);
            let now = time::OffsetDateTime::now_utc().unix_timestamp();
            seed_account_for_teams(Some(xcode_token_until(now - 60)), Some("old-password"));
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();

            let err = signer.teams().await.unwrap_err();
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.srp_complete, 1, "one renewal round must try the kept password once, not again after Apple turned it away");
            assert_eq!(c.apptokens, 1);
            assert_eq!(c.list_teams, 0);
            assert!(!super::super::portal::turned_token_away(&err), "a wrong password is not the portal's answer: {err}");
        });
    }

    #[test]
    fn teams_without_a_kept_password_asks_apple_for_one_app_token() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior { apptokens_ec: -22406, ..MockBehavior::default() }).await;
            point_portal_at(&mock);
            let now = time::OffsetDateTime::now_utc().unix_timestamp();
            seed_account_for_teams(Some(xcode_token_until(now - 60)), None);
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();

            let err = signer.teams().await.unwrap_err();
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.apptokens, 1, "an expired session with no kept password needs one apptokens request");
            assert_eq!(c.srp_init, 0);
            assert_eq!(c.list_teams, 0);
            assert_eq!(err.to_string(), SESSION_EXPIRED, "the app offers Sign In Again for this sentence");
        });
    }

    #[test]
    fn portal_turning_the_saved_token_away_gets_one_fresh_token() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior { portal_turns_away: 1, ..MockBehavior::default() }).await;
            point_portal_at(&mock);
            let now = time::OffsetDateTime::now_utc().unix_timestamp();
            seed_account_for_teams(Some(xcode_token_until(now + 86_400)), Some("correct-horse-battery"));
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();

            let teams = signer.teams().await.unwrap();
            assert_eq!(teams.len(), 1);
            assert_eq!(teams[0].team_id, "TEAM123");
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!(c.list_teams, 2);
            assert_eq!(c.apptokens, 1);
            assert_eq!(c.srp_init, 0, "a session Apple still takes needs no sign-in");
            assert_eq!(store::load().unwrap().xcode_token.unwrap().token, "xcode-auth-token-ok");
        });
    }

    #[test]
    fn portal_turning_a_fresh_token_away_is_not_tried_again() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior { portal_turns_away: usize::MAX, ..MockBehavior::default() }).await;
            point_portal_at(&mock);
            let now = time::OffsetDateTime::now_utc().unix_timestamp();

            // The saved token is turned away, and so is the fresh one: one more try, then Sign In Again.
            seed_account_for_teams(Some(xcode_token_until(now + 86_400)), None);
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let err = signer.teams().await.unwrap_err();
            assert_eq!(err.to_string(), SESSION_EXPIRED);
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!((c.list_teams, c.apptokens, c.srp_init), (2, 1, 0));

            // With no saved token, the token the portal turns away is the one just fetched: no second try.
            seed_account_for_teams(None, None);
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let err = signer.teams().await.unwrap_err();
            assert_eq!(err.to_string(), SESSION_EXPIRED);
            let c = mock.counts.lock().unwrap().clone();
            assert_eq!((c.list_teams, c.apptokens, c.srp_init), (3, 2, 0));
        });
    }

    /// What the CLI leaves behind after Apple took a code without opening the session.
    fn another_client_stores_sign_in_again() {
        let mut stored = store::load().unwrap();
        stored.needs_reauth = true;
        stored.xcode_token = None;
        store::save(&stored).unwrap();
        store::clear_pending().unwrap();
    }

    #[test]
    fn renewal_waiting_on_apple_gives_up_when_another_client_stores_sign_in_again() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior {
                apptokens_ec: -22406,
                on_apptokens: Some(another_client_stores_sign_in_again),
                ..MockBehavior::default()
            })
            .await;
            seed_expired_session_with_kept_password();
            let mut renewing = Signer::for_test(test_client(&mock.base_url)).unwrap();

            let expired = renewing.token().await;
            let after = mock.counts.lock().unwrap().clone();
            assert_eq!(after.apptokens, 1);
            assert_eq!(after.srp_init, 0, "a renewal must not sign in with the kept password once the sign-in-again state is stored");
            assert_eq!(after.total_codes_sent(), 0);
            assert!(super::is_incomplete_session(&expired.unwrap_err()));
            assert!(store::load().unwrap().needs_reauth);

            // The same race when Apple still answers with a token: it is not saved over the stored state.
            seed_expired_session_with_kept_password();
            mock.behavior.lock().unwrap().apptokens_ec = 0;
            let mut refreshing = Signer::for_test(test_client(&mock.base_url)).unwrap();
            let fresh = refreshing.token().await;
            assert!(super::is_incomplete_session(&fresh.unwrap_err()));
            assert!(store::load().unwrap().needs_reauth, "a token that came back late must not write the sign-in-again state away");
            assert_eq!(mock.counts.lock().unwrap().srp_init, 0);
        });
    }

    #[test]
    fn person_signing_in_again_can_resend_the_code() {
        let (_home_guard, _dir) = crate::paths::test_home();
        run_in_vault(async {
            let mock = start_mock_gsa(MockBehavior::default()).await;
            seed_expired_session_with_kept_password();
            another_client_stores_sign_in_again();
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();

            signer.sign_in("person@example.com", "correct-horse-battery", true).await.unwrap().expect("needs code");
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 1);
            let mut waiting = store::load_pending().unwrap();
            waiting.created_at -= 61;
            waiting.last_sent_at -= 61;
            store::save_pending(&waiting).unwrap();
            let mut signer = Signer::for_test(test_client(&mock.base_url)).unwrap();

            let resent = signer.resend_code().await;
            assert!(resent.is_ok(), "the person's own sign-in must be able to resend its code, got {:?}", resent.err().map(|e| e.to_string()));
            assert_eq!(mock.counts.lock().unwrap().trusted_device_push, 2);

            signer.finish_sign_in(resent.unwrap(), "654321").await.unwrap();
            assert!(signer.signed_in());
            assert!(!store::load().unwrap().needs_reauth, "finishing the person's sign-in lifts the sign-in-again state");
        });
    }
}
