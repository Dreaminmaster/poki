//! iPhone History, first tests (GitHub issue 356): what is on screen, read as text through the
//! accessibility audit service (ax.rs) over the loopback and the pairing. Nothing here opens an
//! XCTest session, so a read is not automation and should not raise the "Automation Running" banner;
//! the tests exist to learn on a real iPhone whether that holds, how long a read takes, and whether
//! reads keep coming while Poki is in the background.
//!
//! Two requests, each on a tunnel of its own (never the launcher's):
//! - `read_once`: one read. Answers with the seconds it took, the apps on screen and the number of
//!   elements. The screen's text is counted, and returned only when `include_text` is set.
//! - `watch`: one subscription kept open for `seconds`. Answers with every tree dump as it arrived.
//! - `run`: a read every `interval_ms` for `duration_s`. Reports each read as it is made, then the
//!   reads made, the failures and the longest gap between two reads.
//!
//! Nothing is stored. Password fields and keyboard keys are left out of the text before it is counted.

use crate::{
    ax,
    device::{Device, Failure, Pairing},
};
use serde_json::{Value, json};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    net::IpAddr,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant, SystemTime},
};

/// UIAccessibility's private secure text field trait (AXTraitSecureTextField in idb's AXTraits.h).
const SECURE_TRAIT: u64 = 1 << 24;
/// A key of the on-screen keyboard.
const KEY_TRAIT: u64 = 1 << 5;
/// UIAccessibilityTraitHeader.
const HEADER_TRAIT: u64 = 1 << 16;

const OPEN_WITHIN: Duration = Duration::from_secs(20);
/// Apps iOS keeps listing among those on screen while the phone is unlocked and something else is in
/// front (the Sleep screen, during and after Sleep Focus). History does not read a locked phone, so
/// their elements are never the screen the owner is looking at.
const LOCK_SCREEN_ONLY: [&str; 1] = ["com.apple.SleepLockScreen"];

fn lock_screen_only(app: &Value) -> bool {
    app["bundle_id"].as_str().is_some_and(|id| LOCK_SCREEN_ONLY.contains(&id))
}

/// One subscription of a run's read.
const DEFAULT_READ_WITHIN: Duration = Duration::from_secs(10);

/// The run in progress. A new run, or `cancel`, moves it on, and the older run ends at its next look.
static RUN: AtomicU64 = AtomicU64::new(0);
/// A run that has no tunnel yet tries again every second for its first forty: a run is started
/// (by the reconnect shortcut) in the few seconds in which a tunnel can be opened, and the proxy
/// app's own connection may come up only part way through them (phone log, 2026-11-19: "Network is
/// unreachable" every five seconds, then the loopback answered three seconds after the answer was
/// given). After that it tries once a round, so a refusing loopback is not hammered.
const EAGER: Duration = Duration::from_secs(40);
const EAGER_EVERY: Duration = Duration::from_secs(1);
/// Until when (milliseconds since 1970) a run with no tunnel tries five times a second. The app
/// sets it when the network changes and when the reconnect shortcut asks: the loopback takes a new
/// connection only in the short time around cellular going away or coming back, while the proxy
/// app's connection is still (or already) up (the owner's phone, 2026-11-19: with cellular off the
/// proxy's connection is dropped, so waiting there finds nothing).
static HURRY_UNTIL: AtomicU64 = AtomicU64::new(0);
const HURRY_EVERY: Duration = Duration::from_millis(200);
/// One try in a hurry gives up early, so a try that hangs does not use the whole moment up.
const HURRY_OPEN_WITHIN: Duration = Duration::from_secs(4);

fn now_ms() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Makes a run with no tunnel try fast for the coming seconds. A later call only ever extends it.
pub fn hurry(seconds: u32) {
    HURRY_UNTIL.fetch_max(now_ms() + u64::from(seconds.min(120)) * 1000, Ordering::SeqCst);
}

fn hurrying() -> bool {
    now_ms() < HURRY_UNTIL.load(Ordering::SeqCst)
}

/// The checks of the tunnel the app asked for: a count, doubled, plus one when a tunnel that
/// does not answer is to be given up at once. The run answers every new value with one line.
static CHECK: AtomicU64 = AtomicU64::new(0);

/// Asks the run to look at its tunnel now and say whether it still answers. With `replace` a
/// tunnel that does not answer is given up and a new one tried at once (the owner's reconnect);
/// without it the finding is only reported, because on cellular a tunnel given up by mistake
/// cannot be opened again. Returns the number the run's answer carries.
pub fn check(replace: bool) -> u64 {
    let mut next = 0;
    let _ = CHECK.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |old| {
        next = (((old >> 1) + 1) << 1) | u64::from(replace);
        Some(next)
    });
    next
}

/// How long the phone has to take a new stream inside the tunnel before the tunnel counts as gone.
const ALIVE_WITHIN: Duration = Duration::from_millis(1500);

/// Lockdown as the tunnel lists it. It takes any number of streams, so one more disturbs nothing.
const LOCKDOWN: &str = "com.apple.mobile.lockdown.remote.trusted";

/// Whether the tunnel still carries traffic: a new stream to lockdown (or, where the tunnel lists
/// none, to the accessibility service) is opened and dropped, and nothing is sent on it. Answers
/// with the milliseconds it took. A try that gets no answer is made again when `patient`, so a
/// busy moment is not taken for a lost tunnel; the owner's reconnect has no seconds to spend on it.
async fn alive(device: &mut Device, patient: bool) -> Result<u64, String> {
    let services = &device.rsd.services;
    let port = services.get(LOCKDOWN).or_else(|| services.get(ax::SERVICE)).map(|service| service.port).ok_or("the tunnel lists no service to ask")?;
    let asked = Instant::now();
    for attempt in 0..2 {
        match tokio::time::timeout(ALIVE_WITHIN, device.adapter.connect(port)).await {
            Ok(Ok(stream)) => {
                drop(stream);
                return Ok(milliseconds(asked.elapsed()));
            }
            Ok(Err(error)) => return Err(error.to_string()),
            Err(_) if attempt == 0 && patient => {}
            Err(_) => break,
        }
    }
    Err(format!("no answer in {} ms", milliseconds(asked.elapsed())))
}

/// The tries made since the run last had a tunnel.
#[derive(Default)]
struct Hunt {
    failed: u32,
    since: Option<Instant>,
}

/// Opens the run's tunnel, and says so in a line of its own: how long this try took, how many
/// tries it took and since when.
async fn open_tunnel(target: &Target, hunt: &mut Hunt, emit: &impl Fn(Value)) -> Result<Device, Failure> {
    let asked = Instant::now();
    let since = *hunt.since.get_or_insert(asked);
    match target.open().await {
        Ok(device) => {
            emit(json!({"event": "open", "ms": milliseconds(asked.elapsed()), "tries": hunt.failed + 1, "after_ms": milliseconds(since.elapsed())}));
            *hunt = Hunt::default();
            Ok(device)
        }
        Err(failure) => {
            hunt.failed += 1;
            Err(failure)
        }
    }
}

/// Answers a check the app asked for, if one waits. Returns whether the tunnel was given up.
async fn answer_check(checked: &mut u64, device: &mut Option<Device>, emit: &impl Fn(Value)) -> bool {
    let asked = CHECK.load(Ordering::SeqCst);
    if asked == *checked {
        return false;
    }
    *checked = asked;
    let mut line = json!({"check": asked});
    let mut given_up = false;
    match device.as_mut() {
        None => line["event"] = "none".into(),
        // Without `replace` the finding is only reported, and worth a second try.
        Some(open) => match alive(open, asked & 1 == 0).await {
            Ok(ms) => {
                line["event"] = "alive".into();
                line["ms"] = ms.into();
            }
            Err(error) => {
                line["event"] = "dead".into();
                line["error"] = error.into();
                if asked & 1 == 1 {
                    *device = None;
                    given_up = true;
                }
                line["given_up"] = given_up.into();
            }
        },
    }
    emit(line);
    given_up
}

