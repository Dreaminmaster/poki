//! Poki's releases on GitHub: `ios-v*` (Stable, Beta) and `ios-alpha-*` (Alpha), `ios-prealpha-*` (Pre-alpha) tags with `Poki-external-<v>-<b>.ipa`, `Poki-<v>-<b>.ipa`,
//! `Poki-signing.zip` and `SHA256SUMS`. Poki Setup installs the external edition: its loopback
//! comes from the person's proxy app, which a team profile can sign; the built-in tunnel cannot.
use crate::{Error, Result, Reporter, paths};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

pub const DEFAULT_REPO: &str = "JosssphZhou/poki";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Release {
    pub tag: String,
    pub version: String,
    pub build: String,
    pub published_at: String,
    pub prerelease: bool,
    #[serde(default)]
    pub channel: Channel,
    pub ipa_url: String,
    pub ipa_name: String,
    pub signing_url: Option<String>,
    pub sums_url: Option<String>,
    pub notes: String,
    /// Set on a preview build of a pull request (a GitHub Actions artifact), which is on no channel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<PreviewInfo>,
}

/// The pull request a preview build was made from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewInfo {
    pub pr: u64,
    /// The pull request's head commit that was built.
    #[serde(default)]
    pub sha: String,
    /// The pull request's title.
    #[serde(default)]
    pub title: String,
    /// The GitHub Actions artifact that holds the build.
    #[serde(default)]
    pub artifact_id: u64,
}

#[derive(Deserialize, Clone)]
struct GhRelease {
    tag_name: String,
    prerelease: bool,
    draft: bool,
    published_at: Option<String>,
    body: Option<String>,
    #[serde(default)]
    html_url: Option<String>,
    assets: Vec<GhAsset>,
}
#[derive(Deserialize, Clone)]
struct GhAsset {
    name: String,
    browser_download_url: String,
}

pub fn repo() -> String { std::env::var("POKI_RELEASE_REPO").unwrap_or_else(|_| DEFAULT_REPO.into()) }

/// Which releases Poki Setup installs, renews with and offers as its own updates. Each channel
/// includes the ones above it: Beta takes the newest Stable or Beta, Alpha adds alpha builds, Pre-alpha the newest of all.
/// See docs/release-channels.md upstream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Channel {
    /// `ios-vX.Y.Z` / `desktop-vX.Y.Z` full releases. The default.
    Stable,
    /// The same tags published as prereleases.
    Beta,
    /// `ios-alpha-X.Y.Z-N` / `desktop-alpha-*` early test builds, picked by hand.
    Alpha,
    /// `ios-prealpha-X.Y.Z-N` / `desktop-prealpha-*` snapshots.
    PreAlpha,
}

impl Default for Channel {
    fn default() -> Self { Channel::Stable }
}

impl Channel {
    pub const ALL: [Channel; 4] = [Channel::Stable, Channel::Beta, Channel::Alpha, Channel::PreAlpha];

    pub fn id(self) -> &'static str {
        match self {
            Channel::Stable => "stable",
            Channel::Beta => "beta",
            Channel::Alpha => "alpha",
            Channel::PreAlpha => "pre-alpha",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Channel::Stable => "Stable",
            Channel::Beta => "Beta",
            Channel::Alpha => "Alpha",
            Channel::PreAlpha => "Pre-alpha",
        }
    }

    pub fn parse(s: &str) -> Option<Channel> {
        match s.trim().to_ascii_lowercase().replace(['_', ' '], "-").as_str() {
            "stable" => Some(Channel::Stable),
            "beta" => Some(Channel::Beta),
            "alpha" => Some(Channel::Alpha),
            "pre-alpha" | "prealpha" => Some(Channel::PreAlpha),
            _ => None,
        }
    }

    /// This channel, then each less stable one in turn: where to look when this one has nothing yet.
    pub fn fallbacks(self) -> impl Iterator<Item = Channel> {
        // Pre-alpha is for signed-in GitHub accounts: nobody else reaches it, not even by a
        // channel with no release yet stepping down.
        let pre_alpha = self == Channel::PreAlpha || github_token().is_some();
        Channel::ALL.into_iter().filter(move |c| *c >= self && (*c != Channel::PreAlpha || pre_alpha))
    }

    /// Whether a release of channel `of` is offered to someone on this channel.
    pub fn includes(self, of: Channel) -> bool { of <= self }

    /// The channel a release belongs to, for a product prefix (`ios` or `desktop`), or None when the
    /// tag is not one of that product's.
    pub fn of_tag(product: &str, tag: &str, prerelease: bool) -> Option<Channel> {
        let rest = tag.strip_prefix(product)?.strip_prefix('-')?;
        if rest.starts_with("prealpha-") {
            Some(Channel::PreAlpha)
        } else if rest.starts_with("alpha-") {
            Some(Channel::Alpha)
        } else if rest.starts_with("beta-") {
            Some(Channel::Beta)
        } else if rest.starts_with('v') {
            Some(if prerelease { Channel::Beta } else { Channel::Stable })
        } else {
            None
        }
    }
}

impl Channel {
    /// The channel of an `app-*` release (Poki's tags from Nov 2026 on): `app-0.2.9-prealpha.640`
    /// and `app-prealpha-latest`, `app-0.2.9-alpha.640` and `app-alpha-latest`, `app-0.3.0-beta.1`,
    /// and `app-0.3.0` (Stable, or Beta while it is marked prerelease). None for any other tag.
    pub fn of_app_tag(tag: &str, prerelease: bool) -> Option<Channel> {
        let rest = tag.strip_prefix("app-")?;
        match rest {
            "prealpha-latest" => return Some(Channel::PreAlpha),
            "alpha-latest" => return Some(Channel::Alpha),
            _ => {}
        }
        if !rest.starts_with(|c: char| c.is_ascii_digit()) {
            return None;
        }
        Some(match rest.split_once('-').map(|(_, s)| s) {
            None => if prerelease { Channel::Beta } else { Channel::Stable },
            Some(s) if s.starts_with("prealpha.") => Channel::PreAlpha,
            Some(s) if s.starts_with("alpha.") => Channel::Alpha,
            // beta.N, and rc.N or any other pre-release suffix.
            Some(_) => Channel::Beta,
        })
    }

    /// The channel of a release of Poki itself, under either scheme (`ios-*` or `app-*`).
    pub fn of_app_release(tag: &str, prerelease: bool) -> Option<Channel> {
        Channel::of_tag("ios", tag, prerelease).or_else(|| Channel::of_app_tag(tag, prerelease))
    }
}

impl std::str::FromStr for Channel {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self> { Channel::parse(s).ok_or_else(|| Error::msg(format!("Unknown channel “{s}”. Use stable, beta, alpha or pre-alpha."))) }
}

#[derive(Serialize, Deserialize, Default)]
struct ChannelFile {
    channel: Channel,
    /// The Preview Builds switch on the GitHub Account page.
    #[serde(default)]
    previews: bool,
    /// The pull request whose preview build is installed instead of the channel's release.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    preview: Option<u64>,
    /// The GitHub account signed in for preview builds (its token is kept with the secrets).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    github_login: Option<String>,
}

fn channel_file() -> Result<PathBuf> { Ok(paths::state_dir()?.join("channel.json")) }

fn read_choice() -> ChannelFile {
    channel_file().ok().and_then(|p| std::fs::read(p).ok()).and_then(|b| serde_json::from_slice::<ChannelFile>(&b).ok()).unwrap_or_default()
}

fn write_choice(choice: &ChannelFile) -> Result<()> {
    let p = channel_file()?;
    let tmp = p.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(choice)?)?;
    std::fs::rename(tmp, p)?;
    Ok(())
}

/// The chosen channel: `POKI_RELEASE_CHANNEL` when set, else the saved choice, else Stable.
/// Pre-alpha is for people signed in to GitHub: without the sign-in a saved Pre-alpha choice
/// acts as Alpha, and is Pre-alpha again once GitHub is signed in.
pub fn channel() -> Channel {
    if let Some(c) = std::env::var("POKI_RELEASE_CHANNEL").ok().and_then(|v| Channel::parse(&v)) {
        return c;
    }
    match read_choice().channel {
        Channel::PreAlpha if github_token().is_none() => Channel::Alpha,
        c => c,
    }
}

/// The channels the pickers offer: Pre-alpha only while GitHub is signed in.
pub fn offered_channels() -> Vec<Channel> {
    let signed_in = github_token().is_some();
    Channel::ALL.into_iter().filter(|c| *c != Channel::PreAlpha || signed_in).collect()
}

pub fn set_channel(channel: Channel) -> Result<()> {
    if channel == Channel::PreAlpha && github_token().is_none() {
        return Err(Error::msg("The Pre-alpha channel is for signed-in GitHub accounts. Sign in to GitHub first."));
    }
    write_choice(&ChannelFile { channel, ..read_choice() })
}

