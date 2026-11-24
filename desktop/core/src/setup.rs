//! The whole setup, step by step, and the pieces the shell calls on their own: sign in, pick a
//! team, sign Poki for it, install it, hand the pairing file over, remember the phone.
use crate::apple::anisette::{Provider, Source};
use crate::apple::gsa::{self, AppToken, Outcome as SignInOutcome, Pending};
use crate::apple::portal::{self, FEATURE_APP_GROUPS, Portal, Team};
use crate::apple::{identity, store};
#[cfg(feature = "device")]
use crate::device::{self, Phone};
#[cfg(feature = "device")]
use crate::{keeper, pairshare, release};
use crate::{Error, Reporter, Result, sign};
use std::path::{Path, PathBuf};
#[cfg(feature = "device")]
use std::time::Duration;

/// The signed-in account with a live GSA client.
pub struct Signer {
    pub account: store::Account,
    client: gsa::Client,
    pending: Option<Pending>,
    caller: gsa::CodeCaller,
}

fn now_unix() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp()
}

impl Signer {
    pub fn open() -> Result<Signer> {
        let account = store::load()?;
        let now = now_unix();
        let pending = store::load_pending().filter(|p| p.is_fresh(now));
        let source = pending
            .as_ref()
            .and_then(|p| p.anisette.clone())
            .or_else(|| account.anisette.clone())
            .unwrap_or_else(Source::default_for_platform);
        Ok(Signer { account, client: gsa::Client::new(Provider::new(source))?, pending, caller: gsa::CodeCaller::TokenRefresh })
    }

    #[cfg(test)]
    pub(crate) fn for_test(client: gsa::Client) -> Result<Signer> {
        let account = store::load()?;
        let pending = store::load_pending().filter(|p| p.is_fresh(now_unix()));
        Ok(Signer { account, client, pending, caller: gsa::CodeCaller::TokenRefresh })
    }

    pub fn set_caller(&mut self, caller: gsa::CodeCaller) {
        self.caller = caller;
    }

    pub fn pending(&self) -> Option<&Pending> {
        self.pending.as_ref().filter(|p| p.is_fresh(now_unix()))
    }

    pub fn set_pending_keep_password(&mut self, keep_password: bool) {
        if let Some(p) = &mut self.pending {
            p.keep_password = keep_password;
            let _ = store::save_pending(p);
        }
    }

    pub fn is_rate_limited(&self) -> bool {
        self.account.is_rate_limited(now_unix())
    }

    pub fn rate_limited_until(&self) -> Option<i64> {
        let now = now_unix();
        self.account.rate_limited_until.filter(|&until| now < until)
    }

    pub fn set_anisette(&mut self, source: Source) -> Result<()> {
        self.account.anisette = Some(source.clone());
        self.client = gsa::Client::new(Provider::new(source))?;
        self.persist()
    }

    pub fn signed_in(&self) -> bool { self.account.session.is_some() && !self.account.needs_reauth }

    pub fn needs_reauth(&self) -> bool { self.account.needs_reauth }

    /// Another client (the CLI, a second app) may have changed the sign-in-again state since this
    /// one loaded the account. Takes the stored account then, so a stale copy neither signs in with
    /// the kept password nor writes the state away. True when the account now needs a fresh sign-in.
    pub fn sync_account(&mut self) -> bool {
        if let Ok(stored) = store::load() {
            if stored.needs_reauth != self.account.needs_reauth {
                self.account = stored;
                self.pending = store::load_pending().filter(|p| p.is_fresh(now_unix()));
            }
        }
        self.account.needs_reauth
    }

    /// Saves the account without lifting a sign-in-again state another client stored meanwhile.
    /// Only a sign-in the person finishes lifts it, and those save directly.
    fn persist(&mut self) -> Result<()> {
        if !self.account.needs_reauth && store::load().is_ok_and(|a| a.needs_reauth) {
            self.account.needs_reauth = true;
            self.account.xcode_token = None;
        }
        store::save(&self.account)
    }

    /// Keeps the anisette server that worked (the client may have moved to a fallback).
    fn remember_anisette(&mut self) {
        let used = self.client.anisette().source().clone();
        if self.account.anisette.as_ref() != Some(&used) {
            self.account.anisette = Some(used);
        }
    }

    /// Starts a sign-in. `keep_password` lets the keeper re-sign without asking again.
    pub async fn sign_in(&mut self, apple_id: &str, password: &str, keep_password: bool) -> Result<Option<Pending>> {
        self.sign_in_as(apple_id, password, keep_password, gsa::CodeCaller::SignIn).await
    }

    /// A sign-in the person started. It goes ahead in the sign-in-again state, and lifts it once
    /// Apple opens the session.
    pub async fn sign_in_as(
        &mut self,
        apple_id: &str,
        password: &str,
        keep_password: bool,
        caller: gsa::CodeCaller,
    ) -> Result<Option<Pending>> {
        self.sync_account();
        self.start_sign_in(apple_id, password, keep_password, caller, true).await
    }

