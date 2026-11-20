//! Test builds for people developing Poki: the IPAs that GitHub Actions runs leave as artifacts
//! (`Poki-unsigned` from the iOS IPA workflow, `Poki-preview-pr<N>-…` from pull request previews).
//! None of this touches GitHub Releases or the channels.
//!
//! - The GitHub sign-in: GitHub's device sign-in under the Poki Preview Sign-in app, the GitHub
//!   CLI's sign-in on this computer, or a token pasted by hand. The token stays with the secrets.
//! - The list: every IPA artifact with its run (run number, workflow, branch, commit, who started
//!   it), the pull request it belongs to, and the runs still building. Filters (only runs started
//!   by the signed-in account, one branch, only builds with a pull request) are saved here so the
//!   automatic sync follows the same ones as the list.
//! - Download: the artifact's zip into the cache, the IPA checked against its SHA256SUMS.
//! - Renewals of a phone that has a test build sign that same build again while it is cached.
use crate::{Error, Reporter, Result, paths, release};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const TOKEN: &str = "github-token";

/// The client ID of Poki Preview Sign-in, the GitHub App the sign-in runs under. It can read the
/// repository's Actions and pull requests and nothing else, and needs no client secret.
/// `POKI_GITHUB_CLIENT_ID` overrides it for development.
pub const SIGN_IN_APP_CLIENT_ID: &str = "Iv23lizFeswRVZtONUKT";

/// Workflows whose runs leave a Poki IPA, besides any other run seen with one.
const IPA_WORKFLOWS: [&str; 2] = [".github/workflows/ios-ipa.yml", ".github/workflows/pr-preview.yml"];

fn is_ipa_artifact(name: &str) -> bool { name == "Poki-unsigned" || name.starts_with("Poki-preview-pr") }

// MARK: Settings

/// What the Developer pages choose. Saved in `state/test-builds.json`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Prefs {
    /// Only runs the signed-in GitHub account started.
    #[serde(default = "yes")]
    pub only_mine: bool,
    /// Only this branch.
    #[serde(default)]
    pub branch: Option<String>,
    /// Only builds that belong to a pull request.
    #[serde(default)]
    pub with_pr_only: bool,
    /// Download each new build that matches the filters as soon as GitHub has it.
    #[serde(default)]
    pub auto_download: bool,
    /// Also install it on `auto_install_udid` when that device is connected.
    #[serde(default)]
    pub auto_install: bool,
    #[serde(default)]
    pub auto_install_udid: Option<String>,
    /// Renewing a device that has a test build signs the same build again (else the release).
    #[serde(default = "yes")]
    pub keep_on_renew: bool,
    /// Close Poki on the device before an install replaces it, without asking first.
    #[serde(default)]
    pub close_without_asking: bool,
}
fn yes() -> bool { true }

impl Default for Prefs {
    fn default() -> Self { Prefs { only_mine: true, branch: None, with_pr_only: false, auto_download: false, auto_install: false, auto_install_udid: None, keep_on_renew: true, close_without_asking: false } }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Settings {
    #[serde(default)]
    github_login: Option<String>,
    /// "github" (device sign-in), "cli" (GitHub CLI) or "token" (pasted).
    #[serde(default)]
    token_source: Option<String>,
    /// The newest run the automatic sync has handled; it only acts on newer ones.
    #[serde(default)]
    synced_run: Option<u64>,
    #[serde(default, flatten)]
    prefs: Prefs,
}

fn settings_path() -> Result<PathBuf> { Ok(paths::state_dir()?.join("test-builds.json")) }

fn read_settings() -> Settings { settings_path().ok().and_then(|p| std::fs::read(p).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default() }

fn write_settings(s: &Settings) -> Result<()> {
    let p = settings_path()?;
    let tmp = p.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(s)?)?;
    std::fs::rename(tmp, p)?;
    Ok(())
}

// MARK: GitHub sign-in

/// The saved token. `POKI_GITHUB_TOKEN` stands in for it (development and scripts).
pub fn token() -> Option<String> {
    std::env::var("POKI_GITHUB_TOKEN").ok().filter(|t| !t.trim().is_empty()).or_else(|| crate::apple::store::secret_get(TOKEN))
}

/// The sign-in and the saved choices, for the Developer pages.
#[derive(Debug, Clone, Serialize)]
pub struct State {
    pub signed_in: bool,
    pub login: Option<String>,
    /// "github", "cli" or "token".
    pub source: Option<String>,
    /// The GitHub CLI is installed here, so its sign-in can be used.
    pub cli_available: bool,
    pub can_sign_in: bool,
    pub prefs: Prefs,
    pub synced_run: Option<u64>,
    /// Bytes of downloaded test builds in the cache.
    pub downloads_bytes: u64,
    pub repo: String,
}

pub fn state() -> State {
    let s = read_settings();
    let signed_in = token().is_some();
    State {
        signed_in,
        login: if signed_in { s.github_login.clone() } else { None },
        source: if signed_in { s.token_source.clone() } else { None },
        cli_available: gh_cli().is_some(),
        can_sign_in: client_id().is_ok(),
        prefs: s.prefs,
        synced_run: s.synced_run,
        downloads_bytes: downloads_dir().map(|d| dir_size(&d)).unwrap_or(0),
        repo: release::repo(),
    }
}

/// Saves the filters and the automatic sync. Turning the sync on starts it at the newest build
/// there is now, so only builds made after that are downloaded or installed by themselves.
pub async fn set_prefs(prefs: Prefs) -> Result<State> {
    let mut s = read_settings();
    let starting = (prefs.auto_download || prefs.auto_install) && !(s.prefs.auto_download || s.prefs.auto_install);
    let filters_changed = prefs.only_mine != s.prefs.only_mine || prefs.branch != s.prefs.branch || prefs.with_pr_only != s.prefs.with_pr_only;
    s.prefs = prefs;
    write_settings(&s)?;
    if (starting || filters_changed) && token().is_some() {
        if let Ok(list) = list(false).await {
            let newest = list.builds.iter().filter(|b| b.state == BuildState::Ready).map(|b| b.run_id).max();
            let mut s = read_settings();
            s.synced_run = newest.max(s.synced_run);
            write_settings(&s)?;
        }
    }
    Ok(state())
}

/// Saves a token (signing in) or forgets it when empty (signing out).
pub fn set_token(token: &str, source: &str, login: Option<String>) -> Result<()> {
    let token = token.trim();
    let mut s = read_settings();
    if token.is_empty() {
        s.github_login = None;
        s.token_source = None;
        write_settings(&s)?;
        if let Ok(mut c) = LISTING.lock() {
            *c = None;
        }
        return crate::apple::store::secret_delete(TOKEN);
    }
    if token.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(Error::msg("That does not look like a GitHub token."));
    }
    crate::apple::store::secret_set(TOKEN, token)?;
    s.github_login = login;
    s.token_source = Some(source.to_string());
    write_settings(&s)
}