/// Whether preview builds are offered: the Preview Builds switch on the GitHub Account page is
/// on. It can only be turned on while GitHub is signed in (preview builds cannot be downloaded
/// without a sign-in), and signing out turns it off.
pub fn previews_enabled() -> bool { read_choice().previews && github_token().is_some() }

/// Turns the Preview Builds switch on or off. Off also drops the chosen preview, so installs and
/// updates follow the channel again.
pub fn set_preview_switch(on: bool) -> Result<()> {
    if on && github_token().is_none() {
        return Err(Error::msg("Sign in to GitHub first. Preview builds are for signed-in GitHub accounts."));
    }
    let old = read_choice();
    write_choice(&ChannelFile { previews: on, preview: if on { old.preview } else { None }, ..old })
}

/// The pull request whose preview build is chosen, when the switch is on and one is chosen.
pub fn preview() -> Option<u64> {
    if previews_enabled() { read_choice().preview } else { None }
}

/// Chooses a pull request's preview build, or None to follow the channel again.
pub fn set_preview(pr: Option<u64>) -> Result<()> {
    let old = read_choice();
    if pr.is_some() && !previews_enabled() {
        return Err(Error::msg("Preview builds are off. Sign in to GitHub and turn them on first."));
    }
    write_choice(&ChannelFile { preview: pr, ..old })
}

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder().user_agent(format!("PokiSetup/{}", crate::VERSION)).timeout(std::time::Duration::from_secs(600)).build()?)
}

async fn list() -> Result<Vec<GhRelease>> {
    let mut list: Vec<GhRelease> = client()?
        .get(format!("https://api.github.com/repos/{}/releases?per_page=100", repo()))
        .header("Accept", "application/vnd.github+json")
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await?
        .error_for_status()
        .map_err(|e| Error::msg(format!("Could not read Poki's releases from GitHub ({e}). Check the connection and try again.")))?
        .json()
        .await?;
    list.retain(|r| !r.draft);
    // Newest first by publication, whatever order GitHub lists them in.
    list.sort_by(|a, b| b.published_at.cmp(&a.published_at));
    Ok(list)
}

/// An installable Poki release (one with the external IPA) from GitHub's answer.
fn installable(r: &GhRelease) -> Option<(Channel, Release)> {
    let channel = Channel::of_app_release(&r.tag_name, r.prerelease)?;
    let ipa = r.assets.iter().find(|a| a.name.starts_with("Poki-external-") && a.name.ends_with(".ipa"))?;
    // Poki-external-<version>-<build>.ipa; the tag names the version too for ios-v* releases.
    let stem = ipa.name.trim_start_matches("Poki-external-").trim_end_matches(".ipa");
    let (version, build) = match stem.rsplit_once('-') {
        Some((v, b)) if !v.is_empty() => (v.to_string(), b.to_string()),
        _ => (r.tag_name.trim_start_matches("app-").trim_start_matches("ios-v").trim_start_matches("ios-prealpha-").trim_start_matches("ios-alpha-").trim_start_matches("ios-beta-").to_string(), String::new()),
    };
    Some((
        channel,
        Release {
            tag: r.tag_name.clone(),
            version,
            build,
            published_at: r.published_at.clone().unwrap_or_default(),
            prerelease: r.prerelease,
            channel,
            ipa_url: ipa.browser_download_url.clone(),
            ipa_name: ipa.name.clone(),
            signing_url: r.assets.iter().find(|a| a.name == "Poki-signing.zip").map(|a| a.browser_download_url.clone()),
            sums_url: r.assets.iter().find(|a| a.name == "SHA256SUMS").map(|a| a.browser_download_url.clone()),
            notes: r.body.clone().unwrap_or_default(),
            preview: None,
        },
    ))
}

/// A pull request's preview build is a GitHub Actions artifact of the `PR preview` workflow, named
/// `Poki-preview-pr<N>-<version>-<build>-<commit>`. It is never a release, so no channel (and no
/// Poki Setup or Poki from before previews existed) offers it. GitHub lists artifacts to anyone
/// but hands the files only to a signed-in account, so downloading one needs a GitHub token.
pub const PREVIEW_ARTIFACT_PREFIX: &str = "Poki-preview-pr";

#[derive(Deserialize)]
struct GhArtifacts {
    artifacts: Vec<GhArtifact>,
}
#[derive(Deserialize)]
struct GhArtifact {
    id: u64,
    name: String,
    #[serde(default)]
    expired: bool,
    #[serde(default)]
    created_at: Option<String>,
    archive_download_url: String,
    #[serde(default)]
    workflow_run: Option<GhRun>,
}
#[derive(Deserialize)]
struct GhRun {
    #[serde(default)]
    repository_id: Option<u64>,
    #[serde(default)]
    head_repository_id: Option<u64>,
    /// The branch the run built: for a pull request's run, the pull request's own branch.
    #[serde(default)]
    head_branch: Option<String>,
}
#[derive(Deserialize)]
struct GhPull {
    number: u64,
    #[serde(default)]
    title: String,
    head: GhPullHead,
}
#[derive(Deserialize)]
struct GhPullHead {
    #[serde(rename = "ref")]
    branch: String,
}

/// The pull request, version, build and commit in a preview artifact's name.
fn preview_name(name: &str) -> Option<(u64, String, String, String)> {
    let mut parts = name.strip_prefix(PREVIEW_ARTIFACT_PREFIX)?.split('-');
    let (pr, version, build, sha) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let ok = digits(pr) && digits(build) && version.split('.').count() == 3 && version.split('.').all(digits) && sha.len() >= 7 && sha.bytes().all(|b| b.is_ascii_hexdigit());
    ok.then(|| Some((pr.parse().ok()?, version.to_string(), build.to_string(), sha.to_string()))).flatten()
}

/// An installable preview build from one artifact. Only a run from a branch of the repository
/// itself counts: a fork's pull request can upload an artifact with any name, but its run's head
/// repository is the fork, and the people who can push a branch here are the ones who can merge.
fn preview_release(a: &GhArtifact) -> Option<Release> {
    let (pr, version, build, sha) = preview_name(&a.name)?;
    let run = a.workflow_run.as_ref()?;
    if a.expired || run.repository_id.is_none() || run.repository_id != run.head_repository_id {
        return None;
    }
    Some(Release {
        tag: format!("preview-pr-{pr}"),
        ipa_name: format!("Poki-external-{version}-{build}.ipa"),
        version,
        build,
        published_at: a.created_at.clone().unwrap_or_default(),
        prerelease: true,
        channel: Channel::PreAlpha,
        ipa_url: a.archive_download_url.clone(),
        signing_url: None,
        sums_url: None,
        notes: String::new(),
        preview: Some(PreviewInfo { pr, sha, title: String::new(), artifact_id: a.id }),
    })
}

/// The newest preview build of each open pull request, newest pull request first. The pull
/// request number in an artifact's name is believed only when the run that made the artifact built
/// that pull request's own branch, so a build cannot pass as another pull request's preview. A
/// closed pull request's artifact, which may outlive it for a moment, is not offered.
fn preview_list(artifacts: &[GhArtifact], open: &[GhPull]) -> Vec<Release> {
    let mut newest: std::collections::BTreeMap<u64, Release> = Default::default();
    for a in artifacts {
        let Some(r) = preview_release(a) else { continue };
        let Some(p) = r.preview.clone() else { continue };
        let Some(pull) = open.iter().find(|q| q.number == p.pr) else { continue };
        if a.workflow_run.as_ref().and_then(|w| w.head_branch.as_deref()) != Some(pull.head.branch.as_str()) {
            continue;
        }
        let r = Release { preview: Some(PreviewInfo { title: pull.title.clone(), ..p.clone() }), ..r };
        let newer = newest.get(&p.pr).and_then(|o| o.preview.as_ref()).map(|o| p.artifact_id > o.artifact_id).unwrap_or(true);
        if newer {
            newest.insert(p.pr, r);
        }
    }
    newest.into_values().rev().collect()
}

const GITHUB_TOKEN: &str = "github-token";

/// The GitHub token preview builds are downloaded with, if one is saved.
pub fn github_token() -> Option<String> { crate::apple::store::secret_get(GITHUB_TOKEN) }

/// The GitHub account signed in for preview builds, when there is one.
pub fn github_login() -> Option<String> { github_token().and(read_choice().github_login) }

/// Saves the token (in the Keychain or the system's credential store), or forgets it when empty:
/// signing out of GitHub. The sign-in below saves it by itself; this is for a token made by hand.
pub fn set_github_token(token: &str) -> Result<()> {
    let token = token.trim();
    let old = read_choice();
    if token.is_empty() {
        // Signed out: preview builds go off with it, and the channel takes over again.
        write_choice(&ChannelFile { github_login: None, previews: false, preview: None, ..old })?;
        return crate::apple::store::secret_delete(GITHUB_TOKEN);
    }
    write_choice(&ChannelFile { github_login: None, ..old })?;
    if token.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(Error::msg("That does not look like a GitHub token."));
    }
    crate::apple::store::secret_set(GITHUB_TOKEN, token)
}