    /// A sign-in with the kept password that nobody asked for (renewals, teams, tokens). The stored
    /// sign-in-again state is read right before the request goes out, so a state another client
    /// stored while this one waited on Apple stops it.
    async fn background_sign_in(&mut self, apple_id: &str, password: &str) -> Result<Option<Pending>> {
        if self.sync_account() {
            return Err(gsa::incomplete_session());
        }
        let caller = self.caller;
        self.start_sign_in(apple_id, password, true, caller, false).await
    }

    async fn start_sign_in(
        &mut self,
        apple_id: &str,
        password: &str,
        keep_password: bool,
        caller: gsa::CodeCaller,
        by_person: bool,
    ) -> Result<Option<Pending>> {
        let now = now_unix();
        if self.account.is_rate_limited(now) {
            return Err(gsa::rate_limited());
        }
        if let Some(existing) = &mut self.pending {
            if existing.is_fresh_for(apple_id, now) {
                existing.keep_password = keep_password;
                let _ = store::save_pending(existing);
                return Ok(Some(existing.clone()));
            }
        }
        let outcome = match self.client.sign_in_with_caller(apple_id.trim(), password, caller).await {
            Ok(o) => o,
            Err(e) => {
                if gsa::is_rate_limit(&e) {
                    self.account.mark_rate_limited(now);
                    let _ = self.persist();
                }
                return Err(e);
            }
        };
        match outcome {
            SignInOutcome::SignedIn(session) => {
                self.pending = None;
                let _ = store::clear_pending();
                self.account.clear_rate_limit();
                self.remember_anisette();
                self.account.session = Some(session);
                self.account.password = keep_password.then(|| password.to_string());
                self.account.xcode_token = None;
                if by_person {
                    self.account.needs_reauth = false;
                    self.account.rejected_resign_in = false;
                    store::save(&self.account)?;
                } else {
                    self.persist()?;
                }
                Ok(None)
            }
            SignInOutcome::NeedsCode(mut p) => {
                p.keep_password = keep_password;
                p.anisette = Some(self.client.anisette().source().clone());
                self.remember_anisette();
                if by_person {
                    self.account.rejected_resign_in = false;
                }
                self.persist()?;
                let _ = store::save_pending(&p);
                self.pending = Some(p.clone());
                Ok(Some(p))
            }
        }
    }

    pub async fn finish_sign_in(&mut self, pending: Pending, code: &str) -> Result<()> {
        let now = now_unix();
        if self.account.is_rate_limited(now) {
            return Err(gsa::rate_limited());
        }
        let mut active = match self.pending.take() {
            Some(saved) if saved.same_challenge(&pending) => saved,
            _ => pending,
        };
        match self.client.finish(&mut active, code).await {
            Ok(session) => {
                self.pending = None;
                let _ = store::clear_pending();
                self.account.clear_rate_limit();
                self.account.needs_reauth = false;
                self.remember_anisette();
                self.account.password = active.keep_password.then(|| active.password_str().to_string());
                self.account.session = Some(session);
                self.account.xcode_token = None;
                store::save(&self.account)?;
                Ok(())
            }
            Err(e) => {
                if gsa::is_rate_limit(&e) {
                    self.account.mark_rate_limited(now);
                    let _ = self.persist();
                }
                if gsa::is_incomplete_session(&e) {
                    self.pending = None;
                    let _ = store::clear_pending();
                    self.account.needs_reauth = true;
                    self.account.xcode_token = None;
                    store::save(&self.account)?;
                } else {
                    let _ = store::save_pending(&active);
                    self.pending = Some(active);
                }
                Err(e)
            }
        }
    }

    pub fn cancel_sign_in(&mut self) -> Result<()> {
        self.pending = None;
        let _ = store::clear_pending();
        self.account = store::load()?;
        Ok(())
    }

    /// A new code for the sign-in waiting on one: always the person's request, so it goes ahead in
    /// the sign-in-again state. A verification step another client used up is dropped first.
    pub async fn resend_code(&mut self) -> Result<Pending> {
        self.sync_account();
        let now = now_unix();
        if self.account.is_rate_limited(now) {
            return Err(gsa::rate_limited());
        }
        let mut active = self
            .pending
            .take()
            .or_else(store::load_pending)
            .filter(|p| p.is_fresh(now))
            .ok_or_else(|| Error::NeedsPerson("Sign in again. The verification step has expired.".into()))?;
        let wait = active.resend_wait_secs(now);
        if wait > 0 {
            let _ = store::save_pending(&active);
            self.pending = Some(active);
            return Err(Error::NeedsPerson(format!("Wait {wait} seconds before requesting another verification code.")));
        }
        match self.client.resend(&mut active, now).await {
            Ok(()) => {
                let _ = store::save_pending(&active);
                self.pending = Some(active.clone());
                Ok(active)
            }
            Err(e) => {
                if gsa::is_rate_limit(&e) {
                    self.account.mark_rate_limited(now);
                    let _ = self.persist();
                }
                let _ = store::save_pending(&active);
                self.pending = Some(active);
                Err(e)
            }
        }
    }

