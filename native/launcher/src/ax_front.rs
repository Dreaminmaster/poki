//! Which app is in front, and whether the screen moves, heard from the phone as it happens and
//! without accessibility.
//!
//! Screen History must not miss an app the owner opens (the owner, 2026-11-20: "Cant miss
//! things") and must not slow the iPhone down (the same day: "Unacceptable"). Asking the
//! accessibility service which app is in front costs the apps something every time, so it cannot
//! be asked every second. The developer services tell both for nothing, on the same service hub
//! the launcher already uses to start and end the runner:
//! - `mobilenotifications` sends a notice whenever an app's state changes, the ones Xcode shows as
//!   an app comes to the foreground: its bundle id, its process and its state.
//! - `graphics.opengl` says once a second how many frames the screen drew.
//!
//! Neither turns accessibility on, asks an app anything, or shows anything on the phone. Both are
//! hints: a run that hears nothing from them reads at its own pace, as before.
use super::*;
use idevice::dvt::remote_server::RemoteServerClient;
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// The developer services' hub, as the tunnel lists it.
pub const HUB: &str = "com.apple.instruments.dtservicehub";
const NOTICES: &str = "com.apple.instruments.server.services.mobilenotifications";
const GRAPHICS: &str = "com.apple.instruments.server.services.graphics.opengl";

/// How long the phone has to open a channel before the watch counts as not there.
const START_WITHIN: Duration = Duration::from_secs(4);

/// An app the phone named in a notice.
#[derive(Clone, Debug, PartialEq)]
pub struct App {
    pub pid: u64,
    /// Its bundle id, when the notice carried one that reads as one.
    pub bundle: Option<String>,
}

/// One notice of the phone's: an app, and whether it is in the foreground now.
#[derive(Debug, PartialEq)]
pub struct Notice {
    pub app: App,
    pub foreground: bool,
}

/// The names of a notice's fields that this reads, as the phone spells them.
const FIELDS: [&str; 6] = ["displayID", "pid", "state", "state_description", "elevated_state", "elevated_state_description"];

impl Notice {
    /// Reads a notice from the archived dictionary the phone sends. A foreground app is one whose
    /// state says so in words ("Foreground Running") or by number (the system's own: 8, and 32
    /// for one in the foreground that something covers).
    fn from(archive: &Archive) -> Option<Self> {
        let root = archive.root();
        let pid = archive.field(root, "pid").and_then(|pid| archive.integer(pid)).filter(|pid| *pid > 0)?;
        let bundle = archive.field(root, "displayID").and_then(|id| archive.string(id)).filter(|id| is_bundle(id));
        let words = ["state_description", "elevated_state_description"].iter().filter_map(|key| archive.field(root, key).and_then(|v| archive.string(v))).collect::<Vec<_>>();
        let number = archive.field(root, "state").and_then(|state| archive.integer(state));
        let foreground = if words.is_empty() { matches!(number, Some(8 | 32)) } else { words.iter().any(|words| words.contains("Foreground")) };
        Some(Self { app: App { pid, bundle }, foreground })
    }

    /// Which of the fields a notice has. For the log: it says what this iOS sends, and names no app.
    fn fields(archive: &Archive) -> Vec<&'static str> {
        FIELDS.into_iter().filter(|name| archive.field(archive.root(), name).is_some()).collect()
    }
}

/// Whether a name reads as a bundle id: letters, digits, dashes and dots, with a dot inside.
fn is_bundle(name: &str) -> bool {
    name.len() <= 155 && name.contains('.') && !name.starts_with('.') && !name.ends_with('.') && !name.contains("..") && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.')
}

/// The apps in the foreground, the one that came last at the end: it is the one in front.
#[derive(Default, Debug)]
pub struct Fronts {
    up: Vec<App>,
}

impl Fronts {
    /// Takes a notice in. Returns whether the app in front is another one now (or none).
    pub fn hear(&mut self, notice: Notice) -> bool {
        let before = self.front().map(|app| app.pid);
        self.up.retain(|app| app.pid != notice.app.pid);
        if notice.foreground {
            // A notice that was missed must not leave a list that grows for the whole day.
            if self.up.len() >= 8 {
                self.up.remove(0);
            }
            self.up.push(notice.app);
        }
        before != self.front().map(|app| app.pid)
    }