/// The OAuth App that GitHub's device sign-in runs under ("Enable Device Flow" on, no client
/// secret involved; the ID is public). `POKI_GITHUB_CLIENT_ID` overrides it.
pub const GITHUB_CLIENT_ID: &str = "";

fn github_client_id() -> Result<String> {
    std::env::var("POKI_GITHUB_CLIENT_ID").ok().filter(|v| !v.trim().is_empty()).or_else(|| (!GITHUB_CLIENT_ID.is_empty()).then(|| GITHUB_CLIENT_ID.to_string()))
        .ok_or_else(|| Error::msg("This build of Poki has no GitHub sign-in set up."))
}

/// A GitHub device sign-in under way: the person opens `verification_uri` and enters `user_code`,
/// while [`github_sign_in_finish`] waits for GitHub to say they did.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GithubSignIn {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    #[serde(default = "five")]
    pub interval: u64,
    #[serde(default)]
    pub expires_in: u64,
}
fn five() -> u64 { 5 }

/// Starts GitHub's device sign-in. No scope is asked for, so the sign-in can read public data
/// only, which is all a preview build's download needs.
pub async fn github_sign_in_start() -> Result<GithubSignIn> {
    let res = client()?
        .post("https://github.com/login/device/code")
        .header("Accept", "application/json")
        .form(&[("client_id", github_client_id()?.as_str()), ("scope", "")])
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await?
        .error_for_status()
        .map_err(|e| Error::msg(format!("GitHub did not start the sign-in ({e}). Try again.")))?;
    Ok(res.json().await?)
}

#[derive(Deserialize)]
struct GithubTokenAnswer {
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// What one answer to the token request means: the token, keep waiting (with the seconds to add
/// to the interval), or the reason the sign-in ended.
fn github_poll_step(answer: &GithubTokenAnswer) -> std::result::Result<Option<String>, std::result::Result<u64, &'static str>> {
    if let Some(t) = answer.access_token.as_deref().filter(|t| !t.is_empty()) {
        return Ok(Some(t.to_string()));
    }
    match answer.error.as_deref() {
        Some("authorization_pending") => Err(Ok(0)),
        Some("slow_down") => Err(Ok(5)),
        Some("access_denied") => Err(Err("The GitHub sign-in was cancelled.")),
        Some("expired_token") => Err(Err("The GitHub code expired. Start the sign-in again.")),
        _ => Err(Err("GitHub did not finish the sign-in. Start it again.")),
    }
}

/// Waits until the person has entered the code on GitHub, then keeps the token with the secrets
/// and remembers the account's name. Returns that name.
pub async fn github_sign_in_finish(pending: &GithubSignIn) -> Result<String> {
    let id = github_client_id()?;
    let mut interval = pending.interval.clamp(1, 60);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(pending.expires_in.clamp(60, 900));
    let token = loop {
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        if std::time::Instant::now() > deadline {
            return Err(Error::msg("The GitHub code expired. Start the sign-in again."));
        }
        let res = client()?
            .post("https://github.com/login/oauth/access_token")
            .header("Accept", "application/json")
            .form(&[("client_id", id.as_str()), ("device_code", pending.device_code.as_str()), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")])
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await;
        // A request that did not get through is tried again at the next turn.
        let Ok(res) = res else { continue };
        let Ok(answer) = res.json::<GithubTokenAnswer>().await else { continue };
        match github_poll_step(&answer) {
            Ok(Some(t)) => break t,
            Ok(None) => continue,
            Err(Ok(more)) => interval += more,
            Err(Err(why)) => return Err(Error::msg(why)),
        }
    };
    set_github_token(&token)?;
    #[derive(Deserialize)]
    struct User {
        login: String,
    }
    let login = match github("https://api.github.com/user".into())?.timeout(std::time::Duration::from_secs(30)).send().await {
        Ok(res) => res.json::<User>().await.map(|u| u.login).unwrap_or_default(),
        Err(_) => String::new(),
    };
    write_choice(&ChannelFile { github_login: (!login.is_empty()).then(|| login.clone()), ..read_choice() })?;
    Ok(login)
}

fn github(url: String) -> Result<reqwest::RequestBuilder> {
    let req = client()?.get(url).header("Accept", "application/vnd.github+json").header("X-GitHub-Api-Version", "2022-11-28");
    Ok(match github_token() {
        Some(t) => req.bearer_auth(t),
        None => req,
    })
}

/// Every preview build on offer (a few GitHub requests; the token is used when there is one, for
/// its higher request limit, but listing works without).
async fn list_previews() -> Result<Vec<Release>> {
    let mut artifacts = vec![];
    for page in 1..=3 {
        let got: GhArtifacts = github(format!("https://api.github.com/repos/{}/actions/artifacts?per_page=100&page={page}", repo()))?
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await?
            .error_for_status()
            .map_err(|e| Error::msg(format!("Could not read the preview builds from GitHub ({e}). Check the connection and the GitHub token, then try again.")))?
            .json()
            .await?;
        let last = got.artifacts.len() < 100;
        artifacts.extend(got.artifacts);
        if last {
            break;
        }
    }
    // Without the open pull requests no artifact can be matched to one, so none is offered.
    let mut pulls: Vec<GhPull> = vec![];
    for page in 1..=5 {
        let got: Vec<GhPull> = github(format!("https://api.github.com/repos/{}/pulls?state=open&per_page=100&page={page}", repo()))?
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await?
            .error_for_status()
            .map_err(|e| Error::msg(format!("Could not read the open pull requests from GitHub ({e}). Check the connection, then try again.")))?
            .json()
            .await?;
        let last = got.len() < 100;
        pulls.extend(got);
        if last {
            break;
        }
    }
    Ok(preview_list(&artifacts, &pulls))
}

/// What installs and updates use: the chosen pull request's preview build while it exists, else
/// the channel's newest release. The bool says the chosen preview is gone (its pull request was
/// merged or closed, the label came off, or the build expired).
fn choose(list: &[GhRelease], channel: Channel, previews: &[Release], preview: Option<u64>) -> (Option<Release>, bool) {
    if let Some(pr) = preview {
        if let Some(r) = previews.iter().find(|r| r.preview.as_ref().map(|p| p.pr) == Some(pr)) {
            return (Some(r.clone()), false);
        }
        return (pick(list, channel), true);
    }
    (pick(list, channel), false)
}

/// Downloads a preview build's artifact (a zip of the IPA, Poki-signing.zip and SHA256SUMS) with
/// the saved GitHub token, unpacks it into the cache and checks the IPA against the SHA256SUMS.
async fn fetch_preview(release: &Release, info: &PreviewInfo, reporter: &Reporter) -> Result<(PathBuf, Option<PathBuf>)> {
    let dir = paths::cache_dir()?.join(format!("preview-pr-{}-{}", info.pr, info.artifact_id));
    let ipa = dir.join("Poki-external-unsigned.ipa");
    let signing = dir.join("Poki-signing.zip");
    if !(ipa.is_file() && dir.join(".complete").is_file()) {
        let token = github_token().ok_or_else(|| Error::msg("Downloading a preview build needs a GitHub sign-in. Sign in to GitHub where the preview build is chosen, then try again."))?;
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir)?;
        let zip_path = dir.join("artifact.zip");
        let res = client()?.get(&release.ipa_url).bearer_auth(token).header("Accept", "application/vnd.github+json").send().await?;
        let res = match res.status().as_u16() {
            401 | 403 => return Err(Error::msg("GitHub did not accept the sign-in for this preview build. Sign in to GitHub again.")),
            404 | 410 => return Err(Error::msg("This preview build is gone. Its pull request may have a newer build, or it was closed.")),
            _ => res.error_for_status()?,
        };
        save_stream(res, &zip_path, reporter, "release").await?;
        let (z, d) = (zip_path.clone(), dir.clone());
        tokio::task::spawn_blocking(move || unpack_preview(&z, &d)).await.map_err(|e| Error::msg(e.to_string()))??;
        let _ = std::fs::remove_file(&zip_path);
        if !ipa.is_file() {
            return Err(Error::msg("The preview build has no Poki IPA in it."));
        }
        let sums = std::fs::read_to_string(dir.join("SHA256SUMS")).unwrap_or_default();
        match sum_for(&sums, "Poki-external-unsigned.ipa") {
            Some(expected) if expected == sha256_file(&ipa)? => {}
            _ => {
                let _ = std::fs::remove_dir_all(&dir);
                return Err(Error::msg("The preview build's IPA does not match its SHA256SUMS. Try again."));
            }
        }
        std::fs::write(dir.join(".complete"), b"")?;
    }
    Ok((ipa, signing.is_file().then_some(signing)))
}

/// Takes the three files Poki Setup needs out of the artifact, by exact name.
fn unpack_preview(zip_path: &std::path::Path, dir: &std::path::Path) -> Result<()> {
    let mut archive = zip::ZipArchive::new(std::fs::File::open(zip_path)?).map_err(|e| Error::msg(format!("The preview build did not unpack ({e}).")))?;
    for name in ["Poki-external-unsigned.ipa", "Poki-signing.zip", "SHA256SUMS"] {
        let Ok(mut entry) = archive.by_name(name) else { continue };
        let mut out = std::fs::File::create(dir.join(name))?;
        std::io::copy(&mut entry, &mut out)?;
    }
    Ok(())
}

/// The Preview Builds switch, the GitHub sign-in, the chosen pull request and the preview builds on
/// offer, for the pickers.
#[derive(Debug, Clone, Serialize)]
pub struct PreviewState {
    /// The Preview Builds switch is on (it needs the GitHub sign-in): show the preview builds.
    pub enabled: bool,
    pub selected: Option<u64>,
    /// GitHub is signed in (or a token is saved), so a preview build can be downloaded.
    pub has_token: bool,
    /// The GitHub account's name, when the sign-in told it.
    pub github_login: Option<String>,
    /// This build can run the GitHub sign-in.
    pub can_sign_in: bool,
    pub builds: Vec<Release>,
}

/// The preview picker's state. With the switch off nothing is listed and GitHub is not asked.
pub async fn previews() -> Result<PreviewState> {
    if !previews_enabled() {
        return Ok(PreviewState { enabled: false, selected: None, has_token: github_token().is_some(), github_login: github_login(), can_sign_in: github_client_id().is_ok(), builds: vec![] });
    }
    let builds = list_previews().await?;
    let mut selected = preview();
    // A chosen build that is gone: back to the channel, as latest() does.
    if let Some(pr) = selected {
        if !builds.iter().any(|r| r.preview.as_ref().map(|p| p.pr) == Some(pr)) {
            set_preview(None)?;
            selected = None;
        }
    }
    Ok(PreviewState { enabled: true, selected, has_token: github_token().is_some(), github_login: github_login(), can_sign_in: github_client_id().is_ok(), builds })
}

/// The highest version and build the channel offers, whatever order GitHub lists releases in
/// (rolling ios-*-latest releases keep their first creation date while their files change).
/// On a tie the channel's own release wins, then the later published one.
fn pick_exact(list: &[GhRelease], channel: Channel) -> Option<Release> {
    list.iter()
        .filter_map(installable)
        .filter(|(c, _)| channel.includes(*c))
        .max_by(|(ca, a), (cb, b)| {
            let key = |c: &Channel, r: &Release| (version_key(&full(&r.version, &r.build)), *c == channel, r.published_at.clone());
            key(ca, a).cmp(&key(cb, b))
        })
        .map(|(_, r)| r)
}

/// The newest release the channel offers; when it has none yet, the next less stable channel's,
/// one step at a time (Stable, then Beta, then Alpha, then Pre-alpha).
fn pick(list: &[GhRelease], channel: Channel) -> Option<Release> {
    channel.fallbacks().find_map(|c| pick_exact(list, c))
}

fn none_in(channel: Channel) -> Error {
    Error::msg(format!("No Poki release with an installable IPA is published on the {} channel at github.com/{}. Pick another channel, or choose an IPA file.", channel.title(), repo()))
}

/// What Poki Setup and Poki install and update with: the chosen preview build when preview builds
/// are on and one is chosen, else the newest installable release on the chosen channel. When the
/// chosen preview is gone the choice is dropped and the channel takes over again.
pub async fn latest() -> Result<Release> {
    let (channel, preview) = (channel(), preview());
    let previews = if preview.is_some() { list_previews().await? } else { vec![] };
    let (found, gone) = choose(&list().await?, channel, &previews, preview);
    if gone {
        let _ = set_preview(None);
    }
    found.ok_or_else(|| none_in(channel))
}

/// The newest installable release that a channel offers.
pub async fn latest_in(channel: Channel) -> Result<Release> { pick(&list().await?, channel).ok_or_else(|| none_in(channel)) }

/// One channel's row for the picker: its newest release, if any.
#[derive(Debug, Clone, Serialize)]
pub struct ChannelInfo {
    pub id: Channel,
    pub title: &'static str,
    pub selected: bool,
    pub latest: Option<Release>,
}

/// Every channel with its newest release (one GitHub request), the chosen one marked.
pub async fn channels() -> Result<Vec<ChannelInfo>> {
    let chosen = channel();
    let list = list().await.ok();
    Ok(offered_channels()
        .iter()
        .map(|&c| ChannelInfo { id: c, title: c.title(), selected: c == chosen, latest: list.as_deref().and_then(|l| pick(l, c)) })
        .collect())
}

/// Poki Setup's own update on the chosen channel. Any release on the channel can carry it (an
/// `ios-*` release with the desktop apps attached, or a `desktop-*` one): the asset for this
/// platform, `PokiSetup-<version>-<build>-macos.dmg` or `PokiSetup-<version>-<build>-windows-x64-setup.exe`.
#[derive(Debug, Clone, Serialize)]
pub struct UpdateInfo {
    pub current: String,
    pub latest: Option<String>,
    /// The release page.
    pub url: Option<String>,
    /// The installer for this computer.
    pub asset_url: Option<String>,
    pub asset_name: Option<String>,
    pub newer: bool,
    pub channel: Channel,
    /// The release's SHA256SUMS-desktop.txt, to check the download against.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sums_url: Option<String>,
}

/// The installer name suffix for this platform.
fn platform_suffix() -> &'static str {
    if cfg!(target_os = "macos") { "-macos.dmg" } else { "-windows-x64-setup.exe" }
}