    pub fn sign_out(&mut self) -> Result<()> {
        self.pending = None;
        let _ = store::clear_pending();
        self.account = store::Account { anisette: self.account.anisette.clone(), ..Default::default() };
        store::clear()?;
        store::save(&self.account)
    }

    async fn fetch_xcode_token(&mut self, session: &gsa::Session) -> Result<AppToken> {
        match self.client.xcode_token(session).await {
            Ok(t) => Ok(t),
            Err(e) => {
                if gsa::is_rate_limit(&e) {
                    self.account.mark_rate_limited(now_unix());
                    let _ = self.persist();
                }
                Err(e)
            }
        }
    }

    /// A token good for at least ten minutes, refreshed from the session or, when the
    /// session is expired and the password is kept, from a fresh sign-in.
    pub async fn token(&mut self) -> Result<AppToken> {
        self.sync_account();
        let now = now_unix();
        if self.account.is_rate_limited(now) {
            return Err(gsa::rate_limited());
        }
        if let Some(pending) = &self.pending {
            if pending.is_fresh(now) {
                return Err(Error::NeedsCode(Box::new(pending.clone())));
            }
            self.pending = None;
            let _ = store::clear_pending();
        }
        if self.account.needs_reauth {
            return Err(gsa::incomplete_session());
        }
        if let Some(t) = &self.account.xcode_token {
            if t.valid_for(600) {
                return Ok(t.clone());
            }
        }
        let session = self.account.session.clone().ok_or_else(|| Error::NeedsPerson("Sign in with your Apple ID first.".into()))?;
        let fetched = self.fetch_xcode_token(&session).await;
        // Another client may have stored the sign-in-again state while Apple answered.
        if self.sync_account() {
            return Err(gsa::incomplete_session());
        }
        let fresh = match fetched {
            Ok(t) => t,
            // An expired session, or one Apple turned away with -22411: sign in again with the kept
            // password. When Apple wants a code for it, the app asks the person for that code.
            // Turned away again after a sign-in that the last -22411 started (for example one that
            // went through a code): wait for the person.
            Err(e) if gsa::is_session_rejected(&e) && self.account.rejected_resign_in => {
                tracing::warn!("Apple turned the new session away as well ({e}); waiting for the person to sign in");
                self.account.xcode_token = None;
                self.account.needs_reauth = true;
                store::save(&self.account)?;
                return Err(e);
            }
            Err(e) if (gsa::is_session_expired(&e) || gsa::is_session_rejected(&e)) && self.account.password.is_some() => {
                let rejected = gsa::is_session_rejected(&e);
                tracing::warn!("Apple turned the session away ({e}); signing in again with the kept password");
                let (id, pw) = (session.apple_id.clone(), self.account.password.clone().unwrap());
                // A sign-in that fails on the way (no network, a 503) leaves the old session and
                // no guard, so the next call tries again.
                let outcome = self.background_sign_in(&id, &pw).await?;
                if rejected {
                    self.account.rejected_resign_in = true;
                    self.persist()?;
                }
                match outcome {
                    None => {
                        let s = self.account.session.clone().unwrap();
                        match self.fetch_xcode_token(&s).await {
                            Ok(t) => t,
                            // The new session was turned away as well. Signing in again by itself
                            // would only repeat it (and may ask Apple for more codes), so wait for
                            // the person to sign in.
                            Err(e2) if rejected && gsa::is_session_rejected(&e2) => {
                                self.account.xcode_token = None;
                                self.account.needs_reauth = true;
                                store::save(&self.account)?;
                                return Err(e2);
                            }
                            Err(e2) => return Err(e2),
                        }
                    }
                    Some(pending) => return Err(Error::NeedsCode(Box::new(pending))),
                }
            }
            // Turned away with no kept password: the person signs in again.
            Err(e) if gsa::is_session_rejected(&e) => {
                tracing::warn!("Apple turned the session away ({e}) and no password is kept");
                self.account.xcode_token = None;
                let _ = self.persist();
                return Err(Error::NeedsPerson(gsa::SESSION_EXPIRED.into()));
            }
            Err(e) => return Err(e),
        };
        self.account.xcode_token = Some(fresh.clone());
        self.account.rejected_resign_in = false;
        self.persist()?;
        if self.account.needs_reauth {
            return Err(gsa::incomplete_session());
        }
        Ok(fresh)
    }

    pub async fn teams(&mut self) -> Result<Vec<Team>> {
        let saved = self.account.xcode_token.clone();
        let token = self.token().await?;
        match self.list_teams(&token).await {
            // The portal turned away the saved Xcode token though Apple's own time on it has not run
            // out. Drop it and ask once more with a fresh one: from the session, or with a kept password
            // from one fresh sign-in. Without a password this ends in SESSION_EXPIRED, and the app asks
            // the person to sign in again. Only the portal's answer leads here. When token() itself
            // fails, such as a kept password Apple no longer takes, nothing is tried again, since every
            // wrong password brings Apple's account lock closer. Nor when token() had only just fetched
            // the token: another one from the same session would fare no better.
            Err(e) if portal::turned_token_away(&e) && saved.is_some_and(|s| s.token == token.token) => {
                self.account.xcode_token = None;
                self.persist()?;
                let token = self.token().await?;
                self.list_teams(&token).await
            }
            other => other,
        }
    }

