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
//!   reads made, the failures and the longest gap between two reads. With `direct_points` and
//!   `watch` it reads when the phone says that an app came to the front or that the screen moved
//!   (see `due`), and at the interval only while the phone says nothing.
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

/// What reading costs the phone, and how a run keeps it small without missing what the owner
/// does (the owner, 2026-11-20: Screen History visibly slowed the iPhone down, "Unacceptable",
/// and of a first fix that only looked every 30 seconds: "Cant miss things"):
/// - While a client needs accessibility it is on in every app, and the phone sends the client
///   the front app's whole tree again at every change of the screen. Until 2026-11-20 one
///   subscription was kept for the whole run. Now accessibility is asked for when a screen is
///   to be read and given back at once. Between rounds nothing is asked of any app.
/// - Which app is in front is heard from the phone's own notices of app states (`ax::front`),
///   which cost the apps nothing. An app that comes to the front is read `ARRIVE` later and a
///   second time soon after (`SECOND`), and while the Home Screen or an app that is never kept
///   (`Policy`) shows, no round is made but a look now and then (`SAFETY`).
/// - The app in front is read again `REREAD` after a read that showed something new, and twice
///   as long after each read that did not, up to `IDLE_MAX`. The screen's frame count says more:
///   a screen that drew nothing since it was read is left alone, one that moves again after a
///   quiet time is read at the first pace again, and a round waits a moment for a scroll to end.
/// - A snapshot is made on the app's main thread. After one that took long, the next read of
///   that app waits `BUSY_SHARE` times as long.
/// - With no notices (an iOS that sends none, or before the first), the run looks which app is
///   in front at its interval. Notices that a look found wrong are not believed until they say
///   something new, and after `DOUBTS` of those only when they say that an app came to the front.
/// - After the iPhone is unlocked or an agent's task ends, the first round waits `SETTLE`.
const REREAD: Duration = Duration::from_secs(10);
const IDLE_MAX: Duration = Duration::from_secs(240);
const BUSY_SHARE: u32 = 50;
const REREAD_MAX: Duration = Duration::from_secs(600);
const SETTLE: Duration = Duration::from_secs(2);
/// How long after an app came to the front its screen is read. Asking for accessibility takes
/// most of a second more, so a visit of two seconds is still caught.
const ARRIVE: Duration = Duration::from_millis(500);
/// An app that came to the front is read unless this same process was read less than this ago.
const RETURN: Duration = Duration::from_secs(3);
/// How soon an app that just came to the front is read a second time: the first read may have
/// found it still loading, and by now it shows what it came to show.
const SECOND: Duration = Duration::from_secs(4);
/// With the Home Screen or a left-out app in front a look is made all the same, first after this
/// long and half as often each time it finds the same again, up to `SAFETY_MAX`: a notice that
/// was missed must not end reading for good.
const SAFETY: Duration = Duration::from_secs(60);
const SAFETY_MAX: Duration = Duration::from_secs(600);
/// How long a round that is due waits for the screen to stop moving.
const HOLD: Duration = Duration::from_secs(4);
/// Rounds in a row that found the same app and read nothing, after which a run that was not
/// asked to listen for notices looks half as often.
const STEADY_AFTER: u32 = 4;
/// How often the notices may be found wrong before "no app is in front" is no longer believed.
const DOUBTS: u32 = 3;
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
/// showed the same text. `snapshot`: the time the app spent on the read.
fn reread_after(unchanged: u32, snapshot: Duration) -> Duration {
    paced(REREAD, unchanged, IDLE_MAX).max(snapshot.saturating_mul(BUSY_SHARE)).min(REREAD_MAX)
}

/// How long an app that just came to the front is left alone after its first read. One that
/// took long over the read is given more time here too.
fn second_after(snapshot: Duration) -> Duration {
    SECOND.max(snapshot.saturating_mul(BUSY_SHARE / 5))
}

/// The wait between two looks of a run that was not asked to listen for notices. `steady`: the
/// rounds in a row that found the same app as the round before and read nothing.
fn round_wait(interval: Duration, steady: u32) -> Duration {
    if steady >= STEADY_AFTER { interval.saturating_mul(2) } else { interval }
}