/// What reading costs the phone, and how a run keeps it small (the owner, 2026-11-19 and again
/// 2026-11-20: Screen History visibly slowed the iPhone down, which is not acceptable):
/// - A round is a look: accessibility is asked for, one hit test says which app is in front, and
///   accessibility is given back. Between rounds nothing is asked of the phone at all. Until
///   2026-11-20 one subscription was kept for the whole run, which kept accessibility on in every
///   app all day, and a hit test was made every five seconds.
/// - The app's screen is read (a deep snapshot: the app walks its whole screen on its main
///   thread) only when the app is another than at the last read, or was last read a while ago:
///   twice the interval after a read that showed something new, doubling for each read that did
///   not, up to `IDLE_MAX`.
/// - A read may take the phone at most one part in `BUSY_SHARE` of the time: after a screen that
///   took long to read, the next read of that app waits that many times as long.
/// - An app whose screens are never kept (`Policy`) is not read at all.
/// - After the iPhone is unlocked or an agent's task ends, the first round waits `SETTLE`.
const IDLE_MAX: Duration = Duration::from_secs(240);
const BUSY_SHARE: u32 = 100;
const REREAD_MAX: Duration = Duration::from_secs(600);
const SETTLE: Duration = Duration::from_secs(10);
/// Rounds in a row that found the same app and read nothing, after which rounds come half as often.
const STEADY_AFTER: u32 = 4;
/// A subscription that is not answered in this time has failed.
const SUBSCRIBE_WITHIN: Duration = Duration::from_secs(6);
/// Subscriptions that failed in a row on a tunnel that still answers, after which the tunnel is
/// given up all the same: its list of services is from when it opened.
const SUBSCRIBE_TRIES: u32 = 3;

/// The wait after a read or a try that failed: it doubles from here up to `FAILING_MAX`, so a
/// connection that comes back is found again soon.
const RETRY: Duration = Duration::from_secs(5);
const FAILING_MAX: Duration = Duration::from_secs(30);

/// The wait after `slow` rounds in a row that brought nothing new.
fn paced(interval: Duration, slow: u32, max: Duration) -> Duration {
    interval.saturating_mul(1u32 << slow.min(5)).min(max.max(interval))
}

/// How long an app is left alone after its screen was read. `unchanged`: the reads in a row that
/// showed the same text. `cost`: the time the phone spent on the read.
fn reread_after(interval: Duration, new_app: bool, unchanged: u32, cost: Duration) -> Duration {
    let wait = if new_app { interval } else { paced(interval.saturating_mul(2), unchanged, IDLE_MAX) };
    wait.max(cost.saturating_mul(BUSY_SHARE)).min(REREAD_MAX.max(interval))
}

/// The wait between two rounds that found an app. `steady`: the rounds in a row that found the
/// same app as the round before and read nothing.
fn round_wait(interval: Duration, steady: u32) -> Duration {
    if steady >= STEADY_AFTER { interval.saturating_mul(2) } else { interval }
}

/// The apps whose screens are kept, as the app last said. A screen that would be thrown away is
/// not read: an app the owner left out is never made to walk its screen, and what it shows never
/// leaves it.
#[derive(Default, Clone, PartialEq, Debug)]
pub struct Policy {
    /// Bundle ids never kept, in lower case.
    skip: std::collections::HashSet<String>,
    /// When set, the only bundle ids kept.
    only: Option<std::collections::HashSet<String>>,
}

impl Policy {
    /// From `{"skip": [...], "only": [...]}`; a missing or null `only` means every app not skipped.
    pub fn from(lists: &Value) -> Self {
        let set = |list: &Value| list.as_array().map(|ids| ids.iter().filter_map(Value::as_str).map(|id| id.trim().to_ascii_lowercase()).filter(|id| !id.is_empty()).collect());
        Self { skip: set(&lists["skip"]).unwrap_or_default(), only: set(&lists["only"]) }
    }

    pub fn skips(&self, app: &str) -> bool {
        let app = app.trim().to_ascii_lowercase();
        self.skip.contains(&app) || self.only.as_ref().is_some_and(|only| !only.contains(&app))
    }
}

static POLICY: std::sync::Mutex<Option<Policy>> = std::sync::Mutex::new(None);

/// Sets which apps' screens the run reads, now and for the runs to come.
pub fn set_policy(lists: &Value) {
    *POLICY.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Policy::from(lists));
}

fn policy() -> Policy {
    POLICY.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone().unwrap_or_default()
}

/// What a round does with the app it found.
#[derive(Debug, PartialEq, Clone, Copy)]
enum Look {
    /// Its screen is read.
    Read,
    /// The same app as at the last read, read not long ago: left alone.
    Same,
    /// Its screens are never kept: not read.
    Skipped,
}

/// `app`: the bundle id the owner would name, when the phone told. `last`: the process read
/// last and how long ago. `reread`: how long that process is left alone.
fn decide(app: Option<&str>, pid: u64, policy: &Policy, last: Option<(u64, Duration)>, reread: Duration) -> Look {
    if app.is_some_and(|app| policy.skips(app)) {
        Look::Skipped
    } else if last.is_some_and(|(read, ago)| read == pid && ago < reread) {
        Look::Same
    } else {
        Look::Read
    }
}

/// How long a round waits before the next. With no tunnel it is short while one may come (the
/// app hurries, or the run is young), and otherwise grows with every try that failed: on cellular
/// iOS refuses every try until the network changes, and a change brings a hurry of its own.
fn wait_for(no_tunnel: bool, eager: bool, with_tunnel: Duration, failed: u32) -> Duration {
    if !no_tunnel {
        with_tunnel
    } else if hurrying() {
        HURRY_EVERY
    } else if eager {
        EAGER_EVERY
    } else {
        paced(RETRY, failed, FAILING_MAX)
    }
}

/// The least time from the start of one round to the start of the next, whatever the waits above
/// say. A try with no route fails within a millisecond, so a round that did not wait would spin
/// (build 61 did, during every hurry: thousands of tries and log lines a second).
const ROUND_MIN: Duration = Duration::from_millis(150);

/// The run reads nothing while this is set, and keeps its tunnel: on cellular a tunnel that was
/// closed cannot be opened again, so a wait (an agent's task) must not cost it.
static PAUSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Holds or lets go the reads of the run in progress. A new run starts unheld.
pub fn pause(on: bool) {
    PAUSED.store(on, Ordering::SeqCst);
}

/// Ends the background run, if one is going. It answers with what it measured so far.
pub fn cancel() {
    RUN.fetch_add(1, Ordering::SeqCst);
}

struct Target {
    address: IpAddr,
    pairing_file: PathBuf,
    host_name: Option<String>,
    /// The downloaded developer disk image. After a restart the phone has unmounted it, and the
    /// accessibility audit service goes with it: a tunnel that finds it missing mounts it again,
    /// so History does not wait for the owner to open Poki.
    ddi_dir: Option<String>,
}

/// Apple's signing server and a ~20 MB upload over the phone's own loopback.
const DDI_MOUNT_WITHIN: Duration = Duration::from_secs(120);

impl Target {
    fn from(request: &Value) -> Result<Self, Failure> {
        let address = request["device_address"].as_str().unwrap_or("10.7.0.1");
        let address = address.parse().map_err(|_| Failure::new(format!("{address} is not an address")).code("config"))?;
        let pairing_file = request["pairing_file"].as_str().ok_or_else(|| Failure::new("this iPhone is not paired yet").fix(crate::device::PAIRING_FIX).code("pairing"))?;
        Ok(Self {
            address,
            pairing_file: pairing_file.into(),
            host_name: request["host_name"].as_str().map(String::from),
            ddi_dir: request["ddi_dir"].as_str().filter(|d| !d.is_empty()).map(String::from),
        })
    }