    async fn list_teams(&mut self, token: &AppToken) -> Result<Vec<Team>> {
        let session = self.account.session.clone().unwrap();
        let mut portal = Portal::new(&session, token, self.client.anisette())?;
        portal.teams().await
    }

    /// The team to use: the chosen one, or the only one, or the first free one.
    pub async fn team(&mut self) -> Result<Team> {
        let teams = self.teams().await?;
        if let Some(id) = &self.account.team_id {
            if let Some(t) = teams.iter().find(|t| &t.team_id == id) {
                return Ok(t.clone());
            }
        }
        let pick = if teams.len() == 1 { teams[0].clone() } else { teams.iter().find(|t| !t.is_free).or(teams.first()).cloned().unwrap() };
        self.account.team_id = Some(pick.team_id.clone());
        self.persist()?;
        Ok(pick)
    }

    #[cfg(feature = "device")]
    pub(crate) async fn check_update_identity(&mut self, team: &str, certificate: &str) -> Result<()> {
        let token = self.token().await?;
        let session = self.account.session.clone().ok_or_else(|| Error::UpdateCheck("Sign in on the original signing computer, then retry update-only."))?;
        let mut portal = Portal::new(&session, &token, self.client.anisette())?;
        identity::update_certificate(&mut portal, team, certificate).await?;
        Ok(())
    }

    #[cfg(feature = "device")]
    pub(crate) async fn sign_update(&mut self, team: &Team, unpacked: sign::Unpacked, certificate: &str, out: &Path, reporter: &Reporter) -> Result<SignedBuild> {
        let token = self.token().await?;
        let session = self.account.session.clone().ok_or_else(|| Error::msg("Sign in on the original signing computer, then retry update-only."))?;
        let mut portal = Portal::new(&session, &token, self.client.anisette())?;
        let ident = identity::existing_for_update(&mut portal, &team.team_id, certificate).await?;
        sign_prepared(&mut portal, team, unpacked, ident, out, reporter, true).await
    }

    /// For support: the chosen team's development certificates as Apple lists them.
    pub async fn diagnose_certificates(&mut self) -> Result<Vec<String>> {
        let team = self.team().await?;
        let token = self.token().await?;
        let session = self.account.session.clone().unwrap();
        let mut portal = Portal::new(&session, &token, self.client.anisette())?;
        identity::diagnose(&mut portal, &team.team_id).await
    }

    pub fn choose_team(&mut self, team_id: &str) -> Result<()> {
        self.account.team_id = Some(team_id.to_string());
        self.persist()
    }
}

pub struct SignedBuild {
    pub ipa: PathBuf,
    pub bundle_id: String,
    pub app_group: String,
    pub version: String,
    pub build: String,
    pub profile_expires_at: i64,
    pub profiles: Vec<Vec<u8>>,
    pub notes: Vec<String>,
    /// The key and certificate Poki was signed with, handed to Poki so it can re-sign itself.
    pub identity: identity::Identity,
}

/// Where Poki looks for the signing identity Poki Setup hands over (inside its container).
pub const SIGNING_IDENTITY_PATH: &str = "Documents/PokiSetup/signing-identity.json";

/// `poki.signing-identity/1`: what Poki needs to renew its own signature on the phone.
pub fn signing_identity_json(ident: &identity::Identity, apple_id: &str) -> Result<Vec<u8>> {
    use base64::Engine;
    use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey};
    let key = rsa::RsaPrivateKey::from_pkcs8_der(&ident.key_pkcs8).map_err(|e| Error::msg(e.to_string()))?;
    let pem = key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).map_err(|e| Error::msg(e.to_string()))?;
    Ok(serde_json::to_vec_pretty(&serde_json::json!({
        "schema": "poki.signing-identity/1",
        "team_id": ident.team_id,
        "key_pkcs8_pem": pem.as_str(),
        "certificate_serial": ident.certificate.serial_number,
        "certificate_id": ident.certificate.certificate_id,
        "certificate_der_b64": base64::engine::general_purpose::STANDARD.encode(&ident.certificate.der),
        "apple_id": apple_id,
    }))?)
}

/// Writes the signing identity into Poki's container. Failing is not fatal: Poki then needs the
/// computer for renewals, as before.
#[cfg(feature = "device")]
async fn hand_signing_identity(phone: &device::Phone, built: &SignedBuild, apple_id: &str, reporter: &Reporter) {
    let res = async {
        let bytes = signing_identity_json(&built.identity, apple_id)?;
        device::container::write_file(phone, &built.bundle_id, SIGNING_IDENTITY_PATH, &bytes).await
    }
    .await;
    match res {
        Ok(()) => reporter.note("pairing_file", "Gave Poki its signing identity, so it can renew itself"),
        Err(e) => reporter.note("pairing_file", format!("Could not give Poki its signing identity ({e}); renewals stay on this computer.")),
    }
}