/// What the phone's notices say is in front, while a run waits.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Shown {
    /// Nothing is heard: no notices on this iOS, none yet, or they were found wrong.
    Unknown,
    /// No app is in the foreground: the Home Screen.
    Home,
    /// An app whose screens are never kept.
    LeftOut,
    /// An app whose screen is read.
    App,
}

/// What the frame counts say, when they can be believed.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Moves {
    /// Nothing was drawn since the last read: the screen shows what was read.
    still: bool,
    /// Nothing was drawn since the last round began: the app it found is still in front.
    unstirred: bool,
    /// The screen moved again after a quiet time, this long ago.
    woke: Option<Duration>,
    /// The screen is moving now.
    moving: bool,
}

/// What the hints say while a run waits for its next round.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Hint {
    shown: Shown,
    /// The app in front changed after the last round began, this long ago.
    changed: Option<Duration>,
    moves: Option<Moves>,
}

/// The waits after a round that found the screen, each counted from when that round began.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Waits {
    /// Until a run that hears nothing looks again.
    blind: Duration,
    /// Until the app in front may be read again, at the pace its screen has set.
    again: Duration,
    /// Until it may be read again at the first pace, when its screen shows new things.
    afresh: Duration,
    /// Until a look is made though the notices say that nothing is to be read.
    safety: Duration,
    /// The round found an app whose screens are never kept, or the Home Screen.
    left_out: bool,
}

/// Why a round is made. It goes into the round's line as "due", so the app's log shows what
/// drives the reading on a phone.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Why {
    /// An app came to the front.
    Arrived,
    /// The screen moved again after a quiet time.
    Woke,
    /// The app in front is read again at its pace.
    Pace,
    /// The notices say that nothing is to be read: a look all the same.
    Safety,
    /// Nothing is heard of the app in front: a look at the run's interval.
    Blind,
}

impl Why {
    fn name(self) -> &'static str {
        match self {
            Why::Arrived => "arrived",
            Why::Woke => "woke",
            Why::Pace => "pace",
            Why::Safety => "safety",
            Why::Blind => "blind",
        }
    }
}

/// Whether the next round is due, and why. `waited`: since the last round began.
fn due(waited: Duration, waits: &Waits, hint: &Hint) -> Option<Why> {
    let after = |wait: Duration, why: Why| (waited >= wait).then_some(why);
    match (hint.shown, hint.moves) {
        // An app came to the front: it is read, whatever was read before.
        (Shown::App, _) if hint.changed.is_some() => hint.changed.filter(|ago| *ago >= ARRIVE).map(|_| Why::Arrived),
        (Shown::Home | Shown::LeftOut, _) => after(waits.safety, Why::Safety),
        // No app can have come to the front on a screen that drew nothing: the one the last
        // round found is still there, and is read again only when it drew since it was read.
        (Shown::Unknown, Some(moves)) if moves.unstirred => {
            if waits.left_out || moves.still { after(waits.safety, Why::Safety) } else { after(waits.again, Why::Pace) }
        }
        (Shown::Unknown, _) => after(waits.blind.min(waits.again), Why::Blind),
        (Shown::App, None) => after(waits.again, Why::Pace),
        (Shown::App, Some(moves)) => {
            // New things show after a quiet time: read once the scroll ends, or soon anyway.
            if waited >= waits.afresh && moves.woke.is_some_and(|ago| !moves.moving || ago >= HOLD) {
                return Some(Why::Woke);
            }
            let wait = if moves.still { waits.again.max(IDLE_MAX) } else { waits.again };
            (waited >= wait && (!moves.moving || waited >= wait + HOLD)).then_some(Why::Pace)
        }
    }
}

/// The phone's notices of app states and its frame counts (`ax::front`), kept going on the run's
/// tunnel. Each is started again a while after it failed or ended, and a run goes on without.
#[derive(Default)]
struct Hints {
    watch: Option<ax::front::Watch>,
    frames: Option<ax::front::Frames>,
    watch_again: Option<Instant>,
    watch_failed: u32,
    frames_again: Option<Instant>,
    frames_failed: u32,
    /// The watch's count of changes when the last round began.
    changes: u64,
    /// The count of changes at which a round found the watch wrong: until it changes again,
    /// the watch is not believed. And how often that happened in this run.
    doubted: Option<u64>,
    doubts: u32,
    /// The frame counts as the round under way began.
    mark: Option<ax::front::Motion>,
    /// The first notice and the first believable frame count were said in a line.
    said_notice: bool,
    said_moves: bool,
}