pub fn sign_out() -> Result<State> {
    set_token("", "", None)?;
    Ok(state())
}

/// Checks a token with GitHub and returns the account's login.
async fn login_of(token: &str) -> Result<String> {
    #[derive(Deserialize)]
    struct User {
        login: String,
    }
    let res = client()?.get("https://api.github.com/user").bearer_auth(token).header("Accept", "application/vnd.github+json").timeout(Duration::from_secs(30)).send().await?;
    if matches!(res.status().as_u16(), 401 | 403) {
        return Err(Error::msg("GitHub did not accept that sign-in."));
    }
    Ok(res.error_for_status()?.json::<User>().await?.login)
}

/// A token pasted by hand (a fine-grained token with Actions read is enough).
pub async fn use_token(token: &str) -> Result<State> {
    let login = login_of(token.trim()).await?;
    set_token(token, "token", Some(login))?;
    Ok(state())
}

/// The GitHub CLI, where it is usually installed (an app does not get the shell's PATH).
fn gh_cli() -> Option<PathBuf> {
    let mut places: Vec<PathBuf> = vec!["/opt/homebrew/bin/gh".into(), "/usr/local/bin/gh".into(), "/usr/bin/gh".into()];
    if let Some(path) = std::env::var_os("PATH") {
        for d in std::env::split_paths(&path) {
            places.push(d.join(if cfg!(windows) { "gh.exe" } else { "gh" }));
        }
    }
    if cfg!(windows) {
        if let Some(pf) = std::env::var_os("ProgramFiles") {
            places.push(PathBuf::from(pf).join("GitHub CLI").join("gh.exe"));
        }
    }
    places.into_iter().find(|p| p.is_file())
}

/// Uses the account the GitHub CLI is signed in to on this computer.
pub async fn use_cli() -> Result<State> {
    let gh = gh_cli().ok_or_else(|| Error::msg("The GitHub CLI (gh) is not installed on this computer."))?;
    let out = tokio::process::Command::new(gh).args(["auth", "token", "--hostname", "github.com"]).output().await?;
    let token = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() || token.is_empty() {
        return Err(Error::msg("The GitHub CLI is not signed in. Run gh auth login in Terminal, then try again."));
    }
    let login = login_of(&token).await?;
    set_token(&token, "cli", Some(login))?;
    Ok(state())
}

fn client_id() -> Result<String> {
    std::env::var("POKI_GITHUB_CLIENT_ID")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .or_else(|| (!SIGN_IN_APP_CLIENT_ID.is_empty()).then(|| SIGN_IN_APP_CLIENT_ID.to_string()))
        .ok_or_else(|| Error::msg("This build of Poki Setup has no GitHub sign-in set up."))
}

/// A GitHub device sign-in under way: the person opens `verification_uri` and enters `user_code`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignIn {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    #[serde(default = "five")]
    pub interval: u64,
    #[serde(default)]
    pub expires_in: u64,
}
fn five() -> u64 { 5 }