/// The version in a Poki Setup installer's name, for this platform.
fn desktop_asset_version(name: &str, suffix: &str) -> Option<String> {
    let v = name.strip_prefix("PokiSetup-")?.strip_suffix(suffix)?;
    (!v.is_empty() && v.chars().next()?.is_ascii_digit()).then(|| v.to_string())
}

fn release_channel(r: &GhRelease) -> Option<Channel> {
    Channel::of_tag("desktop", &r.tag_name, r.prerelease).or_else(|| Channel::of_app_release(&r.tag_name, r.prerelease))
}

/// The newest Poki Setup installer a channel offers (stepping down like Poki's own releases).
fn pick_desktop<'a>(list: &'a [GhRelease], channel: Channel, suffix: &str) -> Option<(&'a GhRelease, &'a GhAsset, String)> {
    channel.fallbacks().find_map(|want| {
        list.iter()
            .filter(|r| release_channel(r).map(|c| want.includes(c)).unwrap_or(false))
            .flat_map(|r| r.assets.iter().filter_map(move |a| desktop_asset_version(&a.name, suffix).map(|v| (r, a, v))))
            .max_by(|a, b| version_key(&a.2).cmp(&version_key(&b.2)))
    })
}

pub async fn desktop_update() -> Result<UpdateInfo> {
    let channel = channel();
    let current = crate::full_version();
    let list = list().await?;
    let found = pick_desktop(&list, channel, platform_suffix());
    let newer = found.as_ref().map(|(_, _, v)| version_key(v) > version_key(&current)).unwrap_or(false);
    Ok(match found {
        Some((r, a, v)) => {
            let sums_url = r.assets.iter().find(|a| a.name == "SHA256SUMS-desktop.txt").map(|a| a.browser_download_url.clone());
            UpdateInfo { current, latest: Some(v), url: r.html_url.clone(), asset_url: Some(a.browser_download_url.clone()), asset_name: Some(a.name.clone()), newer, channel, sums_url }
        }
        None => UpdateInfo { current, latest: None, url: None, asset_url: None, asset_name: None, newer, channel, sums_url: None },
    })
}

/// What installing an update did.
#[derive(Debug, Clone, Serialize)]
pub struct Installed {
    /// The downloaded installer.
    pub path: PathBuf,
    /// The new Poki Setup is in place (or its installer is running) and starts by itself once
    /// this one quits: the app should quit now.
    pub relaunching: bool,
}

/// Downloads the newer Poki Setup, checks it against the release's SHA256SUMS-desktop.txt, and
/// installs it over this one: on a Mac the app inside the disk image replaces this app bundle and
/// a helper opens the new one after this one quits; on Windows the installer runs in passive mode
/// and starts Poki Setup again. When the swap is not possible (the app is not in a writable
/// place, for example) the disk image or installer is opened for the person instead.
pub async fn install_desktop_update(reporter: &Reporter) -> Result<Installed> {
    let info = desktop_update().await?;
    let (Some(url), Some(name), true) = (info.asset_url, info.asset_name, info.newer) else {
        return Err(Error::msg("Poki Setup is up to date."));
    };
    let dir = paths::cache_dir()?.join("updates");
    std::fs::create_dir_all(&dir)?;
    let to = dir.join(&name);
    let expected = match &info.sums_url {
        Some(u) => client()?.get(u).send().await?.error_for_status()?.text().await.ok().and_then(|t| sum_for(&t, &name)),
        None => None,
    };
    let good = |p: &std::path::Path| p.is_file() && expected.as_deref().map(|e| sha256_file(p).ok().as_deref() == Some(e)).unwrap_or(true);
    if !good(&to) {
        let part = dir.join(format!("{name}.part"));
        download(&url, &part, reporter, "update").await?;
        if let Some(e) = &expected {
            let got = sha256_file(&part)?;
            if &got != e {
                let _ = std::fs::remove_file(&part);
                return Err(Error::msg(format!("The downloaded update did not match its checksum ({got}). Try again.")));
            }
        }
        std::fs::rename(&part, &to)?;
    }
    match install_in_place(&to) {
        Ok(()) => Ok(Installed { path: to, relaunching: true }),
        Err(e) => {
            tracing::warn!("update not installed in place ({e}); opening the installer");
            open_installer(&to)?;
            Ok(Installed { path: to, relaunching: false })
        }
    }
}