/// The first wait before a hint that failed or ended is tried again. It doubles up to ten minutes.
const HINT_AGAIN: Duration = Duration::from_secs(30);

impl Hints {
    /// The tunnel is gone, and what ran inside it with it. On a new tunnel both are tried at
    /// once again; on the same one, each is tried later every time it failed or ended.
    fn lose(&mut self) {
        (self.watch, self.frames, self.mark) = (None, None, None);
        (self.watch_again, self.watch_failed, self.frames_again, self.frames_failed) = (None, 0, None, 0);
    }

    /// Starts what is not running, and says in a line what started, failed or ended. The frames
    /// are not counted during a hold: the screen is dark then, or an agent's.
    async fn keep(&mut self, device: &mut Device, emit: &impl Fn(Value), frames: bool) {
        let now = Instant::now();
        if let Some(ended) = self.watch.as_ref().and_then(|watch| watch.front().ended) {
            self.watch = None;
            self.watch_again = Some(now + paced(HINT_AGAIN, self.watch_failed, Duration::from_secs(600)));
            self.watch_failed += 1;
            emit(json!({"event": "watch", "on": false, "error": ended}));
        }
        if self.watch.is_none() && self.watch_again.is_none_or(|again| now >= again) {
            let asked = Instant::now();
            match ax::front::Watch::start(&mut device.adapter, &device.rsd).await {
                Ok(watch) => {
                    self.watch = Some(watch);
                    self.watch_again = None;
                    self.changes = 0;
                    self.doubted = None;
                    self.said_notice = false;
                    emit(json!({"event": "watch", "on": true, "ms": milliseconds(asked.elapsed())}));
                }
                Err(error) => {
                    self.watch_again = Some(Instant::now() + paced(HINT_AGAIN, self.watch_failed, Duration::from_secs(600)));
                    self.watch_failed += 1;
                    emit(json!({"event": "watch", "on": false, "error": error}));
                }
            }
        }
        if !frames {
            if self.frames.take().is_some() {
                self.frames_again = None;
                self.mark = None;
            }
            return;
        }
        if let Some(ended) = self.frames.as_ref().and_then(|frames| frames.motion().1) {
            self.frames = None;
            self.mark = None;
            self.frames_again = Some(now + paced(HINT_AGAIN, self.frames_failed, Duration::from_secs(600)));
            self.frames_failed += 1;
            emit(json!({"event": "frames", "on": false, "error": ended}));
        }
        if self.frames.is_none() && self.frames_again.is_none_or(|again| now >= again) {
            match ax::front::Frames::start(&mut device.adapter, &device.rsd).await {
                Ok(frames) => {
                    self.frames = Some(frames);
                    self.frames_again = None;
                    self.said_moves = false;
                    emit(json!({"event": "frames", "on": true}));
                }
                Err(error) => {
                    self.frames_again = Some(Instant::now() + paced(HINT_AGAIN, self.frames_failed, Duration::from_secs(600)));
                    self.frames_failed += 1;
                    emit(json!({"event": "frames", "on": false, "error": error}));
                }
            }
        }
    }

    /// What the watch knows, while it runs and is believed.
    fn front(&self) -> Option<ax::front::Front> {
        let front = self.watch.as_ref()?.front();
        (front.ended.is_none() && front.changes > 0 && self.doubted != Some(front.changes)).then_some(front)
    }

    /// What the hints say now. Says once, in a line, what the first notice carried and that the
    /// frame counts can be believed: the log then shows what this iOS sends.
    fn hint(&mut self, emit: &impl Fn(Value)) -> Hint {
        let now = Instant::now();
        if !self.said_notice && let Some(front) = self.watch.as_ref().map(|watch| watch.front()).filter(|front| front.notices > 0) {
            self.said_notice = true;
            emit(json!({"event": "watch", "notice": true, "fields": front.fields}));
        }
        let moves = self.frames.as_ref().map(|frames| frames.motion().0).filter(|motion| motion.told(now)).map(|motion| Moves {
            still: motion.still(),
            unstirred: motion.unstirred(),
            woke: motion.woke(now),
            moving: motion.moving(now),
        });
        if moves.is_some() && !self.said_moves {
            self.said_moves = true;
            emit(json!({"event": "frames", "told": true}));
        }
        let Some(front) = self.front() else { return Hint { shown: Shown::Unknown, changed: None, moves } };
        let shown = match &front.app {
            Some(app) if !app.bundle.as_deref().is_some_and(left_out) => Shown::App,
            // "Nothing to read" was wrong too often: it is no longer taken from the notices.
            _ if self.doubts >= DOUBTS => Shown::Unknown,
            Some(_) => Shown::LeftOut,
            None => Shown::Home,
        };
        let changed = (front.changes != self.changes).then(|| front.changed_at.map(|at| now.saturating_duration_since(at)).unwrap_or(ARRIVE));
        Hint { shown, changed, moves }
    }