    pub fn front(&self) -> Option<&App> {
        self.up.last()
    }
}

#[derive(Default)]
struct Heard {
    fronts: Fronts,
    /// How often the app in front changed. 0: no notice named a foreground app yet.
    changes: u64,
    changed_at: Option<Instant>,
    notices: u64,
    fields: Vec<&'static str>,
    ended: Option<String>,
}

impl Heard {
    fn hear(&mut self, notice: Notice) {
        if self.fronts.hear(notice) {
            self.changes += 1;
            self.changed_at = Some(Instant::now());
        }
    }
}

/// What the watch knows now.
#[derive(Clone, Debug, Default)]
pub struct Front {
    /// How often the app in front changed since the watch began. 0: nothing is known yet.
    pub changes: u64,
    /// The app in front. None once the last one left the foreground: the Home Screen shows.
    pub app: Option<App>,
    /// When it last changed.
    pub changed_at: Option<Instant>,
    pub notices: u64,
    /// The fields the first notice had.
    pub fields: Vec<&'static str>,
    /// Why the watch ended, when it did. A watch that ended knows nothing any more.
    pub ended: Option<String>,
}

/// Listens to the phone's notices of app states on a stream of its own inside the tunnel.
pub struct Watch {
    heard: Arc<Mutex<Heard>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Watch {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn lock<T>(shared: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    shared.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Watch {
    /// Opens the channel and asks for the notices. Only the notices of app states: the ones
    /// about memory are left off.
    pub async fn start(adapter: &mut AdapterHandle, rsd: &RsdHandshake) -> std::result::Result<Self, String> {
        let port = rsd.services.get(HUB).ok_or("the developer services are not listed")?.port;
        let stream = tokio::time::timeout(START_WITHIN, adapter.connect(port)).await.map_err(|_| "no answer from the developer services".to_string())?.map_err(|error| error.to_string())?;
        let heard = Arc::new(Mutex::new(Heard::default()));
        let (ready, started) = tokio::sync::oneshot::channel::<std::result::Result<(), String>>();
        let task = tokio::spawn({
            let heard = heard.clone();
            async move {
                let mut server = RemoteServerClient::new(stream);
                let ended = Self::listen(&mut server, &heard, ready).await;
                lock(&heard).ended = Some(ended);
            }
        });
        let watch = Self { heard, task };
        match tokio::time::timeout(START_WITHIN, started).await {
            Ok(Ok(Ok(()))) => Ok(watch),
            Ok(Ok(Err(error))) => Err(error),
            Ok(Err(_)) => Err(lock(&watch.heard).ended.clone().unwrap_or_else(|| "the channel closed".into())),
            Err(_) => Err("the app notices did not start in time".into()),
        }
    }

    /// Runs until the stream ends. Returns why it did.
    async fn listen(server: &mut RemoteServerClient<Box<dyn ReadWrite>>, heard: &Mutex<Heard>, ready: tokio::sync::oneshot::Sender<std::result::Result<(), String>>) -> String {
        let mut channel = match server.make_channel(NOTICES).await {
            Ok(channel) => channel,
            Err(error) => {
                let error = format!("no channel for app notices: {error}");
                let _ = ready.send(Err(error.clone()));
                return error;
            }
        };
        if let Err(error) = channel.call_method(Some(Value::String("setApplicationStateNotificationsEnabled:".into())), Some(vec![AuxValue::archived_value(true)]), false).await {
            let error = format!("app notices were not turned on: {error}");
            let _ = ready.send(Err(error.clone()));
            return error;
        }
        let _ = ready.send(Ok(()));
        loop {
            let message = match channel.read_message().await {
                Ok(message) => message,
                Err(error) => return error.to_string(),
            };
            for value in message.aux.map(|aux| aux.values).unwrap_or_default() {
                let AuxValue::Array(bytes) = value else { continue };
                let Ok(archive) = Archive::parse(&bytes) else { continue };
                let mut heard = lock(heard);
                if heard.notices == 0 {
                    heard.fields = Notice::fields(&archive);
                }
                heard.notices += 1;
                let Some(notice) = Notice::from(&archive) else { continue };
                heard.hear(notice);
            }
        }
    }

    /// A watch that hears what a test says, with no phone.
    #[cfg(test)]
    pub fn fake() -> Self {
        Self { heard: Default::default(), task: tokio::spawn(async {}) }
    }

    #[cfg(test)]
    pub fn say(&self, pid: u64, bundle: &str, foreground: bool) {
        let mut heard = lock(&self.heard);
        heard.notices += 1;
        heard.hear(Notice { app: App { pid, bundle: Some(bundle.into()) }, foreground });
    }

    pub fn front(&self) -> Front {
        let heard = lock(&self.heard);
        Front { changes: heard.changes, app: heard.fronts.front().cloned(), changed_at: heard.changed_at, notices: heard.notices, fields: heard.fields.clone(), ended: heard.ended.clone() }
    }
}

/// A second with this many frames or more is one in which the screen moved: a scroll, a new page,
/// typing. Fewer is the clock ticking over or a cursor.
const MOVING: f64 = 4.0;
/// The screen is quiet again after this long with no second that moved.
const QUIET_AFTER: Duration = Duration::from_secs(3);
/// A sample older than this says nothing of the screen now.
const SAMPLE_FRESH: Duration = Duration::from_secs(4);

/// What the frame counts say of the screen, as far as a reader needs it: whether anything was
/// drawn since the last read, and whether the screen is moving now.
#[derive(Default, Debug, Clone)]
pub struct Motion {
    /// When the last sample came.
    heard_at: Option<Instant>,
    /// When a second last moved.
    moved_at: Option<Instant>,
    /// When the last round ended.
    round_at: Option<Instant>,
    /// Frames were drawn since the last read.
    drew: bool,
    /// Frames were drawn since the last round began, whether it read a screen or not.
    stirred: bool,
    /// When the screen moved again after it had been quiet, since the last read: new things show.
    woke_at: Option<Instant>,
    /// The counts were seen both at nothing and moving, so they can be believed.
    seen_still: bool,
    seen_moving: bool,
}

impl Motion {
    pub fn hear(&mut self, frames: f64, now: Instant) {
        if frames >= MOVING {
            // Quiet since the screen last moved and since the last round: a round may make the
            // screen draw itself, and that is no news.
            let quiet = self.moved_at.max(self.round_at).is_none_or(|last| now.saturating_duration_since(last) >= QUIET_AFTER);
            if self.woke_at.is_none() && quiet {
                self.woke_at = Some(now);
            }
            self.moved_at = Some(now);
            self.seen_moving = true;
        }
        if frames > 0.0 {
            self.drew = true;
            self.stirred = true;
        } else {
            self.seen_still = true;
        }
        self.heard_at = Some(now);
    }

    /// A round begins: it finds out which app is in front, so what is drawn from now on may be
    /// another app.
    pub fn begin(&mut self) {
        self.stirred = false;
    }

    /// A round is over. `before`: the counts as it began. After a round that read the screen,
    /// what is drawn from now on is news again. What was drawn while a round ran is never news
    /// of its own: after one that read nothing, what was news before it still is.
    pub fn passed(&mut self, before: &Motion, read: bool, now: Instant) {
        (self.drew, self.woke_at) = if read { (false, None) } else { (before.drew, before.woke_at) };
        self.round_at = Some(now);
    }

    /// Whether the counts say anything: they come, they are fresh, and this run saw them both
    /// still and moving. Counts that are always nothing, or never nothing, are not believed.
    pub fn told(&self, now: Instant) -> bool {
        self.seen_still && self.seen_moving && self.heard_at.is_some_and(|heard| now.saturating_duration_since(heard) < SAMPLE_FRESH)
    }

    /// Nothing was drawn since the last read: the screen shows what was read.
    pub fn still(&self) -> bool {
        !self.drew
    }

    /// Nothing was drawn since the last round began: the app it found is still the one in front.
    pub fn unstirred(&self) -> bool {
        !self.stirred
    }

    /// How long ago the screen moved again after a quiet time, if it did since the last read.
    pub fn woke(&self, now: Instant) -> Option<Duration> {
        self.woke_at.map(|woke| now.saturating_duration_since(woke))
    }

    /// The screen is moving at this moment: a read now would land in a scroll.
    pub fn moving(&self, now: Instant) -> bool {
        self.moved_at.is_some_and(|moved| now.saturating_duration_since(moved) < Duration::from_millis(1500))
    }
}

/// Counts messages in ten-second spans.
#[derive(Default)]
struct Flood {
    since: Option<Instant>,
    count: u32,
}

impl Flood {
    /// Ten seconds bring ten samples. Four times that is a flood.
    const MOST: u32 = 40;

    /// Takes a message in. Returns whether too many came in this span.
    fn is_one(&mut self, now: Instant) -> bool {
        if self.since.is_none_or(|since| now.saturating_duration_since(since) >= Duration::from_secs(10)) {
            (self.since, self.count) = (Some(now), 0);
        }
        self.count += 1;
        self.count > Self::MOST
    }
}

/// The frames drawn in a sample's second, when the message is a sample.
fn frames_of(sample: &Value) -> Option<f64> {
    let frames = sample.as_dictionary()?.get("CoreAnimationFramesPerSecond")?;
    frames.as_real().or_else(|| frames.as_signed_integer().map(|frames| frames as f64)).or_else(|| frames.as_unsigned_integer().map(|frames| frames as f64))
}

/// Samples the screen's frame count once a second on a stream of its own inside the tunnel.
pub struct Frames {
    motion: Arc<Mutex<(Motion, Option<String>)>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Frames {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Frames {
    pub async fn start(adapter: &mut AdapterHandle, rsd: &RsdHandshake) -> std::result::Result<Self, String> {
        let port = rsd.services.get(HUB).ok_or("the developer services are not listed")?.port;
        let stream = tokio::time::timeout(START_WITHIN, adapter.connect(port)).await.map_err(|_| "no answer from the developer services".to_string())?.map_err(|error| error.to_string())?;
        // What the screen drew before the counting began is not known: taken as drawn.
        let motion = Arc::new(Mutex::new((Motion { drew: true, stirred: true, ..Default::default() }, None)));
        let (ready, started) = tokio::sync::oneshot::channel::<std::result::Result<(), String>>();
        let task = tokio::spawn({
            let motion = motion.clone();
            async move {
                let mut server = RemoteServerClient::new(stream);
                let ended = Self::sample(&mut server, &motion, ready).await;
                lock(&motion).1 = Some(ended);
            }
        });
        let frames = Self { motion, task };
        match tokio::time::timeout(START_WITHIN, started).await {
            Ok(Ok(Ok(()))) => Ok(frames),
            Ok(Ok(Err(error))) => Err(error),
            Ok(Err(_)) => Err(lock(&frames.motion).1.clone().unwrap_or_else(|| "the channel closed".into())),
            Err(_) => Err("the frame counts did not start in time".into()),
        }
    }

    async fn sample(server: &mut RemoteServerClient<Box<dyn ReadWrite>>, motion: &Mutex<(Motion, Option<String>)>, ready: tokio::sync::oneshot::Sender<std::result::Result<(), String>>) -> String {
        let mut channel = match server.make_channel(GRAPHICS).await {
            Ok(channel) => channel,
            Err(error) => {
                let error = format!("no channel for frame counts: {error}");
                let _ = ready.send(Err(error.clone()));
                return error;
            }
        };
        // The phone sends a sample about every second whatever interval is asked for, and a
        // screen that stands still counts 0 (pymobiledevice3's notes on this channel, 2026).
        if let Err(error) = channel.call_method(Some(Value::String("startSamplingAtTimeInterval:".into())), Some(vec![AuxValue::Double(1.0)]), true).await {
            let error = format!("frame counts were not started: {error}");
            let _ = ready.send(Err(error.clone()));
            return error;
        }
        let _ = ready.send(Ok(()));
        let mut pace = Flood::default();
        loop {
            // The answer to the call and anything else that is no sample is passed over.
            match channel.read_message().await {
                Ok(message) => {
                    let now = Instant::now();
                    // A phone that sends far more than asked is not listened to: hearing it
                    // would cost more than the reads it saves.
                    if pace.is_one(now) {
                        return "the frame counts came too fast".into();
                    }
                    if let Some(frames) = message.data.as_ref().and_then(frames_of) {
                        lock(motion).0.hear(frames, now);
                    }
                }
                Err(error) => return error.to_string(),
            }
        }
    }

    /// What the counts say now, and why the sampling ended when it did.
    pub fn motion(&self) -> (Motion, Option<String>) {
        lock(&self.motion).clone()
    }

    /// A round begins. Returns the counts as they stand, for `passed`.
    pub fn begin(&self) -> Motion {
        let mut motion = lock(&self.motion);
        motion.0.begin();
        motion.0.clone()
    }

    /// A round is over, one that read the screen or not.
    pub fn passed(&self, before: &Motion, read: bool) {
        lock(&self.motion).0.passed(before, read, Instant::now());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dictionary(entries: Vec<(&str, Value)>) -> Value {
        Value::Dictionary(entries.into_iter().map(|(key, value)| (key.to_string(), value)).collect())
    }

    /// A notice as the phone archives it: an NSDictionary of the given fields. Object 1 is the
    /// dictionary, then come the names, then the values.
    fn notice(fields: Vec<(&str, Value)>) -> Archive {
        let count = fields.len() as u64;
        let uids = |from: u64| Value::Array((0..count).map(|index| Value::Uid(plist::Uid::new(from + index))).collect());
        let mut objects = vec![Value::String("$null".into()), dictionary(vec![("NS.keys", uids(2)), ("NS.objects", uids(2 + count))])];
        let (names, things): (Vec<&str>, Vec<Value>) = fields.into_iter().unzip();
        objects.extend(names.into_iter().map(|name| Value::String(name.into())));
        objects.extend(things);
        let archive = dictionary(vec![("$objects", Value::Array(objects)), ("$top", dictionary(vec![("root", Value::Uid(plist::Uid::new(1)))]))]);
        let mut bytes = vec![];
        archive.to_writer_binary(&mut bytes).unwrap();
        Archive::parse(&bytes).unwrap()
    }

    fn app(pid: u64, bundle: &str) -> App {
        App { pid, bundle: Some(bundle.into()) }
    }

    #[test]
    fn a_notice_names_the_app_and_says_whether_it_is_in_the_foreground() {
        let front = notice(vec![
            ("displayID", "com.apple.Maps".into()),
            ("pid", 412u64.into()),
            ("state", 8u64.into()),
            ("state_description", "Foreground Running".into()),
            ("elevated_state_description", "Foreground Running".into()),
            ("appName", "Maps".into()),
        ]);
        assert_eq!(Notice::from(&front), Some(Notice { app: app(412, "com.apple.Maps"), foreground: true }));
        assert_eq!(Notice::fields(&front), ["displayID", "pid", "state", "state_description", "elevated_state_description"]);
        let back = notice(vec![("displayID", "com.apple.Maps".into()), ("pid", 412u64.into()), ("state", 4u64.into()), ("state_description", "Background Running".into())]);
        assert_eq!(Notice::from(&back), Some(Notice { app: app(412, "com.apple.Maps"), foreground: false }));
        // With no words, the number says it. With no process, the notice says nothing.
        assert!(Notice::from(&notice(vec![("pid", 7u64.into()), ("state", 8u64.into())])).unwrap().foreground);
        assert!(!Notice::from(&notice(vec![("pid", 7u64.into()), ("state", 2u64.into())])).unwrap().foreground);
        assert_eq!(Notice::from(&notice(vec![("displayID", "com.apple.Maps".into()), ("state", 8u64.into())])), None);
        // A name that is no bundle id is not taken for one.
        assert_eq!(Notice::from(&notice(vec![("displayID", "Maps".into()), ("pid", 7u64.into()), ("state", 8u64.into())])).unwrap().app.bundle, None);
    }

    #[test]
    fn the_app_in_front_is_the_one_that_came_to_the_foreground_last() {
        let mut fronts = Fronts::default();
        let hear = |fronts: &mut Fronts, pid: u64, bundle: &str, foreground: bool| fronts.hear(Notice { app: app(pid, bundle), foreground });
        assert_eq!(fronts.front(), None);
        assert!(hear(&mut fronts, 1, "com.apple.Maps", true));
        // The same app said again is no change.
        assert!(!hear(&mut fronts, 1, "com.apple.Maps", true));
        // Another app comes to the front before the first has left it.
        assert!(hear(&mut fronts, 2, "com.apple.mobilesafari", true));
        assert_eq!(fronts.front(), Some(&app(2, "com.apple.mobilesafari")));
        // The one behind leaves: the front stays.
        assert!(!hear(&mut fronts, 1, "com.apple.Maps", false));
        // The front leaves: the Home Screen shows.
        assert!(hear(&mut fronts, 2, "com.apple.mobilesafari", false));
        assert_eq!(fronts.front(), None);
        // An app that was never in front and ends changes nothing.
        assert!(!hear(&mut fronts, 9, "com.example.mail", false));
        // Notices that were missed do not let the list grow.
        for pid in 10..40 {
            hear(&mut fronts, pid, "com.example.app", true);
        }
        assert_eq!(fronts.up.len(), 8);
        assert_eq!(fronts.front().map(|app| app.pid), Some(39));
    }

    #[test]
    fn the_frame_counts_say_when_the_screen_stood_still_and_when_it_moved_again() {
        let start = Instant::now();
        let at = |seconds: u64| start + Duration::from_secs(seconds);
        let mut motion = Motion::default();
        // Not believed before they were seen both still and moving.
        motion.hear(60.0, at(0));
        assert!(!motion.told(at(0)));
        motion.hear(0.0, at(1));
        assert!(motion.told(at(1)));
        assert!(motion.moving(at(1)) && !motion.moving(at(2)));
        // A read, then nothing drawn: the screen shows what was read.
        let before = motion.clone();
        motion.passed(&before, true, at(1));
        motion.hear(0.0, at(2));
        assert!(motion.still() && motion.woke(at(2)).is_none());
        // The clock ticks over: something drew, the screen did not move.
        motion.hear(1.0, at(3));
        assert!(!motion.still() && motion.woke(at(3)).is_none() && !motion.moving(at(3)));
        // The owner scrolls after the quiet: new things show, and for how long is counted.
        motion.hear(58.0, at(5));
        motion.hear(58.0, at(6));
        assert_eq!(motion.woke(at(7)), Some(Duration::from_secs(2)));
        assert!(motion.moving(at(6)));
        // A scroll that goes on is no new waking after the next read.
        let before = motion.clone();
        motion.passed(&before, true, at(6));
        motion.hear(60.0, at(7));
        assert!(motion.woke(at(7)).is_none() && !motion.still());
        // Counts that stopped coming say nothing.
        assert!(!motion.told(at(30)));
        // One sample a second is no flood, however long it goes on; forty in a moment is one.
        let mut pace = Flood::default();
        assert!((0..120).all(|second| !pace.is_one(at(second))));
        let mut pace = Flood::default();
        assert_eq!((0..60).filter(|_| pace.is_one(at(0))).count(), 20);
        // A round that read nothing leaves what was news before it, and what was drawn while it
        // ran is no news: the round may have made the screen draw itself.
        let mut motion = Motion::default();
        motion.hear(0.0, at(40));
        motion.begin();
        let before = motion.clone();
        motion.hear(30.0, at(41));
        assert!(!motion.unstirred());
        motion.passed(&before, false, at(41));
        assert!(motion.still() && motion.woke(at(41)).is_none());
        // Nor is what the screen draws in the moment after a round a waking.
        motion.hear(30.0, at(42));
        assert!(!motion.still() && motion.woke(at(42)).is_none());
        // A round that read nothing does not forget that the screen woke before it.
        motion.hear(0.0, at(43));
        motion.hear(0.0, at(46));
        motion.hear(30.0, at(47));
        assert!(motion.woke(at(47)).is_some());
        motion.begin();
        let before = motion.clone();
        assert!(motion.unstirred());
        motion.passed(&before, false, at(48));
        assert!(motion.woke(at(48)).is_some() && !motion.still());
        // A sample is a dictionary with the count in it, whole or not.
        assert_eq!(frames_of(&dictionary(vec![("CoreAnimationFramesPerSecond", 58u64.into()), ("XRVideoCardRunTimeStamp", 1u64.into())])), Some(58.0));
        assert_eq!(frames_of(&dictionary(vec![("CoreAnimationFramesPerSecond", Value::Real(0.0))])), Some(0.0));
        assert_eq!(frames_of(&dictionary(vec![("Device Utilization %", 3u64.into())])), None);
        assert_eq!(frames_of(&Value::String("ok".into())), None);
    }
}