/// Signs an IPA for a team: device, identity, App IDs, group, profiles, signature.
pub async fn sign_for_team(signer: &mut Signer, team: &Team, phone: Option<(&str, &str)>, ipa: &Path, signing_zip: Option<&Path>, out: &Path, reporter: &Reporter) -> Result<SignedBuild> {
    reporter.step("sign", &format!("Signing Poki for {}", team.name));
    let token = signer.token().await?;
    let session = signer.account.session.clone().unwrap();
    let mut portal = Portal::new(&session, &token, signer.client.anisette())?;
    if let Some((udid, name)) = phone {
        reporter.part("sign", 0.02, Some("Registering the iPhone with the team".into()));
        portal.ensure_device(&team.team_id, udid, name).await?;
    }
    let ident = identity::ensure(&mut portal, &team.team_id, reporter).await?;
    let requested = match signing_zip {
        Some(z) => sign::requested_from_signing_zip(z, "external").unwrap_or_default(),
        None => Default::default(),
    };
    let unpacked = sign::unpack(ipa, &team.team_id, &requested, reporter)?;
    sign_prepared(&mut portal, team, unpacked, ident, out, reporter, false).await
}

async fn sign_prepared(portal: &mut Portal<'_>, team: &Team, unpacked: sign::Unpacked, ident: identity::Identity, out: &Path, reporter: &Reporter, preserve_group: bool) -> Result<SignedBuild> {
    let group = portal.ensure_app_group(&team.team_id, &unpacked.app_group, "Poki").await?;
    let mut profiles = vec![];
    let mut raw_profiles = vec![];
    let mut expires = i64::MAX;
    for (i, b) in unpacked.bundles.iter().enumerate() {
        reporter.part("sign", 0.1 + 0.3 * (i as f64 / unpacked.bundles.len() as f64), Some(format!("App ID and profile for {}", b.name)));
        let name = if b.rel.is_empty() { "Poki".to_string() } else { format!("Poki {}", b.name.trim_start_matches("Poki")) };
        let app_id = portal.ensure_app_id(&team.team_id, &b.new_id, &name).await?;
        portal.enable_feature(&team.team_id, &app_id, FEATURE_APP_GROUPS).await?;
        portal.assign_app_group(&team.team_id, &app_id, &group).await?;
        let p = portal.profile(&team.team_id, &app_id).await?;
        let parsed = sign::profile::parse(&p.data)?;
        if preserve_group {
            let merged = sign::entitlements::merge(&b.requested, &parsed.entitlements);
            let groups = merged.get("com.apple.security.application-groups").and_then(|v| v.as_array());
            if !groups.is_some_and(|groups| groups.iter().any(|v| v.as_string() == Some(unpacked.app_group.as_str()))) {
                return Err(Error::UpdateCheck("The signing profile cannot preserve the installed app group; keep Poki installed and use the original signing setup."));
            }
        }
        expires = expires.min(parsed.expires_at);
        raw_profiles.push(p.data.clone());
        profiles.push((b.new_id.clone(), parsed));
    }
    let notes = sign::sign(&unpacked, &ident, &profiles, reporter)?;
    reporter.part("sign", 0.9, Some("Packing".into()));
    sign::pack(&unpacked, out)?;
    reporter.done("sign", Some(format!("Poki {} ({}) signed for {}", unpacked.version, unpacked.build, team.name)));
    let mut all_notes = notes;
    for d in &unpacked.dropped_extensions {
        all_notes.push(format!("{d} left out: a team profile cannot carry the packet-tunnel entitlement, so Poki uses your proxy app's loopback instead."));
    }
    Ok(SignedBuild { ipa: out.to_path_buf(), bundle_id: unpacked.bundles[0].new_id.clone(), app_group: unpacked.app_group.clone(), version: unpacked.version.clone(), build: unpacked.build.clone(), profile_expires_at: expires, profiles: raw_profiles, notes: all_notes, identity: ident })
}

#[cfg(feature = "device")]
#[derive(Debug, Clone, Default)]
pub struct Options {
    pub udid: Option<String>,
    pub ipa: Option<PathBuf>,
    pub signing_zip: Option<PathBuf>,
    /// How long to wait for Trust This Computer / the Developer Mode restart.
    pub wait: Option<Duration>,
    /// Also serve the pairing file on the LAN for the phone's QR (for later, Wi-Fi-only use).
    pub hand_off: bool,
    /// Pre-seed the developer disk image into Poki's container.
    pub seed_ddi: bool,
    /// The test build `ipa` came from (Developer > Test Builds), kept in the device's record so
    /// renewals can sign it again.
    pub test_build: Option<crate::devbuilds::BuildRef>,
    /// Close Poki on the device before replacing it. Without it, an install that finds Poki
    /// running stops with [`Error::PokiRunning`] so the person can be asked first.
    pub close_poki: bool,
}