    /// A round begins: what the watch said so far is taken in, and the frames drawn from now on
    /// may be another app's.
    fn begin(&mut self) {
        if let Some(watch) = &self.watch {
            self.changes = watch.front().changes;
        }
        self.mark = self.frames.as_ref().map(|frames| frames.begin());
    }

    /// A round found the screen. `kept`: an app whose screen is read is in front.
    fn looked(&mut self, kept: bool, emit: &impl Fn(Value)) {
        let Some(front) = self.watch.as_ref().map(|watch| watch.front()) else { return };
        // Notices that came while the round was under way say nothing of what it found.
        if front.changes != self.changes || front.changes == 0 || front.ended.is_some() {
            return;
        }
        let nothing = front.app.as_ref().is_none_or(|app| app.bundle.as_deref().is_some_and(left_out));
        if kept && nothing && self.doubted != Some(front.changes) {
            // An app is in front while the notices say that none is, or only one that is left
            // out: they are wrong, and are not believed until they say something new.
            self.doubted = Some(front.changes);
            self.doubts += 1;
            emit(json!({"event": "watch", "doubted": self.doubts}));
        } else if !kept && nothing {
            self.doubted = None;
        }
    }

    /// A round is over. `read`: it read a screen.
    fn end(&mut self, read: bool) {
        if let (Some(frames), Some(before)) = (&self.frames, self.mark.take()) {
            frames.passed(&before, read);
        }
    }
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

/// Whether this app's screens are never kept, as the app last said.
fn left_out(app: &str) -> bool {
    POLICY.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).as_ref().is_some_and(|policy| policy.skips(app))
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
    // How long the app spent on the last read, and whether the round to come is for an app that
    // has just come to the front.
    let mut last_snapshot = Duration::ZERO;
    let mut arrived = false;
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
    // The phone's own notices of the app in front and of the screen moving, for a run that asks
    // for them: they say when a round is due, and cost the apps nothing.
    let hinted = points.is_some() && request["watch"].as_bool().unwrap_or(false);
    let mut hints = Hints::default();
    // Why the round to come is made, when the hints said so.
    let mut next: Option<Why> = None;
    loop {
        let why = next.take();
        if device.is_none() {
            hints.lose();
        }
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
            // The notices go on through a hold, so the app the owner unlocks into is known at
            // once. The frames are not counted: the screen is dark, or an agent's.
            if hinted && let Some(open) = device.as_mut() {
                hints.keep(open, &emit, false).await;
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
        if let Some(why) = why {
            line["due"] = why.name().into();
        }
        let mut trace = ax::direct::Trace::default();
        let result = async {
            if device.is_none() {
                device = Some(open_tunnel(&target, &mut hunt, &emit).await?);
                stats.connections += 1;
            }
            // The tunnel is opened first, whatever else waits: the moment for it may be short.
            if hinted {
                hints.keep(device.as_mut().unwrap(), &emit, true).await;
            }
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
            hints.begin();
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
        // The wait until the next round, while the run has a tunnel, of a run that hears nothing
        // of the app in front. After a round that found the screen, a run that listens has more
        // waits than this one, and the hints choose among them.
        let blind;
        let mut waits = None;
        let mut read = false;
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
                    let snapshot = Duration::from_millis(trace.snapshot_ms.unwrap_or(took));
                    // An app that has just come to the front, or one the run did not read last.
                    let fresh = arrived || (pid.is_some() && last_read.map(|(read, _)| read) != pid);
                    read = true;
                    if let Some((_, summary)) = &kept {
                        let text = hash_of(&summary["text"]);
                        let changed = last_text != Some(text);
                        last_text = Some(text);
                        unchanged = if changed { 0 } else { unchanged + 1 };
                        line["changed"] = changed.into();
                    }
                    reread = reread_after(unchanged, snapshot);
                    if fresh && kept.is_some() {
                        reread = reread.min(second_after(snapshot));
                    }
                    last_snapshot = snapshot;
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
                arrived = false;
                // A run that listens and hears nothing must not look less often for that.
                blind = if hinted { interval } else { round_wait(interval, steady) };
                let least = Duration::from_secs(1);
                let since_read = last_read.map(|(_, read)| asked.saturating_duration_since(read)).unwrap_or_default();
                waits = Some(match look {
                    // An app that is never kept is in front: nothing of it is to be read again.
                    Look::Skipped => Waits { blind, again: blind, afresh: blind, safety: paced(SAFETY, steady, SAFETY_MAX), left_out: true },
                    Look::Read | Look::Same => Waits {
                        blind,
                        again: reread.saturating_sub(since_read).max(least),
                        afresh: reread_after(0, last_snapshot).saturating_sub(since_read).max(least),
                        safety: paced(SAFETY, steady, SAFETY_MAX),
                        left_out: false,
                    },
                });
                hints.looked(look != Look::Skipped, &emit);
            }
            Err(failure) => {
                // A screen that shows no app (locked or off) is an answer, and the tunnel stays.
                let no_app = failure.detail.contains("no point of the screen") && !failure.detail.contains(ax::direct::HITS_FAILED);
                steady = 0;
                last_pid = None;
                if no_app {
                    idle += 1;
                    unsubscribed = 0;
                    blind = paced(interval, idle, IDLE_MAX);
                } else {
                    failing += 1;
                    blind = paced(RETRY, failing, FAILING_MAX);
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
        hints.end(read);
        emit(line);
        // Waits in short pieces, so Stop is answered at once. The wait is asked again each piece:
        // with no tunnel it turns short the moment a hurry begins, and stays 200 ms during one.
        // Nothing is asked of any app while the run waits. After a round that found the screen,
        // the phone's own notices can end the wait early (an app came to the front) or stretch
        // it (the Home Screen shows, or nothing was drawn).
        while RUN.load(Ordering::SeqCst) == me && !PAUSED.load(Ordering::SeqCst) {
            match waits.as_ref().filter(|_| hinted && device.is_some()) {
                Some(waits) => {
                    if let Some(reason) = due(asked.elapsed(), waits, &hints.hint(&emit)) {
                        match reason {
                            // Read, unless this very process was read a moment ago.
                            Why::Arrived => {
                                arrived = true;
                                reread = reread.min(RETURN);
                            }
                            // Read at the first pace again.
                            Why::Woke => {
                                unchanged = 0;
                                reread = reread.min(reread_after(0, last_snapshot));
                            }
                            Why::Pace | Why::Safety | Why::Blind => {}
                        }
                        next = Some(reason);
                        break;
                    }
                }
                None => {
                    if asked.elapsed() >= wait_for(device.is_none(), since_start() < EAGER, blind, failing) {
                        break;
                    }
                }
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
        let quick = Duration::from_millis(100);
        // Ten seconds after a read that showed something new, and twice as long after each read
        // that showed the same.
        let waits: Vec<u64> = (0..7).map(|unchanged| reread_after(unchanged, quick).as_secs()).collect();
        assert_eq!(waits, [10, 20, 40, 80, 160, 240, 240]);
        // A screen that took the app long to read is left alone fifty times as long.
        assert_eq!(reread_after(0, Duration::from_millis(900)).as_secs(), 45);
        assert_eq!(reread_after(0, Duration::from_secs(30)), REREAD_MAX);
        // An app that just came to the front is read a second time soon, a slow one less soon.
        assert_eq!(second_after(quick), SECOND);
        assert_eq!(second_after(Duration::from_millis(900)).as_secs(), 9);
    }

    const WAITS: Waits = Waits { blind: Duration::from_secs(15), again: Duration::from_secs(10), afresh: Duration::from_secs(10), safety: Duration::from_secs(60), left_out: false };

    fn seconds(seconds: u64) -> Duration {
        Duration::from_secs(seconds)
    }

    #[test]
    fn an_app_that_comes_to_the_front_is_read_whatever_was_read_before() {
        let arrived = |ago: u64| Hint { shown: Shown::App, changed: Some(Duration::from_millis(ago)), moves: None };
        // Half a second after it came: a second after the last round, or minutes after it.
        assert_eq!(due(seconds(1), &WAITS, &arrived(200)), None);
        assert_eq!(due(seconds(1), &WAITS, &arrived(500)), Some(Why::Arrived));
        assert_eq!(due(seconds(500), &WAITS, &arrived(200)), None);
        // The frame counts do not hold it up: its first screen moves as it comes.
        let moving = Hint { moves: Some(Moves { still: false, unstirred: false, woke: None, moving: true }), ..arrived(500) };
        assert_eq!(due(seconds(1), &WAITS, &moving), Some(Why::Arrived));
        // The owner goes to the Home Screen or to an app that is left out: no round for that,
        // only a look after a good while.
        for shown in [Shown::Home, Shown::LeftOut] {
            let gone = Hint { shown, changed: Some(seconds(5)), moves: None };
            assert_eq!(due(seconds(59), &WAITS, &gone), None);
            assert_eq!(due(seconds(60), &WAITS, &gone), Some(Why::Safety));
        }
        // The looks at a left-out app come half as often each time, up to ten minutes.
        let looks: Vec<u64> = (0..6).map(|steady| paced(SAFETY, steady, SAFETY_MAX).as_secs()).collect();
        assert_eq!(looks, [60, 120, 240, 480, 600, 600]);
    }

    #[test]
    fn the_app_in_front_is_read_again_at_the_pace_of_its_screen() {
        let app = Hint { shown: Shown::App, changed: None, moves: None };
        assert_eq!(due(seconds(9), &WAITS, &app), None);
        assert_eq!(due(seconds(10), &WAITS, &app), Some(Why::Pace));
        let frames = |still: bool, woke: Option<u64>, moving: bool| Hint { moves: Some(Moves { still, unstirred: still, woke: woke.map(seconds), moving }), ..app };
        // A screen that drew nothing since it was read is left alone.
        assert_eq!(due(seconds(239), &WAITS, &frames(true, None, false)), None);
        assert_eq!(due(seconds(240), &WAITS, &frames(true, None, false)), Some(Why::Pace));
        // One that drew something (the clock) is read at its pace.
        assert_eq!(due(seconds(10), &WAITS, &frames(false, None, false)), Some(Why::Pace));
        // A read that is due waits for a scroll to end, though not for long.
        assert_eq!(due(seconds(10), &WAITS, &frames(false, None, true)), None);
        assert_eq!(due(seconds(14), &WAITS, &frames(false, None, true)), Some(Why::Pace));
        // The owner scrolls a page that was read many times and had stayed the same: it is read
        // as soon as the scroll ends, or four seconds into one that goes on.
        let slow = Waits { again: seconds(160), ..WAITS };
        assert_eq!(due(seconds(30), &slow, &frames(false, None, false)), None);
        assert_eq!(due(seconds(30), &slow, &frames(false, Some(1), false)), Some(Why::Woke));
        assert_eq!(due(seconds(30), &slow, &frames(false, Some(1), true)), None);
        assert_eq!(due(seconds(30), &slow, &frames(false, Some(4), true)), Some(Why::Woke));
        // Never sooner than the first pace, and later for an app that is slow to read.
        assert_eq!(due(seconds(9), &slow, &frames(false, Some(1), false)), None);
        let heavy = Waits { afresh: seconds(45), ..slow };
        assert_eq!(due(seconds(30), &heavy, &frames(false, Some(1), false)), None);
        assert_eq!(due(seconds(45), &heavy, &frames(false, Some(1), false)), Some(Why::Woke));
    }

    #[test]
    fn a_run_that_hears_no_notices_looks_at_its_interval() {
        let nothing = Hint { shown: Shown::Unknown, changed: None, moves: None };
        // The app it read is read again at its pace, when that comes sooner than the next look.
        assert_eq!(due(seconds(9), &WAITS, &nothing), None);
        assert_eq!(due(seconds(10), &WAITS, &nothing), Some(Why::Blind));
        let left_out = Waits { again: seconds(15), left_out: true, ..WAITS };
        assert_eq!(due(seconds(14), &left_out, &nothing), None);
        assert_eq!(due(seconds(15), &left_out, &nothing), Some(Why::Blind));
        // With frame counts alone: no app can have come to the front on a screen that drew nothing.
        let frames = |still: bool, unstirred: bool| Hint { moves: Some(Moves { still, unstirred, woke: None, moving: false }), ..nothing };
        assert_eq!(due(seconds(59), &WAITS, &frames(true, true)), None);
        assert_eq!(due(seconds(60), &WAITS, &frames(true, true)), Some(Why::Safety));
        assert_eq!(due(seconds(10), &WAITS, &frames(false, false)), Some(Why::Blind));
        // The app the last round found and did not read drew before that round: read at its pace.
        assert_eq!(due(seconds(10), &WAITS, &frames(false, true)), Some(Why::Pace));
        // The Home Screen, drawn on before the last look and still since: nothing to read there.
        assert_eq!(due(seconds(59), &left_out, &frames(false, true)), None);
    }

    #[tokio::test]
    async fn notices_a_look_finds_wrong_are_not_believed() {
        // The app lists are the process's own.
        let _turn = ONE_RUN.lock().await;
        set_policy(&json!({"skip": ["com.tencent.xin"]}));
        let lines = std::sync::Mutex::new(vec![]);
        let emit = |line: Value| lines.lock().unwrap().push(line);
        let mut hints = Hints { watch: Some(ax::front::Watch::fake()), ..Default::default() };
        let say = |hints: &Hints, pid: u64, bundle: &str, foreground: bool| hints.watch.as_ref().unwrap().say(pid, bundle, foreground);
        // Before the first notice of a foreground app nothing is known.
        assert_eq!(hints.hint(&emit).shown, Shown::Unknown);
        say(&hints, 5, "com.apple.Maps", false);
        assert_eq!(hints.hint(&emit).shown, Shown::Unknown);
        // An app comes to the front after the last round began.
        say(&hints, 7, "com.apple.mobilesafari", true);
        let hint = hints.hint(&emit);
        assert_eq!((hint.shown, hint.changed.is_some()), (Shown::App, true));
        // The round that reads it takes the news in.
        hints.begin();
        hints.looked(true, &emit);
        assert_eq!(hints.hint(&emit), Hint { shown: Shown::App, changed: None, moves: None });
        // The owner opens an app that is left out, then goes to the Home Screen.
        say(&hints, 8, "com.tencent.xin", true);
        say(&hints, 7, "com.apple.mobilesafari", false);
        assert_eq!(hints.hint(&emit).shown, Shown::LeftOut);
        say(&hints, 8, "com.tencent.xin", false);
        assert_eq!(hints.hint(&emit).shown, Shown::Home);
        // A look that finds an app there all the same: the notices are wrong, and the run looks
        // at its interval until they say something new.
        hints.begin();
        hints.looked(true, &emit);
        assert_eq!(hints.hint(&emit).shown, Shown::Unknown);
        assert_eq!(lines.lock().unwrap().last().unwrap()["doubted"], 1);
        hints.begin();
        hints.looked(true, &emit);
        assert_eq!(hints.doubts, 1);
        say(&hints, 9, "com.apple.Maps", true);
        assert_eq!(hints.hint(&emit).shown, Shown::App);
        // Wrong three times: "nothing is in front" is no longer taken from them, but an app that
        // comes to the front still is.
        for _ in 0..2 {
            say(&hints, 9, "com.apple.Maps", false);
            hints.begin();
            hints.looked(true, &emit);
            say(&hints, 9, "com.apple.Maps", true);
        }
        assert_eq!(hints.doubts, 3);
        say(&hints, 9, "com.apple.Maps", false);
        assert_eq!(hints.hint(&emit).shown, Shown::Unknown);
        say(&hints, 8, "com.tencent.xin", true);
        assert_eq!(hints.hint(&emit).shown, Shown::Unknown);
        say(&hints, 9, "com.apple.Maps", true);
        assert_eq!(hints.hint(&emit).shown, Shown::App);
        // The first notice was said once, with the fields it had and no app's name.
        let said: Vec<Value> = lines.lock().unwrap().iter().filter(|line| line["notice"] == true).cloned().collect();
        assert_eq!(said.len(), 1);
        *POLICY.lock().unwrap() = None;
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