fn sum_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut parts = l.split_whitespace();
        let hash = parts.next()?;
        (parts.next()?.trim_start_matches('*') == name).then(|| hash.to_lowercase())
    })
}

#[cfg(target_os = "macos")]
fn install_in_place(dmg: &std::path::Path) -> Result<()> {
    use std::process::Command;
    // This process is Poki Setup.app/Contents/MacOS/<exe>.
    let exe = std::env::current_exe()?;
    let bundle = exe.ancestors().nth(3).filter(|p| p.extension().map(|e| e == "app").unwrap_or(false))
        .ok_or_else(|| Error::msg("Poki Setup is not running from an app bundle."))?.to_path_buf();
    let mount = std::env::temp_dir().join(format!("poki-setup-update-{}", std::process::id()));
    std::fs::create_dir_all(&mount)?;
    let st = Command::new("/usr/bin/hdiutil").args(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint"]).arg(&mount).arg(dmg).status()?;
    if !st.success() {
        return Err(Error::msg("Could not open the update's disk image."));
    }
    let result = (|| -> Result<()> {
        let new_app = std::fs::read_dir(&mount)?.filter_map(|e| e.ok()).map(|e| e.path())
            .find(|p| p.extension().map(|e| e == "app").unwrap_or(false))
            .ok_or_else(|| Error::msg("The update's disk image has no app in it."))?;
        verify_mac_app(&new_app)?;
        let staged = bundle.with_extension("app.new");
        let old = bundle.with_extension("app.old");
        let _ = std::fs::remove_dir_all(&staged);
        let _ = std::fs::remove_dir_all(&old);
        if !Command::new("/usr/bin/ditto").arg(&new_app).arg(&staged).status()?.success() {
            let _ = std::fs::remove_dir_all(&staged);
            return Err(Error::msg("Could not copy the new Poki Setup next to this one."));
        }
        // Swap: a running app keeps its open files after its bundle is renamed.
        std::fs::rename(&bundle, &old)?;
        if let Err(e) = std::fs::rename(&staged, &bundle) {
            let _ = std::fs::rename(&old, &bundle);
            return Err(e.into());
        }
        let _ = std::fs::remove_dir_all(&old);
        Ok(())
    })();
    let _ = Command::new("/usr/bin/hdiutil").args(["detach", "-quiet"]).arg(&mount).status();
    let _ = std::fs::remove_dir(&mount);
    result?;
    // Opens the new app once this one has quit (the app quits when told `relaunching`).
    let pid = std::process::id();
    let script = format!("while kill -0 {pid} 2>/dev/null; do sleep 0.3; done; sleep 0.5; /usr/bin/open \"$0\"");
    use std::os::unix::process::CommandExt;
    Command::new("/bin/sh").arg("-c").arg(script).arg(&bundle).process_group(0)
        .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null())
        .spawn()?;
    Ok(())
}

/// The new app must carry a valid signature from the same team as this one (Developer ID,
/// notarized builds only), so a swapped download can never replace Poki Setup with something else.
#[cfg(target_os = "macos")]
fn verify_mac_app(app: &std::path::Path) -> Result<()> {
    use std::process::Command;
    let ok = Command::new("/usr/bin/codesign").args(["--verify", "--deep", "--strict"]).arg(app).status()?.success();
    if !ok {
        return Err(Error::msg("The update's signature did not check out."));
    }
    let team = |p: &std::path::Path| -> Option<String> {
        let out = Command::new("/usr/bin/codesign").args(["-dv"]).arg(p).output().ok()?;
        let text = String::from_utf8_lossy(&out.stderr).to_string();
        text.lines().find_map(|l| l.strip_prefix("TeamIdentifier=")).map(|t| t.trim().to_string()).filter(|t| t != "not set")
    };
    let exe = std::env::current_exe()?;
    let mine = exe.ancestors().nth(3).and_then(team);
    let theirs = team(app);
    match (mine, theirs) {
        (Some(a), Some(b)) if a == b => Ok(()),
        (None, _) => Err(Error::msg("This Poki Setup is not signed with a Developer ID, so it does not update itself.")),
        (Some(a), b) => Err(Error::msg(format!("The update is signed by another team ({}), not {a}.", b.unwrap_or_else(|| "none".into())))),
    }
}

#[cfg(windows)]
fn install_in_place(setup: &std::path::Path) -> Result<()> {
    // Tauri's NSIS installer: /P passive (progress only, no questions), /R starts the app again.
    std::process::Command::new(setup).args(["/P", "/R"]).spawn()?;
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn install_in_place(_: &std::path::Path) -> Result<()> { Err(Error::msg("Updates install by themselves on macOS and Windows only.")) }

fn open_installer(path: &std::path::Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    std::process::Command::new("/usr/bin/open").arg(path).spawn()?;
    #[cfg(windows)]
    std::process::Command::new(path).spawn()?;
    #[cfg(not(any(target_os = "macos", windows)))]
    let _ = path;
    Ok(())
}

/// One dot-separated part of a suffix: numbers compare as numbers and sort before words.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Ident {
    Num(u64),
    Text(String),
}

/// How a version compares, SemVer-like with Poki's build numbers:
/// `0.3.0-beta.1` < `0.3.0-beta.2` < `0.3.0` < `0.3.0-700` < `0.3.1`. The numbers before the
/// first `-` compare in order; then a pre-release suffix (any part that is not a number, like
/// `beta.1` or `rc.2`) sorts below the plain version, and a build number (`-700`) above it.
type VersionKey = (Vec<u64>, u8, Vec<Ident>);

fn version_key(s: &str) -> VersionKey {
    let (core, suffix) = s.split_once('-').unwrap_or((s, ""));
    let core = core.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect();
    if suffix.is_empty() {
        return (core, 1, vec![]);
    }
    let parts: Vec<Ident> = suffix.split(['.', '-']).map(|x| x.parse::<u64>().map(Ident::Num).unwrap_or_else(|_| Ident::Text(x.to_ascii_lowercase()))).collect();
    let build = parts.iter().all(|p| matches!(p, Ident::Num(_)));
    (core, if build { 2 } else { 0 }, parts)
}

/// A release's version and build as one string for [`version_key`]: `0.3.0`, `0.3.0-beta.1`, `0.2.9-630`.
fn full(version: &str, build: &str) -> String {
    if build.is_empty() { version.to_string() } else { format!("{version}-{build}") }
}

/// Downloads the IPA (and the signing zip) into the cache, checks SHA-256 against SHA256SUMS.
pub async fn fetch(release: &Release, reporter: &Reporter) -> Result<(PathBuf, Option<PathBuf>)> {
    if let Some(info) = &release.preview {
        return fetch_preview(release, info, reporter).await;
    }
    let dir = paths::cache_dir()?.join(&release.tag);
    std::fs::create_dir_all(&dir)?;
    let ipa = dir.join(&release.ipa_name);
    let sums = match &release.sums_url {
        Some(u) => Some(client()?.get(u).send().await?.error_for_status()?.text().await?),
        None => None,
    };
    let expected = sums.as_ref().and_then(|s| s.lines().find(|l| l.ends_with(&release.ipa_name)).and_then(|l| l.split_whitespace().next()).map(|h| h.to_lowercase()));
    if !(ipa.is_file() && expected.as_deref().map(|e| sha256_file(&ipa).ok().as_deref() == Some(e)).unwrap_or(false)) {
        download(&release.ipa_url, &ipa, reporter, "release").await?;
        if let Some(e) = &expected {
            let got = sha256_file(&ipa)?;
            if &got != e {
                let _ = std::fs::remove_file(&ipa);
                return Err(Error::msg("The downloaded IPA does not match the release's SHA256SUMS. Try again; if it repeats, the download is being altered on the way."));
            }
        }
    }
    let signing = match &release.signing_url {
        Some(u) => {
            let p = dir.join("Poki-signing.zip");
            if !p.is_file() {
                download(u, &p, reporter, "release").await?;
            }
            Some(p)
        }
        None => None,
    };
    Ok((ipa, signing))
}