#[cfg(feature = "device")]
pub struct Done {
    pub record: keeper::Record,
    pub handoff: Option<pairshare::Server>,
    pub notes: Vec<String>,
}

#[cfg(feature = "device")]
/// Picks the phone: the one asked for, else the one USB phone.
pub async fn pick_phone(udid: Option<&str>) -> Result<Phone> {
    let phones = Phone::list().await?;
    if let Some(u) = udid {
        if let Some(p) = phones.into_iter().find(|p| p.udid == u) {
            return Ok(p);
        }
        if let Some(rec) = keeper::get(u)? {
            if let Some(addr) = rec.wifi_address.and_then(|a| a.parse().ok()) {
                return Ok(Phone::over_wifi(u, addr));
            }
        }
        return Err(Error::device("That iPhone is not connected. Plug it in with a cable."));
    }
    let usb: Vec<_> = phones.iter().filter(|p| p.is_usb()).cloned().collect();
    match usb.len() {
        0 if phones.is_empty() => Err(Error::device("No iPhone found. Plug it in with a cable and unlock it.")),
        0 => Ok(phones[0].clone()),
        1 => Ok(usb[0].clone()),
        _ => Err(Error::device("More than one iPhone is plugged in. Choose one.")),
    }
}

#[cfg(feature = "device")]
/// The one-click setup.
pub async fn run(signer: &mut Signer, opts: Options, reporter: &Reporter) -> Result<Done> {
    let wait = opts.wait.unwrap_or(Duration::from_secs(120));
    reporter.step("phone", "Finding the iPhone");
    let phone = pick_phone(opts.udid.as_deref()).await?;
    reporter.done("phone", Some(phone.udid.clone()));

    reporter.step("pair", "Pairing with the iPhone");
    let lockdown_record = device::pairing::pair(&phone, reporter, wait).await?;
    if let Err(e) = device::pairing::enable_network(&phone).await {
        reporter.note("pair", format!("Could not let the iPhone use this pairing over the network ({e}); Poki may need to pair on the phone."));
    }
    let facts = device::info::read(&phone).await?;
    // iOS 26.4 and later only accept an RPPairing record over the loopback Poki uses.
    let needs_remote = device::pairing::needs_remote_record(&facts.ios);
    let record = match device::pairing::pair_remote(&phone, reporter, wait).await {
        Ok(r) => Some(r),
        Err(e) if needs_remote => {
            reporter.note("pair", format!("Remote pairing did not finish ({e}). Poki can pair on the iPhone instead."));
            None
        }
        Err(e) => {
            tracing::info!("remote pairing not made, using the lockdown record: {e}");
            Some(lockdown_record)
        }
    };
    reporter.done("pair", Some(format!("{} · iOS {}", facts.name, facts.ios)));

    reporter.step("devmode", "Developer Mode");
    if facts.developer_mode != Some(true) {
        let already = device::devmode::enable(&phone, reporter).await?;
        if !already {
            device::devmode::wait_until_on(&phone.udid, reporter, wait).await?;
        }
    }
    reporter.done("devmode", Some("on".into()));

    reporter.step("account", "Apple account");
    let team = signer.team().await?;
    reporter.done("account", Some(format!("{} ({})", team.name, if team.is_free { "free, 7-day signing" } else { "paid" })));

    match &opts.test_build {
        Some(b) if opts.ipa.is_none() => reporter.step("release", &format!("Downloading test build {}", b.run_number)),
        _ => reporter.step("release", "Getting Poki"),
    }
    let (ipa, signing_zip, tag) = match &opts.ipa {
        None if opts.test_build.is_some() => {
            let b = opts.test_build.as_ref().expect("checked above");
            let (ipa, zipp) = crate::devbuilds::fetch(b.artifact_id, reporter, "release").await?;
            (ipa, zipp, b.tag())
        }
        Some(p) => {
            let beside = p.with_file_name("Poki-signing.zip");
            let zipp = opts.signing_zip.clone().or_else(|| beside.is_file().then_some(beside));
            let tag = match &opts.test_build {
                Some(b) => b.tag(),
                None => format!("local:{}", p.file_name().unwrap_or_default().to_string_lossy()),
            };
            (p.clone(), zipp, tag)
        }
        None => {
            let rel = release::latest().await?;
            let (ipa, zipp) = release::fetch(&rel, reporter).await?;
            (ipa, zipp, rel.tag)
        }
    };
    reporter.done("release", Some(tag.clone()));

    let out = crate::paths::cache_dir()?.join(format!("Poki-{}-{}.ipa", team.team_id, phone.udid));
    let built = sign_for_team(signer, &team, Some((&phone.udid, &facts.name)), &ipa, signing_zip.as_deref(), &out, reporter).await?;

    reporter.step("install", "Installing");
    device::install::install_profiles(&phone, &built.profiles, reporter).await?;
    let existing = device::install::find_apps(&phone, crate::POKI_BUNDLE_ID).await.unwrap_or_default();
    let upgrade = existing.iter().any(|a| a.bundle_id == built.bundle_id);
    if upgrade {
        let path = existing.iter().find(|a| a.bundle_id == built.bundle_id).and_then(|a| a.path.clone());
        make_sure_poki_is_closed(&phone, path, opts.close_poki, reporter).await?;
    }
    device::install::install_ipa(&phone, &built.ipa, upgrade, reporter).await?;

    reporter.step("pairing_file", "Giving Poki its pairing file");
    let mut handed = false;
    match &record {
        None => reporter.done("pairing_file", Some("Poki pairs on the iPhone itself".into())),
        Some(record) => {
            // Right after an install the phone sometimes drops the first container connection; try again.
            let mut placed = device::container::place_pairing_file(&phone, &built.bundle_id, record).await;
            for _ in 0..2 {
                if placed.is_ok() { break; }
                tokio::time::sleep(Duration::from_secs(2)).await;
                placed = device::container::place_pairing_file(&phone, &built.bundle_id, record).await;
            }
            match placed {
                Ok(true) => {
                    handed = true;
                    reporter.done("pairing_file", Some("placed in Poki's container".into()));
                }
                Ok(false) => {
                    handed = true;
                    reporter.done("pairing_file", Some("Poki already has its own pairing; kept it".into()));
                }
                Err(e) => reporter.note("pairing_file", format!("Could not write into Poki's container ({e}); the QR hand-off below does it instead.")),
            }
        }
    }
    let apple_id = signer.account.apple_id().unwrap_or("").to_string();
    hand_signing_identity(&phone, &built, &apple_id, reporter).await;
    if opts.seed_ddi {
        if let Err(e) = device::ddi::seed_container(&phone, &built.bundle_id, reporter).await {
            reporter.note("pairing_file", format!("Developer disk image not pre-seeded ({e}); Poki downloads it itself."));
        }
        // Mount it too, from here, so automation can start before Poki ever reaches its loopback.
        // Poki mounts it again by itself after a restart; a failure here only means it will.
        if !matches!(device::ddi::mounted(&phone).await, Ok(true)) {
            if let Err(e) = device::ddi::mount(&phone, reporter).await {
                tracing::warn!(error = %e, "mounting the developer disk image from the computer failed");
                reporter.note("mount", format!("The developer disk image was not mounted from this computer ({e}). Poki mounts it itself when it connects."));
                reporter.done("mount", None);
            }
        }
    }
    let handoff = if let (true, Some(record)) = (opts.hand_off || !handed, &record) {
        let server = pairshare::serve(record.clone()).await?;
        reporter.waiting("pairing_file", format!("Scan the code with the iPhone's Camera, or open {} on the iPhone", server.handoff.link));
        Some(server)
    } else {
        None
    };

    let rec = keeper::Record {
        udid: phone.udid.clone(),
        phone_name: facts.name.clone(),
        ios: facts.ios.clone(),
        apple_id: signer.account.apple_id().unwrap_or("").to_string(),
        team_id: team.team_id.clone(),
        team_name: team.name.clone(),
        team_is_free: team.is_free,
        bundle_id: built.bundle_id.clone(),
        app_group: built.app_group.clone(),
        version: built.version.clone(),
        build: built.build.clone(),
        release_tag: tag,
        signed_at: keeper::now(),
        profile_expires_at: built.profile_expires_at,
        last_checked_at: Some(keeper::now()),
        last_error: None,
        wifi_address: facts.wifi_address.clone(),
        pairing_handed_off: handed,
        test_build: opts.test_build.clone(),
    };
    keeper::put(rec.clone())?;
    reporter.done("all", Some(format!("Poki {} is on {}", built.version, facts.name)));
    Ok(Done { record: rec, handoff, notes: built.notes })
}