/// The device code of the sign-in under way; a cancel or a newer sign-in replaces it.
static SIGN_IN: Mutex<Option<String>> = Mutex::new(None);
const CANCELLED: &str = "The GitHub sign-in was cancelled.";

pub fn sign_in_cancel() {
    if let Ok(mut c) = SIGN_IN.lock() {
        *c = None;
    }
}

pub async fn sign_in_start() -> Result<SignIn> {
    let res = client()?
        .post("https://github.com/login/device/code")
        .header("Accept", "application/json")
        .form(&[("client_id", client_id()?.as_str()), ("scope", "")])
        .timeout(Duration::from_secs(30))
        .send()
        .await?
        .error_for_status()
        .map_err(|e| Error::msg(format!("GitHub did not start the sign-in ({e}). Try again.")))?;
    let pending: SignIn = res.json().await?;
    if let Ok(mut c) = SIGN_IN.lock() {
        *c = Some(pending.device_code.clone());
    }
    Ok(pending)
}

#[derive(Deserialize)]
struct TokenAnswer {
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// The token, keep waiting (with seconds to add to the interval), or why the sign-in ended.
fn poll_step(answer: &TokenAnswer) -> std::result::Result<Option<String>, std::result::Result<u64, &'static str>> {
    if let Some(t) = answer.access_token.as_deref().filter(|t| !t.is_empty()) {
        return Ok(Some(t.to_string()));
    }
    match answer.error.as_deref() {
        Some("authorization_pending") => Err(Ok(0)),
        Some("slow_down") => Err(Ok(5)),
        Some("access_denied") => Err(Err(CANCELLED)),
        Some("expired_token") => Err(Err("The GitHub code expired. Start the sign-in again.")),
        _ => Err(Err("GitHub did not finish the sign-in. Start it again.")),
    }
}