    /// Mounts the image on a tunnel of its own, on a thread of its own: the mount's futures are
    /// not all provably Send, and history requests run on the multi-threaded runtime.
    async fn mount_on_own_thread(&self, dir: &str) -> Result<(), Failure> {
        let (address, pairing_file, host_name, dir) = (self.address, self.pairing_file.clone(), self.host_name.clone(), dir.to_string());
        let (tx, rx) = tokio::sync::oneshot::channel();
        std::thread::Builder::new()
            .name("poki-history-ddi".into())
            .stack_size(8 << 20)
            .spawn(move || {
                let answer = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                    Ok(runtime) => runtime.block_on(async move {
                        let mut pairing = Pairing::read(&pairing_file, host_name.as_deref())?;
                        let mut device = Device::open(address, &mut pairing, OPEN_WITHIN).await?;
                        match tokio::time::timeout(DDI_MOUNT_WITHIN, crate::ddi::mount(&mut device, &dir)).await {
                            Ok(result) => result,
                            Err(_) => Err(Failure::new(format!("mounting the developer disk image took over {} s", DDI_MOUNT_WITHIN.as_secs())).fix(crate::device::DDI_TIMEOUT_FIX).code("ddi_timeout")),
                        }
                    }),
                    Err(e) => Err(Failure::new(format!("could not start the disk image mount: {e}"))),
                };
                let _ = tx.send(answer);
            })
            .map_err(|e| Failure::new(format!("could not start the disk image mount: {e}")))?;
        rx.await.map_err(|_| Failure::new("the disk image mount ended without an answer"))?
    }

    /// One try at the tunnel. It has 20 s, and only 4 s once the app hurries: a try that began
    /// before the network changed and hangs must not use up the moment a new one could work in.
    async fn open_once(&self, pairing: &mut Pairing) -> Result<Device, Failure> {
        let started = Instant::now();
        let open = Device::open(self.address, pairing, OPEN_WITHIN);
        tokio::pin!(open);
        loop {
            tokio::select! {
                result = &mut open => return result,
                _ = tokio::time::sleep(Duration::from_millis(100)) => {
                    if hurrying() && started.elapsed() >= HURRY_OPEN_WITHIN {
                        return Err(Failure::new(format!("the phone's developer services did not answer within {} s", HURRY_OPEN_WITHIN.as_secs())).fix(crate::device::LOOPBACK_FIX).code("loopback"));
                    }
                }
            }
        }
    }

    async fn open(&self) -> Result<Device, Failure> {
        let mut pairing = Pairing::read(&self.pairing_file, self.host_name.as_deref())?;
        let mut device = self.open_once(&mut pairing).await?;
        if !crate::ddi::mounted(&device) {
            if let Some(dir) = self.ddi_dir.as_deref().filter(|d| crate::ddi::files_present(d)) {
                // A failure here may only mean the supervisor mounted it meanwhile: the new tunnel tells.
                drop(device);
                let failed = self.mount_on_own_thread(dir).await.err();
                // The services list was fixed when the tunnel opened; a new one shows the image.
                let mut tries = 0;
                loop {
                    device = Device::open(self.address, &mut pairing, OPEN_WITHIN).await?;
                    if crate::ddi::mounted(&device) { break; }
                    if tries >= 3 {
                        return Err(failed.unwrap_or_else(|| Failure::new("the developer disk image was installed but its services did not appear").fix("Restart the phone, then open Poki again.")));
                    }
                    tries += 1;
                    drop(device);
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
        if !device.rsd.services.contains_key(ax::SERVICE) {
            return Err(Failure::new("this iPhone does not list the accessibility audit service")
                .fix("The service comes with the developer disk image. Open Setup and wait until the image is ready, then try again.")
                .code("no_service"));
        }
        Ok(device)
    }
}

fn milliseconds(duration: Duration) -> u64 {
    duration.as_millis() as u64
}

/// No subscription gave a tree: the last one's own error, or what it counted.
fn no_tree(attempts: &[ax::Attempt]) -> Failure {
    let detail = match attempts.last() {
        Some(last) => match &last.error {
            Some(error) => error.clone(),
            None => format!("no tree in {} subscriptions; the last got {} messages, {} dumps, {} roots, {} nodes", attempts.len(), last.messages, last.dumps, last.roots, last.nodes),
        },
        None => "no subscription was made".into(),
    };
    Failure::new(detail).code("read")
}

/// Runs one request. `emit` gets a line for every read of a run.
pub async fn handle(request: Value, emit: impl Fn(Value) + Send + Sync + 'static) -> Result<Value, Failure> {
    match request["op"].as_str().unwrap_or("") {
        "read_once" => read_once(&request).await,
        "watch" => watch(&request).await,
        "run" => run(&request, emit).await,
        other => Err(Failure::new(format!("unknown history request \"{other}\"")).code("config")),
    }
}

/// The waits of one read's subscriptions. The reader on a computer gives each subscription two
/// seconds and then makes a new one. On the phone itself, with no automation session, accessibility
/// may first have to start, so a short wait is tried twice and then a long one.
const READ_WINDOWS: [Duration; 3] = [Duration::from_secs(2), Duration::from_secs(2), Duration::from_secs(15)];

fn windows(request: &Value) -> Vec<Duration> {
    match request["windows_ms"].as_array() {
        Some(list) if !list.is_empty() => list.iter().filter_map(Value::as_u64).map(|ms| Duration::from_millis(ms.clamp(200, 60_000))).take(8).collect(),
        _ => READ_WINDOWS.to_vec(),
    }
}

/// The accessibility services this iPhone lists, for a read that got no tree.
fn accessibility_services(device: &Device) -> Vec<&String> {
    let mut names: Vec<&String> = device.rsd.services.keys().filter(|name| name.to_lowercase().contains("accessib") || name.contains("axAudit")).collect();
    names.sort();
    names
}

async fn read_once(request: &Value) -> Result<Value, Failure> {
    let target = Target::from(request)?;
    let windows = windows(request);
    let include_text = request["include_text"].as_bool().unwrap_or(false);
    let asked = Instant::now();
    let mut device = target.open().await?;
    let connect_ms = milliseconds(asked.elapsed());
    let asked = Instant::now();
    let (tree, attempts) = ax::read_tree_traced(&mut device.adapter, &device.rsd, false, &windows).await;
    let read_ms = milliseconds(asked.elapsed());
    let Some(tree) = tree else {
        // Not a failure of the request: what the phone did send is the answer the test is for.
        return Ok(json!({"tree": false, "connect_ms": connect_ms, "read_ms": read_ms, "attempts": attempts, "services": accessibility_services(&device)}));
    };
    // A second read on the open tunnel: what a read costs once the connection is up, as a loop pays.
    let asked = Instant::now();
    let (again, second) = ax::read_tree_traced(&mut device.adapter, &device.rsd, false, &windows).await;
    let again_ms = again.is_some().then(|| milliseconds(asked.elapsed()));
    let mut answer = summarize(&tree, include_text);
    answer["tree"] = true.into();
    answer["connect_ms"] = connect_ms.into();
    answer["read_ms"] = read_ms.into();
    answer["second_read_ms"] = json!(again_ms);
    answer["attempts"] = json!(attempts);
    answer["second_attempts"] = json!(second);
    Ok(answer)
}

/// One subscription kept open for `seconds`, whatever arrives: the answer is how the tree grew.
async fn watch(request: &Value) -> Result<Value, Failure> {
    let target = Target::from(request)?;
    let seconds = request["seconds"].as_u64().unwrap_or(30).clamp(2, 300);
    let asked = Instant::now();
    let mut device = target.open().await?;
    let connect_ms = milliseconds(asked.elapsed());
    let (tree, attempts) = ax::read_tree_held(&mut device.adapter, &device.rsd, false, &[Duration::from_secs(seconds)], true).await;
    let mut answer = match tree {
        Some(tree) => summarize(&tree, false),
        None => json!({}),
    };
    answer["tree"] = answer.get("elements").is_some().into();
    answer["connect_ms"] = connect_ms.into();
    answer["attempts"] = json!(attempts);
    answer["services"] = json!(accessibility_services(&device));
    Ok(answer)
}

/// What one round of a run did.
enum Round {
    /// Nothing was asked of the phone: the run was held or stopped while the round waited.
    Held,
    /// The app in front was found. `seen` is missing for a read of the service's own dump.
    Looked { seen: Option<ax::direct::Seen>, look: Look, tree: Option<Value> },
}

async fn run(request: &Value, emit: impl Fn(Value)) -> Result<Value, Failure> {
    let target = Target::from(request)?;
    let interval = Duration::from_millis(request["interval_ms"].as_u64().unwrap_or(30_000).clamp(1000, 600_000));
    let duration = Duration::from_secs(request["duration_s"].as_u64().unwrap_or(1800).clamp(10, 86_400));
    let windows = match request["windows_ms"].as_array() {
        Some(_) => windows(request),
        None => vec![DEFAULT_READ_WITHIN],
    };
    let me = RUN.fetch_add(1, Ordering::SeqCst) + 1;
    // A run may start held (the iPhone is locked, or an agent's task has the screen): it opens its
    // tunnel and reads nothing until it is let go.
    PAUSED.store(request["paused"].as_bool().unwrap_or(false), Ordering::SeqCst);
    let mut stats = RunStats::default();
    let mut device: Option<Device> = None;
    // Wall time, not the runtime's clock: a suspended app's time must show up as a gap.
    let started = SystemTime::now();
    let since_start = || SystemTime::now().duration_since(started).unwrap_or_default();
    let mut last_good: Option<Duration> = None;
    let mut last_text: Option<u64> = None;
    let points: Option<Vec<(f64, f64)>> = request["direct_points"].as_array().map(|points| points.iter().filter_map(|point| Some((point[0].as_f64()?, point[1].as_f64()?))).collect());
    let include_text = request["include_text"].as_bool().unwrap_or(false);
    let include_tree = request["include_tree"].as_bool().unwrap_or(false);
    let mut ended = "finished";
    // What the run knows of the processes it met. It outlives the subscriptions, one per round.
    let mut known = ax::direct::Known::default();
    // The process whose screen was read last and the round that read it, how long that process
    // is left alone, and the reads in a row that showed the same text.
    let mut last_read: Option<(u64, Instant)> = None;
    let mut reread = Duration::ZERO;
    let mut unchanged = 0u32;
    // The process the round before found, and the rounds in a row that found it again and read nothing.
    let mut last_pid: Option<u64> = None;
    let mut steady = 0u32;
    // Rounds in a row that failed or had no tunnel, rounds in a row that found no app on the
    // screen, and subscriptions in a row that failed.
    let mut failing = 0u32;
    let mut idle = 0u32;
    let mut unsubscribed = 0u32;
    // Until when the first look after a hold waits.
    let mut settle: Option<Instant> = None;
    // The tries since the run last had a tunnel, and the last check of the app's that was answered.
    // A check asked as the run was started is answered by its first round (it has no tunnel yet).
    let mut hunt = Hunt::default();
    let mut checked = 0;
    let mut round: Option<Instant> = None;
    loop {
        // No round starts sooner than ROUND_MIN after the one before, whatever ended its wait.
        if let Some(last) = round {
            while last.elapsed() < ROUND_MIN && RUN.load(Ordering::SeqCst) == me {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        }
        if RUN.load(Ordering::SeqCst) != me {
            ended = "stopped";
            break;
        }
        let at = since_start();
        if at >= duration {
            break;
        }
        let asked = Instant::now();
        round = Some(asked);
        answer_check(&mut checked, &mut device, &emit).await;
        if PAUSED.load(Ordering::SeqCst) {
            // A held run still opens its tunnel: the moment it can be opened may not come again
            // (on cellular iOS refuses a new one), and the reads to come need it open. Nothing
            // else is asked of the phone: no subscription is kept through a hold.
            let mut line = json!({"paused": true, "at_s": at.as_secs()});
            if device.is_none() {
                match open_tunnel(&target, &mut hunt, &emit).await {
                    Ok(open) => {
                        device = Some(open);
                        stats.connections += 1;
                        failing = 0;
                    }
                    Err(failure) => {
                        line["error"] = failure.detail.into();
                        failing += 1;
                    }
                }
            }
            line["tunnel"] = device.is_some().into();
            // One line each round, so the caller can tell a held run from a silent one.
            emit(line);
            // Asked again each piece, so a hurry that begins during a long wait cuts it short.
            while asked.elapsed() < wait_for(device.is_none(), since_start() < EAGER, interval, failing) && RUN.load(Ordering::SeqCst) == me && PAUSED.load(Ordering::SeqCst) {
                // A check is answered where the run waits; a tunnel given up is tried again now.
                if answer_check(&mut checked, &mut device, &emit).await {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            // Let go: the screen has just come back (the owner unlocked the iPhone, or an agent's
            // task ended). The first look waits, so it does not land in what the owner is doing.
            if !PAUSED.load(Ordering::SeqCst) {
                settle = Some(Instant::now() + SETTLE);
            }
            continue;
        }
        let mut line = json!({"n": stats.reads + stats.looks + stats.failures + 1, "at_s": at.as_secs()});
        let mut trace = ax::direct::Trace::default();
        let result = async {
            if device.is_none() {
                device = Some(open_tunnel(&target, &mut hunt, &emit).await?);
                stats.connections += 1;
            }
            // The tunnel is opened first, whatever else waits: the moment for it may be short.
            if let Some(until) = settle.take() {
                while Instant::now() < until && RUN.load(Ordering::SeqCst) == me && !PAUSED.load(Ordering::SeqCst) {
                    answer_check(&mut checked, &mut device, &emit).await;
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                if RUN.load(Ordering::SeqCst) != me || PAUSED.load(Ordering::SeqCst) || device.is_none() {
                    return Ok(Round::Held);
                }
            }
            let open = device.as_mut().unwrap();
            let Some(points) = &points else {
                let (tree, attempts) = ax::read_tree_traced(&mut open.adapter, &open.rsd, false, &windows).await;
                return tree.map(|tree| Round::Looked { seen: None, look: Look::Read, tree: Some(tree) }).ok_or_else(|| no_tree(&attempts));
            };
            // With points to hit test, the app is found the way the screen shows it; the service's
            // own dump can name the wrong app. Accessibility is asked for now and given back
            // below, whatever the round brings: while a client needs it, it is on in every app.
            trace.stage = "subscribe";
            let subscribing = Instant::now();
            let mut direct = match tokio::time::timeout(SUBSCRIBE_WITHIN, ax::direct::Direct::connect(&mut open.adapter, &open.rsd)).await {
                Ok(Ok(direct)) => direct,
                Ok(Err(error)) => return Err(Failure::new(format!("no tree at subscribe: {error}")).code("read")),
                Err(_) => return Err(Failure::new(format!("no tree at subscribe: no answer in {} s", SUBSCRIBE_WITHIN.as_secs())).code("read")),
            };
            trace.subscribe_ms = milliseconds(subscribing.elapsed());
            let looked = async {
                let seen = direct.see(points, &mut trace, &mut known).await?;
                let look = decide(seen.app(), seen.pid, &policy(), last_read.map(|(pid, read)| (pid, asked.saturating_duration_since(read))), reread);
                let tree = match look {
                    Look::Read => Some(direct.read(&seen, points, &mut trace, &mut known).await?),
                    Look::Same | Look::Skipped => None,
                };
                Ok::<_, Box<dyn std::error::Error + Send + Sync>>(Round::Looked { seen: Some(seen), look, tree })
            }
            .await;
            let _ = tokio::time::timeout(Duration::from_secs(1), direct.close()).await;
            looked.map_err(|error| Failure::new(format!("no tree at {}: {error}", trace.stage)).code("read"))
        }
        .await;
        let took = milliseconds(asked.elapsed());
        // The wait until the next round, while the run has a tunnel.
        let with_tunnel;
        match result {
            Ok(Round::Held) => continue,
            Ok(Round::Looked { seen, mut look, tree }) => {
                failing = 0;
                idle = 0;
                unsubscribed = 0;
                let pid = seen.as_ref().map(|seen| seen.pid);
                let now = since_start();
                let gap = now.saturating_sub(last_good.unwrap_or(now));
                last_good = Some(now);
                line["ok"] = true.into();
                line["ms"] = took.into();
                // What the round asked of the phone, for the app's tally of what reading costs.
                line["subscribe_ms"] = trace.subscribe_ms.into();
                line["cost_ms"] = trace.asked_ms.into();
                let mut app = seen.as_ref().and_then(|seen| seen.bundle.clone()).map(Value::from).map(|id| bundle_name(&id)).unwrap_or(Value::Null);
                let mut host = seen.as_ref().and_then(|seen| seen.host.clone()).map(Value::from).map(|id| bundle_name(&id)).unwrap_or(Value::Null);
                let mut kept = None;
                if let Some(tree) = tree {
                    let summary = summarize(&tree, true);
                    app = front_name(&summary);
                    // The app that shows a web page, when the page's own process was the one read.
                    if !bundle_name(&tree["host"]["bundle_id"]).is_null() {
                        host = bundle_name(&tree["host"]["bundle_id"]);
                    }
                    // An app the phone named only with its screen: one that is left out is
                    // dropped here, and its text goes no further.
                    let named = match (app.as_str(), host.as_str()) {
                        (_, Some(host)) => Some(host),
                        (Some(app), None) if !ax::direct::is_web(app) => Some(app),
                        _ => None,
                    };
                    if named.is_some_and(|named| policy().skips(named)) {
                        look = Look::Skipped;
                    } else {
                        kept = Some((tree, summary));
                    }
                    line["snapshot_ms"] = json!(trace.snapshot_ms);
                    line["bytes"] = json!(trace.snapshot_bytes);
                    // Read once, whatever becomes of it: the process is left alone for a while.
                    let cost = if points.is_some() { Duration::from_millis(trace.asked_ms) } else { Duration::from_millis(took) };
                    let new_app = pid.is_none() || last_read.map(|(read, _)| read) != pid;
                    if let Some((_, summary)) = &kept {
                        let text = hash_of(&summary["text"]);
                        let changed = last_text != Some(text);
                        last_text = Some(text);
                        unchanged = if changed { 0 } else { unchanged + 1 };
                        line["changed"] = changed.into();
                    }
                    reread = reread_after(interval, new_app && kept.is_some(), unchanged, cost);
                    last_read = pid.map(|pid| (pid, asked));
                }
                if !app.is_null() {
                    line["app"] = app;
                }
                if !host.is_null() {
                    line["host"] = host;
                }
                match kept {
                    Some((tree, summary)) => {
                        let changed = line["changed"] == true;
                        stats.good(took, gap, changed);
                        steady = 0;
                        line["elements"] = summary["elements"].clone();
                        // The capture loop asks for the text itself, and gets it only for a screen that changed.
                        if include_text && changed {
                            line["text"] = summary["text"].clone();
                            line["title"] = title_of(&tree);
                        }
                        // The tree itself, compact, when the capture keeps trees: only for a changed screen.
                        if include_tree && changed {
                            line["tree"] = compact(&tree);
                        }
                    }
                    None => {
                        // A look that read no screen: the app is the one read not long ago, or
                        // one whose screens are never kept.
                        stats.looked(gap);
                        steady = if pid.is_some() && pid == last_pid { steady + 1 } else { 0 };
                        line["look"] = if look == Look::Skipped { "skipped" } else { "same" }.into();
                        line["changed"] = false.into();
                    }
                }
                last_pid = pid;
                with_tunnel = round_wait(interval, steady);
            }
            Err(failure) => {
                // A screen that shows no app (locked or off) is an answer, and the tunnel stays.
                let no_app = failure.detail.contains("no point of the screen") && !failure.detail.contains(ax::direct::HITS_FAILED);
                steady = 0;
                last_pid = None;
                if no_app {
                    idle += 1;
                    unsubscribed = 0;
                    with_tunnel = paced(interval, idle, IDLE_MAX);
                } else {
                    failing += 1;
                    with_tunnel = paced(RETRY, failing, FAILING_MAX);
                    if device.is_some() && points.is_none() {
                        // The service's own dump did not come: the next read opens a new tunnel.
                        device = None;
                        emit(json!({"event": "lost", "error": failure.detail}));
                    } else if device.is_some() && trace.stage == "subscribe" {
                        // A subscription that fails may be a tunnel that is gone. The tunnel is
                        // asked itself: on cellular one given up by mistake cannot be opened
                        // again. One that answers stays, until the service has failed on it
                        // several times over (its list of services is from when it opened).
                        unsubscribed += 1;
                        let gone = alive(device.as_mut().unwrap(), true).await.is_err();
                        if gone || unsubscribed >= SUBSCRIBE_TRIES {
                            unsubscribed = 0;
                            device = None;
                            emit(json!({"event": "lost", "error": failure.detail}));
                        }
                    } else {
                        // The subscription answered, so the tunnel is alive: it stays.
                        unsubscribed = 0;
                    }
                }
                stats.failures += 1;
                stats.last_error = Some(failure.detail.clone());
                line["ok"] = false.into();
                line["ms"] = took.into();
                line["error"] = failure.detail.into();
                line["code"] = json!(failure.code);
                // Whether the run has a tunnel after this failure: without one it was the tunnel
                // that could not be opened, not the screen that could not be read.
                line["tunnel"] = device.is_some().into();
            }
        }
        emit(line);
        // Waits in short pieces, so Stop is answered at once. The wait is asked again each piece:
        // with no tunnel it turns short the moment a hurry begins, and stays 200 ms during one.
        // Nothing is asked of the phone while the run waits.
        while RUN.load(Ordering::SeqCst) == me && !PAUSED.load(Ordering::SeqCst) {
            if asked.elapsed() >= wait_for(device.is_none(), since_start() < EAGER, with_tunnel, failing) {
                break;
            }
            // A check is answered where the run waits; a tunnel given up is tried again now.
            if answer_check(&mut checked, &mut device, &emit).await {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
    let mut answer = stats.json();
    answer["ended"] = ended.into();
    answer["ran_s"] = since_start().as_secs().into();
    answer["interval_ms"] = milliseconds(interval).into();
    // The time since the last read counts too: a run that stopped reading ends with a long gap.
    if let Some(last) = last_good {
        let tail = milliseconds(since_start().saturating_sub(last));
        if tail > answer["longest_gap_ms"].as_u64().unwrap_or(0) {
            answer["longest_gap_ms"] = tail.into();
        }
    }
    Ok(answer)
}

#[derive(Default)]
pub(crate) struct RunStats {
    pub reads: u64,
    /// Rounds that found the app in front and read no screen.
    pub looks: u64,
    pub failures: u64,
    pub changed: u64,
    pub connections: u64,
    pub longest_gap_ms: u64,
    pub total_ms: u64,
    pub slowest_ms: u64,
    pub last_error: Option<String>,
}

impl RunStats {
    pub(crate) fn good(&mut self, took_ms: u64, gap: Duration, changed: bool) {
        self.reads += 1;
        self.total_ms += took_ms;
        self.slowest_ms = self.slowest_ms.max(took_ms);
        self.longest_gap_ms = self.longest_gap_ms.max(milliseconds(gap));
        if changed {
            self.changed += 1;
        }
    }

    pub(crate) fn looked(&mut self, gap: Duration) {
        self.looks += 1;
        self.longest_gap_ms = self.longest_gap_ms.max(milliseconds(gap));
    }

    pub(crate) fn json(&self) -> Value {
        json!({
            "reads": self.reads,
            "looks": self.looks,
            "failures": self.failures,
            "changed": self.changed,
            "connections": self.connections,
            "longest_gap_ms": self.longest_gap_ms,
            "average_ms": if self.reads == 0 { 0 } else { self.total_ms / self.reads },
            "slowest_ms": self.slowest_ms,
            "last_error": self.last_error,
        })
    }
}

fn hash_of(value: &Value) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.to_string().hash(&mut hasher);
    hasher.finish()
}

fn front_name(summary: &Value) -> Value {
    let app = if summary["front"].is_object() { &summary["front"] } else { &summary["applications"][0] };
    bundle_name(&app["bundle_id"])
}

/// A bundle id as the capture takes it, or null for anything that is not one.
fn bundle_name(id: &Value) -> Value {
    id.as_str()
        .filter(|id| {
            id.contains('.') && id.split('.').all(|part| !part.is_empty() && part.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-'))
        })
        .map(Value::from)
        .unwrap_or(Value::Null)
}

/// The screen's title: its first heading that is not a password field.
fn title_of(tree: &Value) -> Value {
    let empty = vec![];
    tree["elements"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter(|element| element["traits"].as_u64().unwrap_or(0) & HEADER_TRAIT != 0 && !is_secure(element))
        .find_map(|element| element["label"].as_str().map(str::trim).filter(|label| !label.is_empty()))
        .map(Value::from)
        .unwrap_or(Value::Null)
}

/// Words that name a secret, in an element's label or identifier.
const SECRET_NAMES: [&str; 8] = ["password", "passcode", "verification code", "one-time code", "密码", "密碼", "验证码", "驗證碼"];

/// A password field, by its role or trait, or any element with a value whose name says it holds a
/// secret. A direct read carries no element type, and a web page's password field or a password
/// shown in clear may not set the trait, so the name is checked too.
fn is_secure(element: &Value) -> bool {
    if element["role"] == "SecureTextField" || element["traits"].as_u64().unwrap_or(0) & SECURE_TRAIT != 0 {
        return true;
    }
    let has_value = element["value"].as_str().is_some_and(|value| !value.trim().is_empty());
    has_value
        && ["label", "identifier"].iter().any(|field| {
            let name = element[*field].as_str().unwrap_or("").to_lowercase();
            SECRET_NAMES.iter().any(|secret| name.contains(secret))
        })
}

fn is_key(element: &Value) -> bool {
    element["role"] == "Key" || element["traits"].as_u64().unwrap_or(0) & KEY_TRAIT != 0
}

/// What a read holds, without the tree itself: the apps on screen, the one in front when the tree
/// names a single app, the number of elements, and the screen's text in reading order. Password
/// fields and keyboard keys give no text. The text is returned only when asked for.
pub fn summarize(tree: &Value, include_text: bool) -> Value {
    let empty = vec![];
    let all = tree["elements"].as_array().unwrap_or(&empty);
    // Elements come in reading order with their depth, so an app's own elements follow it, deeper.
    let mut elements: Vec<&Value> = vec![];
    let mut hidden_below: Option<u64> = None;
    for element in all {
        let depth = element["depth"].as_u64().unwrap_or(0);
        if hidden_below.is_some_and(|below| depth > below) {
            continue;
        }
        hidden_below = (element["role"] == "Application" && lock_screen_only(element)).then_some(depth);
        if hidden_below.is_none() {
            elements.push(element);
        }
    }
    let mut lines: Vec<String> = vec![];
    let mut secure = 0;
    for element in &elements {
        if is_secure(element) {
            secure += 1;
            continue;
        }
        if is_key(element) || element["role"] == "Application" {
            continue;
        }
        for field in ["label", "value"] {
            let Some(text) = element[field].as_str().map(str::trim).filter(|text| !text.is_empty()) else { continue };
            if lines.last().map(String::as_str) != Some(text) {
                lines.push(text.to_string());
            }
        }
    }
    let applications: Vec<Value> = tree["applications"]
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter(|app| !lock_screen_only(app))
        .map(|app| json!({"name": app["name"], "bundle_id": app["bundle_id"], "pid": app["pid"]}))
        .collect();
    // In front: the one app left on screen once the lock screen's own are set aside.
    let front = match applications.as_slice() {
        [app] => app.clone(),
        _ => Value::Null,
    };
    let mut answer = json!({
        "elements": elements.len(),
        "applications": applications,
        "front": front,
        "text_lines": lines.len(),
        "text_characters": lines.iter().map(|line| line.chars().count()).sum::<usize>(),
        "secure_fields_left_out": secure,
    });
    if include_text {
        answer["text"] = json!(lines);
    }
    answer
}

/// The tree as the capture keeps it: one row per element in reading order,
/// `[depth, role, label, value, x, y, width, height]`, numbers rounded to whole points. What
/// `summarize` leaves out is left out here too: elements under an app that only the lock screen
/// shows, keyboard keys, and the value of a password field (its row stays, without label or value).
pub fn compact(tree: &Value) -> Value {
    let empty = vec![];
    let all = tree["elements"].as_array().unwrap_or(&empty);
    let mut rows: Vec<Value> = vec![];
    let mut hidden_below: Option<u64> = None;
    for element in all {
        let depth = element["depth"].as_u64().unwrap_or(0);
        if hidden_below.is_some_and(|below| depth > below) {
            continue;
        }
        hidden_below = (element["role"] == "Application" && lock_screen_only(element)).then_some(depth);
        if hidden_below.is_some() || is_key(element) {
            continue;
        }
        let secure = is_secure(element);
        let text = |field: &str| if secure { "" } else { element[field].as_str().map(str::trim).unwrap_or("") };
        let number = |field: &str| element["frame"][field].as_f64().map(|n| n.round() as i64).unwrap_or(0);
        rows.push(json!([
            depth,
            element["role"].as_str().unwrap_or(""),
            text("label"),
            text("value"),
            number("x"),
            number("y"),
            number("width"),
            number("height"),
        ]));
    }
    Value::Array(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree() -> Value {
        json!({
            "source": "accessibility",
            "applications": [{"object_id": "o1", "name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412}],
            "foreground_app": {"object_id": "o1", "name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412},
            "elements": [
                {"role": "Application", "label": "Notes"},
                {"role": "StaticText", "label": "Shopping list", "traits": 1u64 << 16},
                {"role": "TextView", "label": "Note", "value": "Milk\nEggs"},
                {"role": "StaticText", "label": "Shopping list"},
                {"role": "StaticText", "label": "Shopping list"},
                {"role": "SecureTextField", "label": "Password", "value": "hunter2"},
                {"role": "TextField", "label": "Passcode", "value": "1234", "traits": SECURE_TRAIT},
                {"role": "Key", "label": "q"},
                {"role": "Other", "label": "w", "traits": KEY_TRAIT},
                {"role": "Button", "label": "  "},
                {"role": "Button", "label": "Done"},
            ],
        })
    }

    #[test]
    fn a_compact_tree_keeps_structure_and_leaves_out_secrets_and_keys() {
        let rows = compact(&tree());
        let rows = rows.as_array().unwrap();
        // Eleven elements, less the two keyboard keys.
        assert_eq!(rows.len(), 9);
        assert_eq!(rows[2], json!([0, "TextView", "Note", "Milk\nEggs", 0, 0, 0, 0]));
        assert_eq!(rows[5], json!([0, "SecureTextField", "", "", 0, 0, 0, 0]));
        assert_eq!(rows[6], json!([0, "TextField", "", "", 0, 0, 0, 0]));
        assert!(!rows.iter().any(|row| row[3] == "hunter2" || row[3] == "1234"));
    }

    #[test]
    fn a_summary_counts_the_screen_and_keeps_the_text_out_unless_asked() {
        let summary = summarize(&tree(), false);
        assert_eq!(summary["elements"], 11);
        assert_eq!(summary["front"]["bundle_id"], "com.apple.mobilenotes");
        assert_eq!(summary["applications"].as_array().unwrap().len(), 1);
        assert!(summary.get("text").is_none());
        assert_eq!(summary["text_lines"], 5);
    }

    #[test]
    fn a_value_named_as_a_secret_gives_no_text_without_the_password_trait() {
        let tree = json!({"elements": [
            {"role": "Other", "label": "Verification Code", "value": "482913"},
            {"label": "密码", "value": "s3cret"},
            {"role": "StaticText", "label": "Password"},
        ]});
        let summary = summarize(&tree, true);
        assert_eq!(summary["text"], json!(["Password"]));
        assert_eq!(summary["secure_fields_left_out"], 2);
        let rows = compact(&tree).to_string();
        assert!(!rows.contains("482913") && !rows.contains("s3cret"));
    }

    #[test]
    fn password_fields_and_keyboard_keys_give_no_text() {
        let summary = summarize(&tree(), true);
        let text: Vec<&str> = summary["text"].as_array().unwrap().iter().map(|line| line.as_str().unwrap()).collect();
        assert_eq!(text, ["Shopping list", "Note", "Milk\nEggs", "Shopping list", "Done"]);
        assert_eq!(summary["secure_fields_left_out"], 2);
        let all = summary.to_string();
        assert!(!all.contains("hunter2") && !all.contains("1234"));
    }

    #[test]
    fn an_app_identity_never_falls_back_to_a_display_name_or_pid() {
        for app in [
            json!({"name": "com.example.bank", "pid": 412}),
            json!({"pid": 412}),
            json!({"bundle_id": "", "name": "Notes"}),
            json!({"bundle_id": "Notes"}),
            json!({"bundle_id": "no app name, pid 412"}),
            json!({"bundle_id": "com.example bank"}),
            json!({"bundle_id": "com..bank"}),
            json!({"bundle_id": ".com.bank"}),
            json!({"bundle_id": "com.bank."}),
            json!({"bundle_id": "com.bank/app"}),
            json!({"bundle_id": "com.b\u{e4}nk"}),
        ] {
            for summary in [json!({"front": app}), json!({"applications": [app]})] {
                assert_eq!(front_name(&summary), Value::Null, "{summary}");
            }
        }
        assert_eq!(front_name(&json!({"front": {"bundle_id": "com.example.Bank-2"}})), "com.example.Bank-2");
        assert_eq!(bundle_name(&json!("com.apple.mobilesafari")), "com.apple.mobilesafari");
        assert!(bundle_name(&json!("WidgetRenderer_Default")).is_null());
        assert!(bundle_name(&Value::Null).is_null());
        assert!(crate::ax::direct::is_web("com.apple.WebKit.WebContent"));
        assert!(!crate::ax::direct::is_web("com.apple.mobilesafari"));
    }

    #[test]
    fn several_apps_on_screen_leave_the_front_one_unnamed() {
        let mut tree = tree();
        tree["foreground_app"] = Value::Null;
        tree["applications"] = json!([{"name": "SpringBoard", "bundle_id": "com.apple.springboard", "pid": 60}, {"name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412}]);
        let summary = summarize(&tree, false);
        assert!(summary["front"].is_null());
        assert_eq!(front_name(&summary), "com.apple.springboard");
    }

    #[test]
    fn the_sleep_screen_behind_an_app_is_not_part_of_the_screen() {
        let tree = json!({
            "applications": [{"name": "Sleep", "bundle_id": "com.apple.SleepLockScreen", "pid": 90}, {"name": "Notes", "bundle_id": "com.apple.mobilenotes", "pid": 412}],
            "foreground_app": null,
            "elements": [
                {"role": "Application", "label": "Sleep", "bundle_id": "com.apple.SleepLockScreen", "depth": 0},
                {"role": "StaticText", "label": "Good night", "depth": 1},
                {"role": "Button", "label": "Dismiss", "depth": 2},
                {"role": "Application", "label": "Notes", "bundle_id": "com.apple.mobilenotes", "depth": 0},
                {"role": "StaticText", "label": "Shopping list", "depth": 1},
            ],
        });
        let summary = summarize(&tree, true);
        assert_eq!(summary["elements"], 2);
        assert_eq!(summary["text"], json!(["Shopping list"]));
        assert_eq!(summary["front"]["bundle_id"], "com.apple.mobilenotes");
        assert_eq!(summary["applications"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn an_empty_or_unexpected_tree_is_an_empty_summary() {
        let summary = summarize(&json!({}), true);
        assert_eq!(summary["elements"], 0);
        assert_eq!(summary["text_lines"], 0);
        assert!(front_name(&summary).is_null());
    }

    #[test]
    fn a_read_without_a_tree_says_what_the_last_subscription_got() {
        let quiet = ax::Attempt { messages: 2, ..Default::default() };
        assert!(no_tree(&[quiet.clone(), quiet]).detail.contains("no tree in 2 subscriptions; the last got 2 messages"));
        let broken = ax::Attempt { error: Some("connection reset".into()), ..Default::default() };
        assert_eq!(no_tree(&[broken]).detail, "connection reset");
        assert_eq!(windows(&json!({})), READ_WINDOWS.to_vec());
        assert_eq!(windows(&json!({"windows_ms": [50, 3000]})), [Duration::from_millis(200), Duration::from_secs(3)]);
        let line = serde_json::to_value(ax::Attempt::default()).unwrap();
        assert_eq!(line["answered"], false);
    }

    #[test]
    fn the_title_is_the_first_heading() {
        assert_eq!(title_of(&tree()), "Shopping list");
        assert_eq!(title_of(&json!({"elements": [{"label": "Plain"}]})), Value::Null);
    }

    #[test]
    fn a_screen_is_left_alone_longer_the_less_it_changes() {
        let (half, quick) = (Duration::from_secs(30), Duration::from_millis(200));
        // A new app is read again a round later (it was still drawing); the same app after two
        // rounds when its screen changed, and twice as long after each read that showed the same.
        assert_eq!(reread_after(half, true, 0, quick).as_secs(), 30);
        let waits: Vec<u64> = (0..5).map(|unchanged| reread_after(half, false, unchanged, quick).as_secs()).collect();
        assert_eq!(waits, [60, 120, 240, 240, 240]);
        // A screen that took the phone long to read is left alone a hundred times as long.
        assert_eq!(reread_after(half, true, 0, Duration::from_millis(1500)).as_secs(), 150);
        assert_eq!(reread_after(half, false, 0, Duration::from_millis(900)).as_secs(), 90);
        assert_eq!(reread_after(half, false, 0, Duration::from_secs(30)), REREAD_MAX);
        // A run asked to read more slowly than the caps keeps its own interval.
        assert_eq!(reread_after(Duration::from_secs(900), true, 0, quick).as_secs(), 900);
    }

    #[test]
    fn rounds_come_half_as_often_once_the_same_app_stays_in_front() {
        let half = Duration::from_secs(30);
        let waits: Vec<u64> = (0..6).map(|steady| round_wait(half, steady).as_secs()).collect();
        assert_eq!(waits, [30, 30, 30, 30, 60, 60]);
    }

    #[tokio::test]
    async fn a_run_with_no_tunnel_backs_off_from_five_seconds_whatever_its_interval() {
        // The hurry is the process's own, and a test that starts a run may be in one.
        let _turn = ONE_RUN.lock().await;
        // Not in a hurry and not young: the tries double from five seconds up to thirty.
        HURRY_UNTIL.store(0, Ordering::SeqCst);
        let waits: Vec<u64> = (1..6).map(|failed| wait_for(true, false, Duration::from_secs(240), failed).as_secs()).collect();
        assert_eq!(waits, [10, 20, 30, 30, 30]);
        assert_eq!(wait_for(true, true, Duration::from_secs(240), 9), EAGER_EVERY);
        assert_eq!(wait_for(false, true, Duration::from_secs(240), 9).as_secs(), 240);
        assert_eq!(paced(Duration::from_secs(30), 9, IDLE_MAX), IDLE_MAX);
    }

    #[test]
    fn the_app_lists_decide_which_screens_are_read() {
        let leaves_out = Policy::from(&json!({"skip": ["com.tencent.xin", " COM.Apple.SpringBoard "]}));
        assert!(leaves_out.skips("com.tencent.xin") && leaves_out.skips("com.apple.springboard") && leaves_out.skips("Com.Tencent.Xin"));
        assert!(!leaves_out.skips("com.apple.mobilesafari"));
        // With a list of the only apps kept, every other app is left out, and so is one on both lists.
        let only = Policy::from(&json!({"skip": ["com.apple.mobilenotes"], "only": ["com.apple.mobilesafari", "com.apple.mobilenotes"]}));
        assert!(only.skips("com.apple.Maps") && only.skips("com.apple.mobilenotes") && !only.skips("com.apple.mobileSafari"));
        // Nothing said: every app is read, as before.
        assert_eq!(Policy::from(&json!({})), Policy::default());
        assert!(!Policy::default().skips("com.tencent.xin"));
        assert!(!Policy::from(&json!({"only": null})).skips("com.apple.Maps"));
    }

    #[test]
    fn a_round_reads_a_screen_only_when_it_is_kept_and_not_read_a_moment_ago() {
        let policy = Policy::from(&json!({"skip": ["com.tencent.xin"]}));
        let minute = Duration::from_secs(60);
        // An app that is left out is never read, however long ago anything was.
        assert_eq!(decide(Some("com.tencent.xin"), 7, &policy, None, minute), Look::Skipped);
        assert_eq!(decide(Some("com.tencent.xin"), 7, &policy, Some((7, minute * 9)), minute), Look::Skipped);
        // The first sight of an app, and another app than the one read last: read at once.
        assert_eq!(decide(Some("com.apple.mobilesafari"), 7, &policy, None, minute), Look::Read);
        assert_eq!(decide(Some("com.apple.mobilesafari"), 7, &policy, Some((8, Duration::from_secs(1))), minute), Look::Read);
        // The same app: left alone until its time is up.
        assert_eq!(decide(Some("com.apple.mobilesafari"), 7, &policy, Some((7, Duration::from_secs(59))), minute), Look::Same);
        assert_eq!(decide(Some("com.apple.mobilesafari"), 7, &policy, Some((7, minute)), minute), Look::Read);
        // An app the phone did not name is read: its screen names it, and the lists are asked then.
        assert_eq!(decide(None, 7, &policy, None, minute), Look::Read);
        assert_eq!(decide(None, 7, &policy, Some((7, Duration::from_secs(5))), minute), Look::Same);
    }

    #[test]
    fn run_statistics_keep_the_longest_gap_and_the_average() {
        let mut stats = RunStats::default();
        stats.good(400, Duration::ZERO, true);
        stats.good(600, Duration::from_secs(5), false);
        stats.good(500, Duration::from_secs(42), true);
        stats.failures = 1;
        stats.looked(Duration::from_secs(30));
        let json = stats.json();
        assert_eq!(json["looks"], 1);
        assert_eq!(json["reads"], 3);
        assert_eq!(json["changed"], 2);
        assert_eq!(json["longest_gap_ms"], 42_000);
        assert_eq!(json["average_ms"], 500);
        assert_eq!(json["slowest_ms"], 600);
        assert_eq!(RunStats::default().json()["average_ms"], 0);
    }

    #[tokio::test]
    async fn a_request_without_a_pairing_or_with_an_unknown_name_is_refused() {
        let unpaired = handle(json!({"op": "read_once"}), |_| {}).await.unwrap_err();
        assert_eq!(unpaired.code, Some("pairing"));
        let unknown = handle(json!({"op": "record"}), |_| {}).await.unwrap_err();
        assert_eq!(unknown.code, Some("config"));
    }

    /// The run in progress, the hurry and the checks are the process's own: the tests that start a
    /// run take turns.
    static ONE_RUN: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    #[tokio::test]
    async fn a_run_with_no_tunnel_tries_a_few_times_a_second_in_a_hurry_and_never_spins() {
        let _turn = ONE_RUN.lock().await;
        hurry(3);
        let lines = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let seen = lines.clone();
        // A pairing file that is not there fails each try at once, like a try with no route.
        let run = tokio::spawn(handle(json!({"op": "run", "pairing_file": "/nonexistent/pairing.plist"}), move |line| seen.lock().unwrap().push(line)));
        tokio::time::sleep(Duration::from_millis(1100)).await;
        cancel();
        tokio::time::timeout(Duration::from_secs(2), run).await.expect("the run ends when stopped").unwrap().unwrap();
        let lines = lines.lock().unwrap();
        // The lines about reads; a check another test asked for is answered in a line of its own.
        let tries: Vec<&Value> = lines.iter().filter(|line| line["event"].is_null()).collect();
        assert!((3..=8).contains(&tries.len()), "{} tries in 1.1 s", tries.len());
        // Each one failed, the run had no tunnel after any of them, and says so.
        assert!(tries.iter().all(|line| line["ok"] == false && line["tunnel"] == false));
    }

    #[tokio::test]
    async fn a_run_answers_a_check_where_it_waits() {
        let _turn = ONE_RUN.lock().await;
        let lines = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let seen = lines.clone();
        let run = tokio::spawn(handle(json!({"op": "run", "pairing_file": "/nonexistent/pairing.plist"}), move |line| seen.lock().unwrap().push(line)));
        tokio::time::sleep(Duration::from_millis(50)).await;
        let earlier = check(false);
        let asked = check(true);
        assert!(asked > earlier && earlier & 1 == 0 && asked & 1 == 1);
        let answered = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if lines.lock().unwrap().iter().any(|line| line["check"] == asked && line["event"] == "none") {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        cancel();
        tokio::time::timeout(Duration::from_secs(2), run).await.expect("the run ends when stopped").unwrap().unwrap();
        assert!(answered.is_ok(), "the check got no answer: {:?}", lines.lock().unwrap());
    }

    #[tokio::test]
    async fn a_run_reports_failed_reads_and_ends_when_stopped() {
        let _turn = ONE_RUN.lock().await;
        let lines = std::sync::Arc::new(std::sync::Mutex::new(vec![]));
        let seen = lines.clone();
        let (first, reported) = tokio::sync::oneshot::channel();
        let first = std::sync::Mutex::new(Some(first));
        let run = tokio::spawn(handle(json!({"op": "run", "pairing_file": "/nonexistent/pairing.plist"}), move |line| {
            // A line about the tunnel (the answer to a check another test asked for) is not a read.
            let read = line["event"].is_null();
            seen.lock().unwrap().push(line);
            if read {
                if let Some(first) = first.lock().unwrap().take() {
                    let _ = first.send(());
                }
            }
        }));
        // Stopped once the run has reported its first read, not after a guessed wait.
        reported.await.expect("the run reports its first read");
        cancel();
        let answer = tokio::time::timeout(Duration::from_secs(2), run).await.expect("the run ends when stopped").unwrap().unwrap();
        assert_eq!(answer["ended"], "stopped");
        assert_eq!(answer["reads"], 0);
        assert_eq!(answer["failures"], 1);
        let lines = lines.lock().unwrap();
        let first = lines.iter().find(|line| line["event"].is_null()).expect("a line about a read");
        assert_eq!(first["ok"], false);
        assert_eq!(first["code"], "pairing");
    }
}