#[cfg(feature = "device")]
/// Before an update replaces Poki: checks it is not running, and closes it when `close` says so.
/// When the device cannot say what is running (the developer disk image is not mounted, an older
/// iOS), the update goes on, as it did before this check.
pub async fn make_sure_poki_is_closed(phone: &Phone, app_path: Option<String>, close: bool, reporter: &Reporter) -> Result<()> {
    reporter.step("close", "Making sure Poki is closed");
    if !matches!(device::ddi::mounted(phone).await, Ok(true)) {
        if let Err(e) = device::ddi::mount(phone, &Reporter::silent()).await {
            tracing::warn!(error = %e, "could not mount the developer disk image before checking for Poki");
        }
    }
    match device::running::poki(phone, app_path.clone()).await {
        Ok(list) if list.is_empty() => {
            reporter.done("close", Some("Poki is not running".into()));
            Ok(())
        }
        Ok(_) if close => {
            reporter.part("close", 0.5, Some("Closing Poki on the device".into()));
            device::running::close_poki(phone, app_path).await?;
            reporter.done("close", Some("Closed Poki".into()));
            Ok(())
        }
        Ok(_) => Err(Error::PokiRunning("Poki is open on the device. Close it before updating, or let Poki Setup close it.".into())),
        Err(e) => {
            tracing::warn!(error = %e, "could not check whether Poki is running");
            reporter.note("close", format!("Could not check whether Poki is running ({e}). Updating anyway."));
            reporter.done("close", None);
            Ok(())
        }
    }
}