/// Waits until the person has entered the code on GitHub, then keeps the token.
pub async fn sign_in_finish(pending: &SignIn) -> Result<State> {
    let id = client_id()?;
    let mut interval = pending.interval.clamp(1, 60);
    let deadline = Instant::now() + Duration::from_secs(pending.expires_in.clamp(60, 900));
    let is_current = || SIGN_IN.lock().map(|c| c.as_deref() == Some(pending.device_code.as_str())).unwrap_or(false);
    let token = loop {
        tokio::time::sleep(Duration::from_secs(interval)).await;
        if !is_current() {
            return Err(Error::msg(CANCELLED));
        }
        if Instant::now() > deadline {
            return Err(Error::msg("The GitHub code expired. Start the sign-in again."));
        }
        let res = client()?
            .post("https://github.com/login/oauth/access_token")
            .header("Accept", "application/json")
            .form(&[("client_id", id.as_str()), ("device_code", pending.device_code.as_str()), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")])
            .timeout(Duration::from_secs(30))
            .send()
            .await;
        let Ok(res) = res else { continue };
        let Ok(answer) = res.json::<TokenAnswer>().await else { continue };
        match poll_step(&answer) {
            Ok(Some(t)) => break t,
            Ok(None) => continue,
            Err(Ok(more)) => interval += more,
            Err(Err(why)) => return Err(Error::msg(why)),
        }
    };
    let login = login_of(&token).await.ok();
    {
        let mut current = SIGN_IN.lock().map_err(|_| Error::msg(CANCELLED))?;
        if current.as_deref() != Some(pending.device_code.as_str()) {
            return Err(Error::msg(CANCELLED));
        }
        set_token(&token, "github", login)?;
        *current = None;
    }
    Ok(state())
}

// MARK: The list

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BuildState {
    /// The artifact is there to download.
    Ready,
    /// The run is still going (queued or building).
    Building,
    /// GitHub has deleted the artifact (kept 14 to 90 days).
    Expired,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PullRef {
    pub number: u64,
    pub title: String,
    pub url: String,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub draft: bool,
}

/// One test build (or a run still making one).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TestBuild {
    pub state: BuildState,
    pub run_id: u64,
    /// The workflow's own run number, "iOS IPA #19".
    pub run_number: u64,
    pub run_attempt: u64,
    pub workflow: String,
    pub branch: String,
    pub sha: String,
    /// The head commit's first line.
    pub title: String,
    /// Who started the run.
    pub actor: Option<String>,
    pub event: String,
    pub run_url: String,
    /// When the run started (RFC 3339).
    pub created_at: String,
    pub pr: Option<PullRef>,
    pub artifact_id: Option<u64>,
    pub artifact_name: Option<String>,
    pub size: u64,
    pub expires_at: Option<String>,
    /// The build is in this computer's cache.
    pub downloaded: bool,
}

impl TestBuild {
    pub fn short_sha(&self) -> &str { &self.sha[..self.sha.len().min(7)] }
}

/// What a device was installed with, kept in its record.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BuildRef {
    pub artifact_id: u64,
    pub run_id: u64,
    pub run_number: u64,
    pub workflow: String,
    pub branch: String,
    pub sha: String,
    #[serde(default)]
    pub pr: Option<u64>,
}

impl BuildRef {
    pub fn tag(&self) -> String { format!("actions:{}:{}", self.run_id, self.artifact_id) }
}

impl TestBuild {
    /// What the device record keeps; None while the run is still building.
    pub fn build_ref(&self) -> Option<BuildRef> {
        Some(BuildRef { artifact_id: self.artifact_id?, run_id: self.run_id, run_number: self.run_number, workflow: self.workflow.clone(), branch: self.branch.clone(), sha: self.sha.clone(), pr: self.pr.as_ref().map(|p| p.number) })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Listing {
    /// The builds the filters let through, newest first.
    pub builds: Vec<TestBuild>,
    /// How many there are without the filters.
    pub total: usize,
    /// Every branch with a build, for the branch filter.
    pub branches: Vec<String>,
    pub login: Option<String>,
    /// Unix seconds.
    pub checked_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
struct GhArtifacts {
    #[serde(default)]
    artifacts: Vec<GhArtifact>,
}

#[derive(Debug, Clone, Deserialize)]
struct GhArtifact {
    id: u64,
    name: String,
    #[serde(default)]
    size_in_bytes: u64,
    #[serde(default)]
    expired: bool,
    #[serde(default)]
    expires_at: Option<String>,
    workflow_run: Option<GhArtifactRun>,
}

#[derive(Debug, Clone, Deserialize)]
struct GhArtifactRun {
    id: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct GhRun {
    id: u64,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    path: String,
    #[serde(default)]
    run_number: u64,
    #[serde(default)]
    run_attempt: Option<u64>,
    #[serde(default)]
    event: String,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    conclusion: Option<String>,
    #[serde(default)]
    head_branch: Option<String>,
    #[serde(default)]
    head_sha: String,
    #[serde(default)]
    html_url: String,
    #[serde(default)]
    created_at: String,
    #[serde(default)]
    actor: Option<GhUser>,
    #[serde(default)]
    triggering_actor: Option<GhUser>,
    #[serde(default)]
    head_commit: Option<GhCommit>,
    #[serde(default)]
    pull_requests: Vec<GhRunPull>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct GhUser {
    login: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct GhCommit {
    #[serde(default)]
    message: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct GhRunPull {
    number: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct GhRuns {
    #[serde(default)]
    workflow_runs: Vec<GhRun>,
}

#[derive(Debug, Clone, Deserialize)]
struct GhPull {
    number: u64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    html_url: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    draft: bool,
    head: GhPullHead,
}

#[derive(Debug, Clone, Deserialize)]
struct GhPullHead {
    #[serde(rename = "ref")]
    branch: String,
}

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder().user_agent(format!("PokiSetup/{}", crate::VERSION)).timeout(Duration::from_secs(900)).build()?)
}

fn api(path: &str) -> Result<reqwest::RequestBuilder> {
    let url = format!("https://api.github.com/repos/{}{path}", release::repo());
    let req = client()?.get(url).header("Accept", "application/vnd.github+json").header("X-GitHub-Api-Version", "2022-11-28").timeout(Duration::from_secs(30));
    Ok(match token() {
        Some(t) => req.bearer_auth(t),
        None => req,
    })
}

async fn get_json<T: serde::de::DeserializeOwned>(path: &str) -> Result<T> {
    let res = api(path)?.send().await?;
    match res.status().as_u16() {
        401 => Err(Error::msg("GitHub did not accept the sign-in. Sign in to GitHub again.")),
        403 | 429 => Err(Error::msg("GitHub is limiting requests for a while. Try again in a few minutes.")),
        _ => Ok(res.error_for_status()?.json().await?),
    }
}

/// Runs whose details do not change any more (finished), by id.
static RUNS: Mutex<Option<HashMap<u64, GhRun>>> = Mutex::new(None);
/// The last listing, reused for 45 seconds unless a fresh one is asked for.
static LISTING: Mutex<Option<(Instant, Vec<TestBuild>)>> = Mutex::new(None);

fn cached_run(id: u64) -> Option<GhRun> { RUNS.lock().ok()?.as_ref()?.get(&id).cloned() }

fn keep_run(run: &GhRun) {
    if run.status.as_deref() != Some("completed") {
        return;
    }
    if let Ok(mut m) = RUNS.lock() {
        m.get_or_insert_with(HashMap::new).insert(run.id, run.clone());
    }
}

fn first_line(s: &str) -> String { s.lines().next().unwrap_or("").trim().to_string() }

fn build_of(run: &GhRun, artifact: Option<&GhArtifact>, pulls: &HashMap<String, PullRef>, by_number: &HashMap<u64, PullRef>) -> TestBuild {
    let branch = run.head_branch.clone().unwrap_or_default();
    let pr = run.pull_requests.first().and_then(|p| by_number.get(&p.number).cloned().or(Some(PullRef { number: p.number, title: String::new(), url: format!("https://github.com/{}/pull/{}", release::repo(), p.number), state: String::new(), draft: false })))
        .or_else(|| artifact.and_then(|a| preview_pr(&a.name)).and_then(|n| by_number.get(&n).cloned()))
        .or_else(|| pulls.get(&branch).cloned());
    let state = match artifact {
        Some(a) if a.expired => BuildState::Expired,
        Some(_) => BuildState::Ready,
        None => BuildState::Building,
    };
    let artifact_id = artifact.map(|a| a.id);
    TestBuild {
        state,
        run_id: run.id,
        run_number: run.run_number,
        run_attempt: run.run_attempt.unwrap_or(1),
        workflow: run.name.clone().unwrap_or_else(|| run.path.rsplit('/').next().unwrap_or("").to_string()),
        branch,
        sha: run.head_sha.clone(),
        title: run.head_commit.as_ref().map(|c| first_line(&c.message)).unwrap_or_default(),
        actor: run.triggering_actor.as_ref().or(run.actor.as_ref()).map(|u| u.login.clone()),
        event: run.event.clone(),
        run_url: run.html_url.clone(),
        created_at: run.created_at.clone(),
        pr,
        artifact_id,
        artifact_name: artifact.map(|a| a.name.clone()),
        size: artifact.map(|a| a.size_in_bytes).unwrap_or(0),
        expires_at: artifact.and_then(|a| a.expires_at.clone()),
        downloaded: artifact_id.map(is_downloaded).unwrap_or(false),
    }
}

/// `Poki-preview-pr242-0.3.2-766-d4ac3809b4e1` belongs to pull request 242.
fn preview_pr(name: &str) -> Option<u64> {
    let rest = name.strip_prefix("Poki-preview-pr")?;
    rest.split('-').next()?.parse().ok()
}

/// Everything GitHub has, newest first, before the filters.
async fn fetch_all() -> Result<Vec<TestBuild>> {
    use futures_util::StreamExt;
    let mut artifacts: Vec<GhArtifact> = Vec::new();
    for page in 1..=2 {
        let got: GhArtifacts = get_json(&format!("/actions/artifacts?per_page=100&page={page}")).await?;
        let n = got.artifacts.len();
        artifacts.extend(got.artifacts.into_iter().filter(|a| is_ipa_artifact(&a.name)));
        if n < 100 {
            break;
        }
    }
    // The newest artifact per run (a re-run leaves another).
    artifacts.sort_by(|a, b| b.id.cmp(&a.id));
    let mut per_run: Vec<(u64, GhArtifact)> = Vec::new();
    for a in artifacts {
        let Some(run) = a.workflow_run.as_ref().map(|r| r.id) else { continue };
        if !per_run.iter().any(|(r, _)| *r == run) {
            per_run.push((run, a));
        }
    }
    per_run.truncate(80);

    let missing: Vec<u64> = per_run.iter().map(|(r, _)| *r).filter(|r| cached_run(*r).is_none()).collect();
    let fetched: Vec<GhRun> = futures_util::stream::iter(missing)
        .map(|id| async move { get_json::<GhRun>(&format!("/actions/runs/{id}")).await.ok() })
        .buffer_unordered(8)
        .filter_map(|r| async move { r })
        .collect()
        .await;
    let mut fresh: HashMap<u64, GhRun> = HashMap::new();
    for r in fetched {
        keep_run(&r);
        fresh.insert(r.id, r);
    }

    // Runs still building in the workflows that make IPAs.
    let mut building: Vec<GhRun> = Vec::new();
    let mut workflows: Vec<String> = IPA_WORKFLOWS.iter().map(|s| s.to_string()).collect();
    for (run, _) in &per_run {
        if let Some(r) = fresh.get(run).cloned().or_else(|| cached_run(*run)) {
            if !r.path.is_empty() && !workflows.contains(&r.path) {
                workflows.push(r.path.clone());
            }
        }
    }
    for status in ["in_progress", "queued"] {
        if let Ok(got) = get_json::<GhRuns>(&format!("/actions/runs?status={status}&per_page=30")).await {
            building.extend(got.workflow_runs.into_iter().filter(|r| workflows.contains(&r.path)));
        }
    }

    // Pull requests, by head branch (open ones first) and by number.
    let pulls_list: Vec<GhPull> = get_json("/pulls?state=all&per_page=100&sort=updated&direction=desc").await.unwrap_or_default();
    let mut by_branch: HashMap<String, PullRef> = HashMap::new();
    let mut by_number: HashMap<u64, PullRef> = HashMap::new();
    for p in pulls_list.iter().filter(|p| p.state == "open").chain(pulls_list.iter().filter(|p| p.state != "open")) {
        let r = PullRef { number: p.number, title: p.title.clone(), url: p.html_url.clone(), state: p.state.clone(), draft: p.draft };
        by_branch.entry(p.head.branch.clone()).or_insert_with(|| r.clone());
        by_number.entry(p.number).or_insert(r);
    }

    let mut out: Vec<TestBuild> = Vec::new();
    for r in &building {
        if !per_run.iter().any(|(id, _)| *id == r.id) {
            out.push(build_of(r, None, &by_branch, &by_number));
        }
    }
    for (run_id, a) in &per_run {
        let Some(run) = fresh.get(run_id).cloned().or_else(|| cached_run(*run_id)) else { continue };
        out.push(build_of(&run, Some(a), &by_branch, &by_number));
    }
    out.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(b.run_id.cmp(&a.run_id)));
    Ok(out)
}

fn matches(b: &TestBuild, prefs: &Prefs, login: Option<&str>) -> bool {
    if prefs.only_mine {
        if let Some(me) = login {
            if !b.actor.as_deref().is_some_and(|a| a.eq_ignore_ascii_case(me)) {
                return false;
            }
        }
    }
    if let Some(branch) = prefs.branch.as_deref().filter(|s| !s.is_empty()) {
        if b.branch != branch {
            return false;
        }
    }
    if prefs.with_pr_only && b.pr.is_none() {
        return false;
    }
    true
}

/// The test builds the filters let through. Needs the GitHub sign-in (GitHub asks for one to
/// download artifacts, and it raises the request limit).
pub async fn list(fresh: bool) -> Result<Listing> {
    if token().is_none() {
        return Err(Error::msg("Sign in to GitHub to see test builds."));
    }
    let cached = LISTING.lock().ok().and_then(|c| c.as_ref().filter(|(at, _)| !fresh && at.elapsed() < Duration::from_secs(45)).map(|(_, l)| l.clone()));
    let mut all = match cached {
        Some(l) => l,
        None => {
            let l = fetch_all().await?;
            if let Ok(mut c) = LISTING.lock() {
                *c = Some((Instant::now(), l.clone()));
            }
            l
        }
    };
    for b in &mut all {
        b.downloaded = b.artifact_id.map(is_downloaded).unwrap_or(false);
    }
    let s = read_settings();
    let mut branches: Vec<String> = all.iter().map(|b| b.branch.clone()).filter(|b| !b.is_empty()).collect();
    branches.sort();
    branches.dedup();
    let total = all.len();
    let builds = all.into_iter().filter(|b| matches(b, &s.prefs, s.github_login.as_deref())).collect();
    Ok(Listing { builds, total, branches, login: s.github_login, checked_at: crate::keeper::now() })
}

/// The automatic sync's next build: the newest ready one the filters let through, when it is newer
/// than the last one handled. None when the sync is off.
pub async fn next_to_sync() -> Result<Option<TestBuild>> {
    let s = read_settings();
    if !(s.prefs.auto_download || s.prefs.auto_install) || token().is_none() {
        return Ok(None);
    }
    let l = list(false).await?;
    let newest = l.builds.into_iter().filter(|b| b.state == BuildState::Ready).max_by_key(|b| b.run_id);
    Ok(newest.filter(|b| Some(b.run_id) > s.synced_run))
}

/// The sync has handled this run (downloaded or installed it, or given up on it).
pub fn mark_synced(run_id: u64) -> Result<State> {
    let mut s = read_settings();
    s.synced_run = Some(run_id).max(s.synced_run);
    write_settings(&s)?;
    Ok(state())
}

// MARK: Downloads

fn downloads_dir() -> Result<PathBuf> { Ok(paths::ensure(paths::cache_dir()?.join("test-builds"))?) }

fn build_dir(artifact_id: u64) -> Result<PathBuf> { Ok(downloads_dir()?.join(artifact_id.to_string())) }

fn is_downloaded(artifact_id: u64) -> bool { build_dir(artifact_id).map(|d| d.join(".complete").is_file()).unwrap_or(false) }

fn dir_size(dir: &Path) -> u64 { walkdir::WalkDir::new(dir).into_iter().filter_map(|e| e.ok()).filter_map(|e| e.metadata().ok()).filter(|m| m.is_file()).map(|m| m.len()).sum() }

/// The cached IPA and signing zip of a downloaded build.
pub fn cached(artifact_id: u64) -> Option<(PathBuf, Option<PathBuf>)> {
    let dir = build_dir(artifact_id).ok()?;
    if !dir.join(".complete").is_file() {
        return None;
    }
    let ipa = find_ipa(&dir)?;
    let signing = dir.join("Poki-signing.zip");
    Some((ipa, signing.is_file().then_some(signing)))
}

fn find_ipa(dir: &Path) -> Option<PathBuf> {
    let mut ipas: Vec<PathBuf> = std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "ipa")).collect();
    ipas.sort_by_key(|p| !p.file_name().is_some_and(|n| n.to_string_lossy().contains("external")));
    ipas.into_iter().next()
}

/// Downloads a build into the cache (once) and checks the IPA against the artifact's SHA256SUMS.
/// Progress goes to `step`.
pub async fn fetch(artifact_id: u64, reporter: &Reporter, step: &str) -> Result<(PathBuf, Option<PathBuf>)> {
    if let Some(found) = cached(artifact_id) {
        reporter.part(step, 1.0, Some("Already downloaded".into()));
        return Ok(found);
    }
    use futures_util::StreamExt;
    let token = token().ok_or_else(|| Error::msg("Downloading a test build needs the GitHub sign-in. Sign in under Developer, then try again."))?;
    let dir = build_dir(artifact_id)?;
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)?;
    let zip_path = dir.join("artifact.zip.part");
    let url = format!("https://api.github.com/repos/{}/actions/artifacts/{artifact_id}/zip", release::repo());
    // GitHub answers with a redirect to storage; reqwest drops the token when it follows it.
    let res = client()?.get(url).bearer_auth(token).header("Accept", "application/vnd.github+json").send().await?;
    let res = match res.status().as_u16() {
        401 | 403 => return Err(Error::msg("GitHub did not accept the sign-in for this build. Sign in to GitHub again.")),
        404 | 410 => return Err(Error::msg("This build is gone from GitHub. Artifacts are kept for a limited time.")),
        _ => res.error_for_status()?,
    };
    let total = res.content_length();
    let mut file = tokio::fs::File::create(&zip_path).await?;
    let mut stream = res.bytes_stream();
    let mut got: u64 = 0;
    let mut last = Instant::now() - Duration::from_secs(1);
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        tokio::io::AsyncWriteExt::write_all(&mut file, &chunk).await?;
        got += chunk.len() as u64;
        if last.elapsed() >= Duration::from_millis(150) {
            last = Instant::now();
            match total {
                Some(t) if t > 0 => reporter.part(step, got as f64 / t as f64 * 0.95, Some(format!("{:.1} of {:.1} MB", got as f64 / 1e6, t as f64 / 1e6))),
                _ => reporter.part(step, 0.5, Some(format!("{:.1} MB", got as f64 / 1e6))),
            }
        }
    }
    tokio::io::AsyncWriteExt::flush(&mut file).await?;
    drop(file);
    reporter.part(step, 0.97, Some("Unpacking".into()));
    let (z, d) = (zip_path.clone(), dir.clone());
    tokio::task::spawn_blocking(move || unpack(&z, &d)).await.map_err(|e| Error::msg(e.to_string()))??;
    let _ = std::fs::remove_file(&zip_path);
    let ipa = find_ipa(&dir).ok_or_else(|| {
        let _ = std::fs::remove_dir_all(&dir);
        Error::msg("This build has no Poki IPA in it.")
    })?;
    if let Ok(sums) = std::fs::read_to_string(dir.join("SHA256SUMS")) {
        let name = ipa.file_name().unwrap_or_default().to_string_lossy().to_string();
        if let Some(expected) = sum_for(&sums, &name) {
            if release::sha256_file(&ipa)? != expected {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(Error::msg("The build's IPA does not match its SHA256SUMS. Try again."));
            }
        }
    }
    std::fs::write(dir.join(".complete"), b"")?;
    reporter.part(step, 1.0, Some("Downloaded".into()));
    let signing = dir.join("Poki-signing.zip");
    Ok((ipa, signing.is_file().then_some(signing)))
}

fn sum_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut parts = l.split_whitespace();
        let sum = parts.next()?;
        let file = parts.next()?.trim_start_matches('*');
        (file == name || file.ends_with(&format!("/{name}"))).then(|| sum.to_lowercase())
    })
}