const RELAY_ASSET: &str = "poki-relay-worker.js";

/// Which Poki the relay has to match: the release it was installed from, or its version and build
/// (for an IPA file picked by hand, found by the release's `Poki-external-<version>-<build>.ipa`).
#[derive(Debug, Clone, Default)]
pub struct RelayFor {
    pub tag: Option<String>,
    pub version: Option<String>,
    pub build: Option<String>,
}

/// The relay Worker (`poki-relay-worker.js`) of the release matching that Poki, checked against
/// the release's SHA256SUMS. Without a match (or with nothing to match), the newest one on the
/// chosen channel, stepping down like Poki's own releases. None when no release carries one.
pub async fn relay_worker(want: &RelayFor) -> Result<Option<(String, String, String)>> {
    let list = list().await?;
    let has = |r: &&GhRelease| r.assets.iter().any(|a| a.name == RELAY_ASSET);
    let by_tag = want.tag.as_deref().and_then(|t| list.iter().filter(has).find(|r| r.tag_name == t));
    let by_build = match (&want.version, &want.build) {
        (Some(v), Some(b)) => {
            let ipa = format!("Poki-external-{v}-{b}.ipa");
            list.iter().filter(has).find(|r| r.assets.iter().any(|a| a.name == ipa))
        }
        _ => None,
    };
    let found = by_tag.or(by_build).or_else(|| {
        channel().fallbacks().find_map(|c| list.iter().filter(has).find(|r| release_channel(r).map(|rc| c.includes(rc)).unwrap_or(false)))
    });
    let Some(r) = found else { return Ok(None) };
    let url = &r.assets.iter().find(|a| a.name == RELAY_ASSET).unwrap().browser_download_url;
    let sums_url = r.assets.iter().find(|a| a.name == "SHA256SUMS").map(|a| a.browser_download_url.clone())
        .ok_or_else(|| Error::msg(format!("Release {} has the relay but no SHA256SUMS to check it against.", r.tag_name)))?;
    let http = client()?;
    let sums = http.get(&sums_url).timeout(std::time::Duration::from_secs(30)).send().await?.error_for_status()?.text().await?;
    let expected = sums.lines().find(|l| l.split_whitespace().last().map(|n| n.trim_start_matches('*')) == Some(RELAY_ASSET)).and_then(|l| l.split_whitespace().next()).map(|h| h.to_lowercase())
        .ok_or_else(|| Error::msg(format!("Release {}'s SHA256SUMS does not list {RELAY_ASSET}.", r.tag_name)))?;
    let body = http.get(url).timeout(std::time::Duration::from_secs(60)).send().await?.error_for_status()?.text().await?;
    let got = hex::encode(Sha256::digest(body.as_bytes()));
    if got != expected {
        return Err(Error::msg(format!("The relay in release {} does not match its SHA256SUMS. Try again; if it repeats, the download is being altered on the way.", r.tag_name)));
    }
    Ok(Some((r.tag_name.clone(), body, url.clone())))
}

pub async fn download(url: &str, to: &std::path::Path, reporter: &Reporter, step: &str) -> Result<()> {
    let res = client()?.get(url).send().await?.error_for_status()?;
    save_stream(res, to, reporter, step).await
}

async fn save_stream(res: reqwest::Response, to: &std::path::Path, reporter: &Reporter, step: &str) -> Result<()> {
    use futures_util::StreamExt;
    let total = res.content_length();
    let tmp = to.with_extension("part");
    let mut file = tokio::fs::File::create(&tmp).await?;
    let mut stream = res.bytes_stream();
    let mut got: u64 = 0;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        tokio::io::AsyncWriteExt::write_all(&mut file, &chunk).await?;
        got += chunk.len() as u64;
        if let Some(t) = total {
            reporter.part(step, got as f64 / t as f64, Some(format!("{:.1} of {:.1} MB", got as f64 / 1e6, t as f64 / 1e6)));
        }
    }
    tokio::io::AsyncWriteExt::flush(&mut file).await?;
    drop(file);
    std::fs::rename(&tmp, to)?;
    Ok(())
}