/// Whether Poki is running on the device: Some(true or false), or None when the device cannot say.
#[cfg(feature = "device")]
pub async fn poki_running(udid: &str) -> Result<Option<bool>> {
    let phone = pick_phone(Some(udid)).await?;
    if !matches!(device::ddi::mounted(&phone).await, Ok(true)) {
        let _ = device::ddi::mount(&phone, &Reporter::silent()).await;
    }
    let path = device::install::find_apps(&phone, crate::POKI_BUNDLE_ID).await.ok().and_then(|apps| apps.into_iter().find_map(|a| a.path));
    match device::running::poki(&phone, path).await {
        Ok(l) => Ok(Some(!l.is_empty())),
        Err(e) => {
            tracing::warn!(error = %e, "could not tell whether Poki is running");
            Ok(None)
        }
    }
}

#[cfg(feature = "device")]
/// Signs Poki again for a phone this computer set up and reinstalls it (an upgrade keeps data).
pub async fn renew(signer: &mut Signer, udid: &str, reporter: &Reporter) -> Result<keeper::Record> {
    if signer.sync_account() {
        return Err(gsa::incomplete_session());
    }
    let rec = keeper::get(udid)?.ok_or_else(|| Error::msg("This computer did not set up that iPhone."))?;
    let result: Result<keeper::Record> = async {
        let phone = pick_phone(Some(udid)).await?;
        if !device::pairing::verify(&phone).await? {
            return Err(Error::device("The iPhone no longer trusts this computer. Plug it in and tap Trust."));
        }
        let facts = device::info::read(&phone).await?;
        let teams = signer.teams().await?;
        let team = teams.into_iter().find(|t| t.team_id == rec.team_id).ok_or_else(|| Error::msg(format!("The Apple ID signed in is not on team {} any more.", rec.team_name)))?;
        // A test build is signed again while renewals keep test builds (Developer > Test Builds).
        let kept = match &rec.test_build {
            Some(b) => crate::devbuilds::for_renewal(b, reporter).await.map(|found| (found, b.clone())),
            None => None,
        };
        let (ipa, zipp, tag, test_build) = match kept {
            Some(((ipa, zipp), b)) => (ipa, zipp, b.tag(), Some(b)),
            None => {
                let rel = release::latest().await?;
                let (ipa, zipp) = release::fetch(&rel, reporter).await?;
                (ipa, zipp, rel.tag, None)
            }
        };
        let out = crate::paths::cache_dir()?.join(format!("Poki-{}-{}.ipa", team.team_id, udid));
        let built = sign_for_team(signer, &team, Some((udid, &facts.name)), &ipa, zipp.as_deref(), &out, reporter).await?;
        device::install::install_profiles(&phone, &built.profiles, reporter).await?;
        // A renewal runs by itself, or after the person was asked: it closes Poki first.
        let path = device::install::find_apps(&phone, &rec.bundle_id).await.ok().and_then(|apps| apps.into_iter().find(|a| a.bundle_id == rec.bundle_id).and_then(|a| a.path));
        make_sure_poki_is_closed(&phone, path, true, reporter).await?;
        device::install::install_ipa(&phone, &built.ipa, true, reporter).await?;
        let apple_id = signer.account.apple_id().unwrap_or("").to_string();
        hand_signing_identity(&phone, &built, &apple_id, reporter).await;
        Ok(keeper::Record { version: built.version, build: built.build, release_tag: tag, test_build, signed_at: keeper::now(), profile_expires_at: built.profile_expires_at, last_checked_at: Some(keeper::now()), last_error: None, wifi_address: facts.wifi_address.clone().or(rec.wifi_address.clone()), ..rec.clone() })
    }
    .await;
    match result {
        Ok(r) => {
            keeper::put(r.clone())?;
            Ok(r)
        }
        Err(e) => {
            keeper::note_check(udid, Some(e.to_string()))?;
            Err(e)
        }
    }
}

#[cfg(feature = "device")]
/// Renews every phone that is due. Returns (udid, result) pairs.
pub async fn renew_due(signer: &mut Signer, reporter: &Reporter) -> Vec<(String, Result<keeper::Record>)> {
    if signer.sync_account() || signer.is_rate_limited() || signer.pending().is_some() {
        return vec![];
    }
    let prev_caller = signer.caller;
    signer.set_caller(gsa::CodeCaller::KeeperRenew);
    let mut out = vec![];
    for r in keeper::due().unwrap_or_default() {
        let res = renew(signer, &r.udid, reporter).await;
        let stop = matches!(&res, Err(Error::NeedsCode(_))) || matches!(&res, Err(e) if gsa::is_rate_limit(e));
        out.push((r.udid.clone(), res));
        if stop {
            break;
        }
    }
    signer.set_caller(prev_caller);
    out
}