/// Takes the IPAs, the signing zip and SHA256SUMS out of the artifact, by file name only.
fn unpack(zip_path: &Path, dir: &Path) -> Result<()> {
    let mut archive = zip::ZipArchive::new(std::fs::File::open(zip_path)?).map_err(|e| Error::msg(format!("The build did not unpack ({e}).")))?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| Error::msg(format!("The build did not unpack ({e}).")))?;
        if entry.is_dir() {
            continue;
        }
        let Some(name) = Path::new(entry.name()).file_name().map(|n| n.to_string_lossy().to_string()) else { continue };
        if !(name.ends_with(".ipa") || name == "Poki-signing.zip" || name == "SHA256SUMS") {
            continue;
        }
        let mut out = std::fs::File::create(dir.join(&name))?;
        std::io::copy(&mut entry, &mut out)?;
    }
    Ok(())
}

/// Deletes every downloaded test build.
pub fn delete_downloads() -> Result<State> {
    let dir = downloads_dir()?;
    let _ = std::fs::remove_dir_all(&dir);
    Ok(state())
}

/// For a renewal: the device's test build, downloaded again if the cache lost it, when renewals
/// keep test builds. None means sign the release instead.
pub async fn for_renewal(r: &BuildRef, reporter: &Reporter) -> Option<(PathBuf, Option<PathBuf>)> {
    if !read_settings().prefs.keep_on_renew {
        return None;
    }
    if let Some(found) = cached(r.artifact_id) {
        return Some(found);
    }
    match fetch(r.artifact_id, reporter, "release").await {
        Ok(found) => Some(found),
        Err(e) => {
            reporter.note("release", format!("The test build is not available any more ({e}). Renewing with the release instead."));
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(id: u64, actor: &str, branch: &str) -> GhRun {
        GhRun {
            id,
            name: Some("iOS IPA".into()),
            path: ".github/workflows/ios-ipa.yml".into(),
            run_number: id,
            run_attempt: Some(1),
            event: "workflow_dispatch".into(),
            status: Some("completed".into()),
            conclusion: Some("success".into()),
            head_branch: Some(branch.into()),
            head_sha: "aa47ce4144abe0142b157888a938177971a8d610".into(),
            html_url: String::new(),
            created_at: format!("2026-11-14T18:{id:02}:00Z"),
            actor: Some(GhUser { login: actor.into() }),
            triggering_actor: None,
            head_commit: Some(GhCommit { message: "Fix the thing\n\nMore words".into() }),
            pull_requests: vec![],
        }
    }

    fn art(id: u64, name: &str) -> GhArtifact { GhArtifact { id, name: name.into(), size_in_bytes: 48_000_000, expired: false, expires_at: None, workflow_run: None } }

    #[test]
    fn names_and_lines() {
        assert!(is_ipa_artifact("Poki-unsigned"));
        assert!(is_ipa_artifact("Poki-preview-pr242-0.3.2-766-d4ac3809b4e1"));
        assert!(!is_ipa_artifact("gym-shots"));
        assert_eq!(preview_pr("Poki-preview-pr242-0.3.2-766-d4ac3809b4e1"), Some(242));
        assert_eq!(first_line("Fix the thing\n\nMore"), "Fix the thing");
        assert_eq!(sum_for("abc  Poki-external-unsigned.ipa\ndef  Poki-signing.zip\n", "Poki-external-unsigned.ipa").as_deref(), Some("abc"));
    }

    #[test]
    fn builds_find_their_pull_request_by_branch() {
        let mut pulls = HashMap::new();
        pulls.insert("dev/x".to_string(), PullRef { number: 360, title: "X".into(), url: String::new(), state: "open".into(), draft: true });
        let b = build_of(&run(5, "ZhehanZhang", "dev/x"), Some(&art(9, "Poki-unsigned")), &pulls, &HashMap::new());
        assert_eq!(b.pr.as_ref().map(|p| p.number), Some(360));
        assert_eq!(b.state, BuildState::Ready);
        assert_eq!(b.title, "Fix the thing");
        assert_eq!(b.short_sha(), "aa47ce4");
        assert_eq!(b.build_ref().unwrap().tag(), "actions:5:9");
        let building = build_of(&run(6, "ZhehanZhang", "dev/y"), None, &pulls, &HashMap::new());
        assert_eq!(building.state, BuildState::Building);
        assert!(building.pr.is_none());
    }

    #[test]
    fn filters() {
        let (none, nums) = (HashMap::new(), HashMap::new());
        let mine = build_of(&run(1, "ZhehanZhang", "dev/a"), Some(&art(1, "Poki-unsigned")), &none, &nums);
        let theirs = build_of(&run(2, "JosssphZhou", "dev/b"), Some(&art(2, "Poki-unsigned")), &none, &nums);
        let p = Prefs::default();
        assert!(matches(&mine, &p, Some("zhehanzhang")));
        assert!(!matches(&theirs, &p, Some("ZhehanZhang")));
        let all = Prefs { only_mine: false, ..Prefs::default() };
        assert!(matches(&theirs, &all, Some("ZhehanZhang")));
        let branch = Prefs { only_mine: false, branch: Some("dev/a".into()), ..Prefs::default() };
        assert!(matches(&mine, &branch, None) && !matches(&theirs, &branch, None));
        let prs = Prefs { only_mine: false, with_pr_only: true, ..Prefs::default() };
        assert!(!matches(&mine, &prs, None));
    }

    #[test]
    fn settings_read_old_and_partial_files() {
        let s: Settings = serde_json::from_str("{}").unwrap();
        assert!(s.prefs.only_mine && s.prefs.keep_on_renew && !s.prefs.auto_install);
        let s: Settings = serde_json::from_str(r#"{"github_login":"me","auto_install":true}"#).unwrap();
        assert!(s.prefs.auto_install);
        assert_eq!(s.github_login.as_deref(), Some("me"));
    }

    #[test]
    fn device_sign_in_answers() {
        let a = |t: Option<&str>, e: Option<&str>| TokenAnswer { access_token: t.map(Into::into), error: e.map(Into::into) };
        assert_eq!(poll_step(&a(Some("tok"), None)), Ok(Some("tok".into())));
        assert_eq!(poll_step(&a(None, Some("authorization_pending"))), Err(Ok(0)));
        assert_eq!(poll_step(&a(None, Some("slow_down"))), Err(Ok(5)));
        assert!(matches!(poll_step(&a(None, Some("access_denied"))), Err(Err(_))));
    }
}