pub fn sha256_file(path: &std::path::Path) -> Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut h = Sha256::new();
    std::io::copy(&mut f, &mut h)?;
    Ok(hex::encode(h.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gh(tag: &str, pre: bool, at: &str, ipa: Option<&str>) -> GhRelease {
        GhRelease {
            tag_name: tag.into(),
            prerelease: pre,
            draft: false,
            published_at: Some(at.into()),
            body: None,
            html_url: None,
            assets: ipa.map(|n| vec![GhAsset { name: n.into(), browser_download_url: format!("https://x/{n}") }]).unwrap_or_default(),
        }
    }

    #[test]
    fn tags_map_to_channels() {
        assert_eq!(Channel::of_tag("ios", "ios-v0.2.7", false), Some(Channel::Stable));
        assert_eq!(Channel::of_tag("ios", "ios-v0.2.7", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("ios", "ios-prealpha-0.2.7-252", true), Some(Channel::PreAlpha));
        assert_eq!(Channel::of_tag("ios", "ios-alpha-0.2.8-110", true), Some(Channel::Alpha));
        assert_eq!(Channel::of_tag("ios", "ios-alpha-latest", true), Some(Channel::Alpha));
        assert_eq!(Channel::of_tag("ios", "ios-prealpha-latest", true), Some(Channel::PreAlpha));
        assert_eq!(Channel::of_tag("ios", "ios-beta-0.3.0-600", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("desktop", "desktop-beta-0.3.0-9", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("desktop", "desktop-alpha-0.2.1-3", true), Some(Channel::Alpha));
        assert!(Channel::PreAlpha.includes(Channel::Alpha) && Channel::Alpha.includes(Channel::Beta) && !Channel::Beta.includes(Channel::Alpha));
        assert_eq!(Channel::parse("alpha"), Some(Channel::Alpha));
        assert_eq!(Channel::of_tag("ios", "v0.1.1", false), None);
        assert_eq!(Channel::of_tag("ios", "desktop-v0.2.0", false), None);
        assert_eq!(Channel::of_tag("desktop", "desktop-prealpha-0.2.1-9", true), Some(Channel::PreAlpha));
        assert_eq!(Channel::parse("Pre-alpha"), Some(Channel::PreAlpha));
        assert_eq!(serde_json::to_string(&Channel::PreAlpha).unwrap(), "\"pre-alpha\"");
    }

    #[test]
    fn channels_include_the_ones_above() {
        let mut list = vec![
            gh("ios-prealpha-0.2.8-260", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.8-260.ipa")),
            gh("ios-v0.2.7", true, "2026-11-07T05:00:00Z", Some("Poki-external-0.2.7-12.ipa")),
            gh("ios-v0.2.6", false, "2026-11-06T05:00:00Z", Some("Poki-external-0.2.6-9.ipa")),
            gh("v0.1.1", false, "2026-11-08T06:00:00Z", None),
        ];
        list.sort_by(|a, b| b.published_at.cmp(&a.published_at));
        let p = pick(&list, Channel::PreAlpha).unwrap();
        assert_eq!((p.version.as_str(), p.build.as_str(), p.channel), ("0.2.8", "260", Channel::PreAlpha));
        assert_eq!(pick(&list, Channel::Beta).unwrap().tag, "ios-v0.2.7");
        assert_eq!(pick(&list, Channel::Stable).unwrap().tag, "ios-v0.2.6");
        // Sorted: v0.1.1, prealpha, v0.2.7 (beta), v0.2.6. Without a Stable release, Stable steps
        // down to Beta; with only a Pre-alpha one it takes that; with no ios-* release, nothing.
        assert_eq!(pick(&list[..3], Channel::Stable).unwrap().tag, "ios-v0.2.7");
        // Pre-alpha is reached only with a GitHub sign-in, by choice or by stepping down.
        let (_g, _d) = paths::test_home();
        unsafe { std::env::set_var("POKI_SETUP_FILE_SECRETS", "1") };
        assert!(pick(&list[..2], Channel::Stable).is_none());
        set_github_token("gho_test").unwrap();
        assert_eq!(pick(&list[..2], Channel::Stable).unwrap().tag, "ios-prealpha-0.2.8-260");
        assert!(pick(&list[..1], Channel::Stable).is_none());
        assert_eq!(Channel::default(), Channel::Stable);
    }

    #[test]
    fn rolling_release_wins_by_build_not_list_order() {
        // Rolling releases keep their first date; a Beta made later sits above them in the list.
        let list = vec![
            gh("ios-beta-0.2.9-520", true, "2026-11-10T05:00:00Z", Some("Poki-external-0.2.9-520.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-540.ipa")),
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-530.ipa")),
        ];
        assert_eq!(pick(&list, Channel::PreAlpha).unwrap().build, "540");
        assert_eq!(pick(&list, Channel::Alpha).unwrap().build, "530");
        assert_eq!(pick(&list, Channel::Beta).unwrap().tag, "ios-beta-0.2.9-520");
        // Same build on two channels: Pre-alpha users get their own channel's release.
        let tie = vec![
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.8-501.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.8-501.ipa")),
        ];
        assert_eq!(pick(&tie, Channel::PreAlpha).unwrap().tag, "ios-prealpha-latest");
        assert_eq!(pick(&tie, Channel::Alpha).unwrap().tag, "ios-alpha-latest");
    }

    #[test]
    fn choice_is_saved() {
        let (_g, _d) = paths::test_home();
        unsafe { std::env::remove_var("POKI_RELEASE_CHANNEL") };
        unsafe { std::env::set_var("POKI_SETUP_FILE_SECRETS", "1") };
        assert_eq!(channel(), Channel::Stable);
        set_channel(Channel::Beta).unwrap();
        assert_eq!(channel(), Channel::Beta);
        // Pre-alpha needs a GitHub sign-in, to choose it and to stay on it.
        assert!(set_channel(Channel::PreAlpha).is_err());
        assert!(!offered_channels().contains(&Channel::PreAlpha));
        set_github_token("gho_test").unwrap();
        set_channel(Channel::PreAlpha).unwrap();
        assert_eq!(channel(), Channel::PreAlpha);
        assert_eq!(offered_channels(), Channel::ALL.to_vec());
        set_github_token("").unwrap();
        assert_eq!(channel(), Channel::Alpha);
        set_github_token("gho_test").unwrap();
        assert_eq!(channel(), Channel::PreAlpha);
    }

    fn art(id: u64, name: &str, repo: u64, head: u64) -> GhArtifact {
        GhArtifact { id, name: name.into(), expired: false, created_at: Some("2026-11-12T05:00:00Z".into()), archive_download_url: format!("https://x/artifacts/{id}/zip"), workflow_run: Some(GhRun { repository_id: Some(repo), head_repository_id: Some(head), head_branch: Some(format!("dev/pr{}", name.trim_start_matches("Poki-preview-pr").split('-').next().unwrap_or(""))) }) }
    }

    #[test]
    fn preview_artifact_names() {
        assert_eq!(preview_name("Poki-preview-pr177-0.3.1-783-24a45bb8bb04"), Some((177, "0.3.1".into(), "783".into(), "24a45bb8bb04".into())));
        for bad in ["Poki-unsigned", "Poki-preview-pr-0.3.1-783-24a45bb", "Poki-preview-pr177-0.3-783-24a45bb", "Poki-preview-pr177-0.3.1-x-24a45bb", "Poki-preview-pr177-0.3.1-783-zzzzzzz", "Poki-preview-pr177-0.3.1-783-24a45bb-more", "Poki-preview-pr177-0.3.1-783"] {
            assert_eq!(preview_name(bad), None, "{bad}");
        }
        // Nothing about a preview is a release, so no channel can offer one.
        assert_eq!(Channel::of_app_release("preview-pr-177", true), None);
    }

    #[test]
    fn preview_builds_are_listed_and_chosen() {
        let mut expired = art(50, "Poki-preview-pr200-0.3.1-800-aaaaaaaaaaaa", 1, 1);
        expired.expired = true;
        let artifacts = vec![
            art(40, "Poki-preview-pr177-0.3.1-785-bbbbbbbbbbbb", 1, 1),
            art(30, "Poki-preview-pr177-0.3.1-783-24a45bb8bb04", 1, 1),
            art(35, "Poki-preview-pr12-0.3.1-770-cccccccccccc", 1, 1),
            // Uploaded by a fork's pull request under a preview's name: not believed.
            art(60, "Poki-preview-pr180-0.3.1-790-dddddddddddd", 1, 2),
            art(61, "Poki-unsigned", 1, 1),
            expired,
        ];
        let pull = |number: u64, title: &str, branch: &str| GhPull { number, title: title.into(), head: GhPullHead { branch: branch.into() } };
        let open = vec![pull(177, "Fix a > b", "dev/pr177"), pull(12, "", "dev/pr12"), pull(180, "", "dev/pr180"), pull(200, "", "dev/pr200")];
        let found = preview_list(&artifacts, &open);
        assert_eq!(found.iter().map(|r| r.preview.as_ref().unwrap().pr).collect::<Vec<_>>(), vec![177, 12]);
        let p = &found[0];
        assert_eq!((p.version.as_str(), p.build.as_str(), p.tag.as_str(), p.ipa_url.as_str()), ("0.3.1", "785", "preview-pr-177", "https://x/artifacts/40/zip"));
        assert_eq!(p.preview, Some(PreviewInfo { pr: 177, sha: "bbbbbbbbbbbb".into(), title: "Fix a > b".into(), artifact_id: 40 }));
        // A build of another branch under pull request 177's name is not believed.
        let mut forged = art(70, "Poki-preview-pr177-0.3.1-799-eeeeeeeeeeee", 1, 1);
        forged.workflow_run.as_mut().unwrap().head_branch = Some("dev/other".into());
        assert_eq!(preview_list(&[forged], &open).len(), 0);
        // A closed pull request's leftover build is not offered, and with no pull requests nothing is.
        assert_eq!(preview_list(&artifacts, &open[..1]).len(), 1);
        assert!(preview_list(&artifacts, &[]).is_empty());

        let found = preview_list(&artifacts, &open[..1]);
        let channels = vec![gh("app-prealpha-latest", true, "2026-11-09T06:00:00Z", Some("Poki-external-0.3.1-760.ipa"))];
        let (r, gone) = choose(&channels, Channel::PreAlpha, &found, Some(177));
        assert_eq!((r.unwrap().build.as_str(), gone), ("785", false));
        // The pull request was merged or closed: its build is gone, so the channel's is used.
        let (r, gone) = choose(&channels, Channel::PreAlpha, &found, Some(12));
        assert_eq!((r.unwrap().build.as_str(), gone), ("760", true));
        let (r, gone) = choose(&channels, Channel::PreAlpha, &found, None);
        assert_eq!((r.unwrap().build.as_str(), gone), ("760", false));
    }

    #[test]
    fn preview_artifact_unpacks_only_its_three_files() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let zip_path = dir.path().join("a.zip");
        let mut w = zip::ZipWriter::new(std::fs::File::create(&zip_path).unwrap());
        let opts = zip::write::SimpleFileOptions::default();
        for (name, body) in [("Poki-external-unsigned.ipa", "ipa"), ("Poki-signing.zip", "zip"), ("SHA256SUMS", "sums"), ("signing/external/x.plist", "p"), ("../evil", "e")] {
            w.start_file(name, opts).unwrap();
            w.write_all(body.as_bytes()).unwrap();
        }
        w.finish().unwrap();
        let out = dir.path().join("out");
        std::fs::create_dir_all(&out).unwrap();
        unpack_preview(&zip_path, &out).unwrap();
        let mut names: Vec<String> = std::fs::read_dir(&out).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
        names.sort();
        assert_eq!(names, vec!["Poki-external-unsigned.ipa", "Poki-signing.zip", "SHA256SUMS"]);
        assert!(!dir.path().join("evil").exists());
    }

    #[test]
    fn github_sign_in_answers() {
        let a = |token: Option<&str>, error: Option<&str>| GithubTokenAnswer { access_token: token.map(String::from), error: error.map(String::from) };
        assert_eq!(github_poll_step(&a(Some("gho_x"), None)), Ok(Some("gho_x".into())));
        assert_eq!(github_poll_step(&a(None, Some("authorization_pending"))), Err(Ok(0)));
        assert_eq!(github_poll_step(&a(None, Some("slow_down"))), Err(Ok(5)));
        assert!(matches!(github_poll_step(&a(None, Some("access_denied"))), Err(Err(_))));
        assert!(matches!(github_poll_step(&a(None, Some("expired_token"))), Err(Err(_))));
        assert!(matches!(github_poll_step(&a(Some(""), None)), Err(Err(_))));
    }

    #[test]
    fn preview_choice_needs_the_switch() {
        let (_g, _d) = paths::test_home();
        unsafe { std::env::remove_var("POKI_RELEASE_CHANNEL") };
        unsafe { std::env::set_var("POKI_SETUP_FILE_SECRETS", "1") };
        assert!(!previews_enabled());
        assert!(set_preview(Some(177)).is_err());
        assert_eq!(preview(), None);
        // The switch needs a GitHub sign-in.
        assert!(set_preview_switch(true).is_err());
        set_github_token("gho_test").unwrap();
        assert!(!previews_enabled());
        set_preview_switch(true).unwrap();
        set_preview(Some(177)).unwrap();
        assert_eq!(preview(), Some(177));
        // Changing the channel keeps the preview choice, and the other way round.
        set_channel(Channel::Alpha).unwrap();
        assert_eq!((channel(), preview()), (Channel::Alpha, Some(177)));
        // Off: the choice is dropped, and stays dropped when the switch comes back on.
        set_preview_switch(false).unwrap();
        assert_eq!(preview(), None);
        set_preview_switch(true).unwrap();
        assert_eq!((channel(), preview()), (Channel::Alpha, None));
        // Signing out of GitHub turns preview builds off and drops the choice.
        set_preview(Some(177)).unwrap();
        set_github_token("").unwrap();
        assert_eq!((previews_enabled(), preview(), github_login()), (false, None, None));
        set_github_token("gho_test").unwrap();
        assert!(!previews_enabled());
    }

    #[test]
    fn desktop_installer_found_on_any_release() {
        let mut ios = gh("ios-prealpha-0.2.8-441", true, "2026-11-08T08:00:00Z", Some("Poki-external-0.2.8-441.ipa"));
        ios.assets.push(GhAsset { name: "PokiSetup-0.2.1-300-macos.dmg".into(), browser_download_url: "https://x/dmg".into() });
        ios.assets.push(GhAsset { name: "PokiSetup-0.2.1-300-windows-x64-setup.exe".into(), browser_download_url: "https://x/exe".into() });
        let list = vec![ios];
        let (_g, _d) = paths::test_home();
        unsafe { std::env::set_var("POKI_SETUP_FILE_SECRETS", "1") };
        assert!(pick_desktop(&list, Channel::Stable, "-macos.dmg").is_none());
        set_github_token("gho_test").unwrap();
        let (_, a, v) = pick_desktop(&list, Channel::Stable, "-macos.dmg").unwrap();
        assert_eq!((a.name.as_str(), v.as_str()), ("PokiSetup-0.2.1-300-macos.dmg", "0.2.1-300"));
        assert_eq!(pick_desktop(&list, Channel::Beta, "-windows-x64-setup.exe").unwrap().2, "0.2.1-300");
        assert!(version_key("0.2.1-300") > version_key("0.2.1-296"));
        assert!(version_key("0.2.1-300") > version_key("0.2.0"));
    }

    #[test]
    fn build_suffix_sorts_after_version() {
        assert!(version_key("0.2.1-5") > version_key("0.2.1"));
        assert!(version_key("0.2.2") > version_key("0.2.1-5"));
    }

    #[test]
    fn betas_sort_below_their_stable_and_by_number() {
        let order = ["0.2.9-630", "0.3.0-beta.1", "0.3.0-beta.2", "0.3.0-rc.1", "0.3.0", "0.3.0-700", "0.3.1-beta.1"];
        for w in order.windows(2) {
            assert!(version_key(w[0]) < version_key(w[1]), "{} < {}", w[0], w[1]);
        }
        assert!(version_key("0.3.0-beta.10") > version_key("0.3.0-beta.9"));
        assert_eq!(Channel::of_tag("ios", "ios-v0.3.0-beta.1", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("ios", "ios-v0.3.0", false), Some(Channel::Stable));
        assert_eq!(Channel::of_tag("desktop", "desktop-v0.3.0-beta.1", true), Some(Channel::Beta));
        assert_eq!(Channel::of_tag("desktop", "desktop-v0.3.0", false), Some(Channel::Stable));
    }

    #[test]
    fn app_tags_map_to_channels() {
        let c = |t: &str, pre: bool| Channel::of_app_release(t, pre);
        assert_eq!(c("app-0.2.9-prealpha.640", true), Some(Channel::PreAlpha));
        assert_eq!(c("app-prealpha-latest", true), Some(Channel::PreAlpha));
        assert_eq!(c("app-0.2.9-alpha.640", true), Some(Channel::Alpha));
        assert_eq!(c("app-alpha-latest", true), Some(Channel::Alpha));
        assert_eq!(c("app-0.3.0-beta.1", true), Some(Channel::Beta));
        assert_eq!(c("app-0.3.0", false), Some(Channel::Stable));
        assert_eq!(c("app-0.3.0", true), Some(Channel::Beta));
        assert_eq!(c("app-latest", false), None);
        assert_eq!(c("desktop-v0.3.0", false), None);
        // The ios-* rules stay as they were.
        assert_eq!(c("ios-prealpha-latest", true), Some(Channel::PreAlpha));
        assert_eq!(c("ios-alpha-0.2.8-501", true), Some(Channel::Alpha));
        assert_eq!(c("ios-v0.3.0-beta.1", true), Some(Channel::Beta));
    }

    #[test]
    fn app_and_ios_releases_are_read_together() {
        let list = vec![
            gh("app-0.3.0", false, "2026-11-14T05:00:00Z", Some("Poki-external-0.3.0.ipa")),
            gh("app-0.3.0-beta.1", true, "2026-11-12T05:00:00Z", Some("Poki-external-0.3.0-beta.1.ipa")),
            gh("app-alpha-latest", true, "2026-11-09T06:00:00Z", Some("Poki-external-0.2.9-650.ipa")),
            gh("app-prealpha-latest", true, "2026-11-09T06:00:00Z", Some("Poki-external-0.2.9-660.ipa")),
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-650.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-660.ipa")),
        ];
        let p = pick(&list, Channel::Stable).unwrap();
        assert_eq!((p.tag.as_str(), p.version.as_str(), p.build.as_str()), ("app-0.3.0", "0.3.0", ""));
        assert_eq!(pick(&list[1..], Channel::Beta).unwrap().tag, "app-0.3.0-beta.1");
        // The mirrors carry the same build: either release is fine, the build is what counts.
        assert_eq!(pick(&list[2..], Channel::Alpha).unwrap().build, "650");
        assert_eq!(pick(&list[2..], Channel::PreAlpha).unwrap().build, "660");
        assert_eq!(pick(&list[4..], Channel::PreAlpha).unwrap().tag, "ios-prealpha-latest");

        let mut app = gh("app-alpha-latest", true, "2026-11-09T06:00:00Z", None);
        app.assets.push(GhAsset { name: "PokiSetup-0.2.2-640-macos.dmg".into(), browser_download_url: "https://x/a".into() });
        assert_eq!(pick_desktop(&[app], Channel::Alpha, "-macos.dmg").unwrap().2, "0.2.2-640");
    }

    #[test]
    fn stable_wins_over_its_betas_on_every_channel() {
        let list = vec![
            gh("ios-v0.3.0-beta.2", true, "2026-11-12T05:00:00Z", Some("Poki-external-0.3.0-beta.2.ipa")),
            gh("ios-v0.3.0-beta.1", true, "2026-11-11T05:00:00Z", Some("Poki-external-0.3.0-beta.1.ipa")),
            gh("ios-v0.3.0", false, "2026-11-10T05:00:00Z", Some("Poki-external-0.3.0.ipa")),
            gh("ios-alpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.3.0-700.ipa")),
            gh("ios-prealpha-latest", true, "2026-11-08T05:00:00Z", Some("Poki-external-0.2.9-630.ipa")),
        ];
        let p = pick(&list, Channel::Stable).unwrap();
        assert_eq!((p.tag.as_str(), p.version.as_str(), p.build.as_str()), ("ios-v0.3.0", "0.3.0", ""));
        assert_eq!(pick(&list, Channel::Beta).unwrap().tag, "ios-v0.3.0");
        assert_eq!(pick(&list[..2], Channel::Beta).unwrap().tag, "ios-v0.3.0-beta.2");
        assert_eq!(pick(&list, Channel::Alpha).unwrap().build, "700");
        // Pre-alpha includes every channel: the Alpha 0.3.0-700 is above its own 0.2.9-630.
        assert_eq!(pick(&list, Channel::PreAlpha).unwrap().build, "700");

        let mut beta = gh("desktop-v0.3.0-beta.1", true, "2026-11-11T05:00:00Z", None);
        beta.assets.push(GhAsset { name: "PokiSetup-0.3.0-beta.1-macos.dmg".into(), browser_download_url: "https://x/b".into() });
        let mut stable = gh("desktop-v0.3.0", false, "2026-11-10T05:00:00Z", None);
        stable.assets.push(GhAsset { name: "PokiSetup-0.3.0-macos.dmg".into(), browser_download_url: "https://x/s".into() });
        let desk = vec![beta, stable];
        assert_eq!(pick_desktop(&desk, Channel::Beta, "-macos.dmg").unwrap().2, "0.3.0");
        assert!(version_key("0.3.0") > version_key("0.3.0-beta.1"));
        assert!(version_key("0.3.0-beta.1") > version_key("0.2.2-618"));
    }
}

#[cfg(test)]
mod update_tests {
    #[test]
    fn checksum_line_for_a_file() {
        let sums = "aa11  PokiSetup-0.2.1-307-macos.dmg\nBB22 *PokiSetup-0.2.1-307-windows-x64-setup.exe\n";
        assert_eq!(super::sum_for(sums, "PokiSetup-0.2.1-307-macos.dmg").as_deref(), Some("aa11"));
        assert_eq!(super::sum_for(sums, "PokiSetup-0.2.1-307-windows-x64-setup.exe").as_deref(), Some("bb22"));
        assert_eq!(super::sum_for(sums, "other"), None);
    }
}
