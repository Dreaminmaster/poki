use idevice::{
    IdeviceService, RsdService,
    core_device::hid::{
        ButtonState, IndigoHidClient, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE,
        UniversalHidServiceClient,
    },
    core_device_proxy::CoreDeviceProxy,
    rsd::RsdHandshake,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};
use serde::Deserialize;
use serde_json::Value as Json;
use std::{io::Read, time::Duration};

#[path = "../src/stream.rs"]
mod stream;
// The bridge's own tree reader; this helper uses only part of it.
#[allow(dead_code)]
#[path = "../src/ax.rs"]
mod ax;
#[allow(dead_code)]
#[path = "../src/display.rs"]
mod display;

// display.rs reads this from the crate root, as in the bridge.
const ROUTES_BY_PANEL: bool = true;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Keypad {
    width: f64,
    height: f64,
    // Indexed by the digit, starting with zero; coordinates are logical screen points.
    digits: [[f64; 2]; 10],
}

impl Keypad {
    fn validate(&self) -> Result<()> {
        if !self.width.is_finite()
            || !self.height.is_finite()
            || self.width < 2.0
            || self.height < 2.0
            || self.digits.iter().enumerate().any(|(i, point)| {
                let [x, y] = *point;
                !x.is_finite()
                    || !y.is_finite()
                    || x < 0.0
                    || y < 0.0
                    || x >= self.width
                    || y >= self.height
                    || self.digits[..i].contains(point)
            })
        {
            return Err("Keypad must contain ten distinct points inside the screen".into());
        }
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 || args[1] != "--udid" || args[3] != "--keypad" || args[2].is_empty() {
        return Err("usage: unlock_iphone --udid ID --keypad LAYOUT.json < passcode".into());
    }
    let keypad: Keypad = serde_json::from_slice(&std::fs::read(&args[4])?)?;
    keypad.validate()?;
    let mut pin = String::new();
    std::io::stdin().take(512).read_to_string(&mut pin)?;
    // Only the line ending: an alphanumeric passcode may start or end with a space.
    let pin = pin.trim_end_matches(['\r', '\n']);
    if !(4..=128).contains(&pin.len()) || !pin.bytes().all(|c| key_for(c).is_some()) {
        return Err(
            "Expected a passcode of 4 to 128 characters typed on a US keyboard; nothing sent"
                .into(),
        );
    }
    if keypad_code(pin) {
        tokio::time::timeout(Duration::from_secs(25), unlock(&args[2], pin, &keypad)).await??;
    } else {
        tokio::time::timeout(Duration::from_secs(50), unlock_checked(&args[2], pin)).await??;
    }
    Ok(())
}

/// iOS's 4- and 6-digit codes submit themselves on the keypad, on the path verified on a phone.
fn keypad_code(pin: &str) -> bool {
    (pin.len() == 4 || pin.len() == 6) && pin.bytes().all(|c| c.is_ascii_digit())
}

// --- Any other passcode: entered only where the accessibility tree shows the lock screen's entry. ---

const SPRINGBOARD: &str = "com.apple.springboard";
const TITLES: [&str; 3] = ["Enter Passcode", "输入密码", "輸入密碼"];
const SUBMIT: [&str; 8] = ["OK", "Done", "Enter", "好", "完成", "确定", "確定", "好的"];

/// What the lock screen offers for entering a passcode, read from one accessibility tree.
#[derive(Debug, PartialEq)]
enum Entry {
    /// The numeric keypad: each digit's centre and the key that submits (OK), in screen points.
    Keypad {
        digits: [(f64, f64); 10],
        submit: Option<(f64, f64)>,
    },
    /// The passcode field (a SecureTextField) with nothing in it.
    EmptyField,
}

#[derive(Debug, PartialEq)]
struct Screen {
    width: f64,
    height: f64,
    entry: Entry,
}

fn text<'a>(element: &'a Json, key: &str) -> &'a str {
    element.get(key).and_then(Json::as_str).unwrap_or("").trim()
}

fn frame(element: &Json) -> Option<(f64, f64, f64, f64)> {
    let f = element.get("frame")?;
    let n = |k: &str| f.get(k).and_then(Json::as_f64);
    Some((n("x")?, n("y")?, n("width")?, n("height")?))
}

/// The centre of an element that lies wholly on the screen.
fn on_screen(element: &Json, width: f64, height: f64) -> Option<(f64, f64)> {
    let (x, y, w, h) = frame(element)?;
    (w > 0.0 && h > 0.0 && x >= 0.0 && y >= 0.0 && x + w <= width + 0.5 && y + h <= height + 0.5)
        .then_some((x + w / 2.0, y + h / 2.0))
}

/// Reads the lock screen's passcode entry from a tree, or says why it is not confirmed. Nothing is
/// entered unless SpringBoard alone is in front, its "Enter Passcode" title is shown, and either a
/// complete keypad with no passcode field holding text, or an empty passcode field, is on screen.
fn lock_screen(tree: &Json) -> std::result::Result<Screen, &'static str> {
    let front = tree
        .get("foreground_app")
        .ok_or("the app in front is not known")?;
    if front.get("bundle_id").and_then(Json::as_str) != Some(SPRINGBOARD) {
        return Err("the app in front is not the lock screen");
    }
    let elements = tree
        .get("elements")
        .and_then(Json::as_array)
        .ok_or("no accessibility elements")?;
    let root = elements
        .iter()
        .find(|e| text(e, "role") == "Application")
        .ok_or("no screen size")?;
    let (_, _, width, height) = frame(root).ok_or("no screen size")?;
    if width < 2.0 || height < 2.0 {
        return Err("no screen size");
    }
    let mut title = false;
    let mut digits: [Option<(f64, f64)>; 10] = [None; 10];
    let mut duplicate = false;
    let mut submit = None;
    let mut fields = vec![];
    for e in elements {
        let role = text(e, "role");
        let label = text(e, "label");
        let enabled = e.get("enabled").and_then(Json::as_bool) != Some(false);
        if role == "StaticText" && TITLES.iter().any(|t| label.eq_ignore_ascii_case(t)) {
            title = true;
        }
        if (role == "Button" || role == "Key") && enabled {
            let mut chars = label.chars();
            if let (Some(d @ '0'..='9'), next) = (chars.next(), chars.next()) {
                if matches!(next, None | Some(',') | Some(' ')) {
                    if let Some(point) = on_screen(e, width, height) {
                        let slot = &mut digits[d as usize - '0' as usize];
                        duplicate |= slot.is_some();
                        *slot = Some(point);
                    }
                }
            } else if SUBMIT.contains(&label) {
                submit = submit.or(on_screen(e, width, height));
            }
        }
        if role == "SecureTextField" && on_screen(e, width, height).is_some() {
            let value = text(e, "value");
            fields.push(value.is_empty() || value == text(e, "placeholder"));
        }
    }
    if !title {
        return Err("the lock screen's passcode entry is not shown");
    }
    if fields.iter().any(|empty| !empty) {
        return Err("the passcode field already holds text");
    }
    if !duplicate && digits.iter().all(Option::is_some) {
        let digits = digits.map(|d| d.unwrap());
        return Ok(Screen {
            width,
            height,
            entry: Entry::Keypad { digits, submit },
        });
    }
    if fields.len() == 1 {
        return Ok(Screen {
            width,
            height,
            entry: Entry::EmptyField,
        });
    }
    Err("no empty passcode entry is on screen")
}

/// How a passcode goes in on the screen read, or why it cannot.
fn plan(pin: &str, screen: &Screen) -> std::result::Result<(), &'static str> {
    let digits = pin.bytes().all(|c| c.is_ascii_digit());
    match (&screen.entry, digits) {
        // A custom numeric code waits for OK after its last digit.
        (
            Entry::Keypad {
                submit: Some(_), ..
            },
            true,
        ) => Ok(()),
        (Entry::Keypad { submit: None, .. }, true) => Err("the keypad's OK key is not shown"),
        (Entry::Keypad { .. }, false) => {
            Err("the lock screen shows a keypad, but the passcode has letters or symbols")
        }
        (Entry::EmptyField, _) => Ok(()),
    }
}

const LEFT_SHIFT: u64 = 0xE1;
const RETURN: u64 = 0x28;

/// The HID keyboard usage (page 0x07, US layout) of a printable ASCII character, and whether it
/// needs Shift.
fn key_for(c: u8) -> Option<(u64, bool)> {
    Some(match c {
        b'a'..=b'z' => (0x04 + (c - b'a') as u64, false),
        b'A'..=b'Z' => (0x04 + (c - b'A') as u64, true),
        b'1'..=b'9' => (0x1E + (c - b'1') as u64, false),
        b'0' => (0x27, false),
        b' ' => (0x2C, false),
        b'!' => (0x1E, true),
        b'@' => (0x1F, true),
        b'#' => (0x20, true),
        b'$' => (0x21, true),
        b'%' => (0x22, true),
        b'^' => (0x23, true),
        b'&' => (0x24, true),
        b'*' => (0x25, true),
        b'(' => (0x26, true),
        b')' => (0x27, true),
        b'-' => (0x2D, false),
        b'_' => (0x2D, true),
        b'=' => (0x2E, false),
        b'+' => (0x2E, true),
        b'[' => (0x2F, false),
        b'{' => (0x2F, true),
        b']' => (0x30, false),
        b'}' => (0x30, true),
        b'\\' => (0x31, false),
        b'|' => (0x31, true),
        b';' => (0x33, false),
        b':' => (0x33, true),
        b'\'' => (0x34, false),
        b'"' => (0x34, true),
        b'`' => (0x35, false),
        b'~' => (0x35, true),
        b',' => (0x36, false),
        b'<' => (0x36, true),
        b'.' => (0x37, false),
        b'>' => (0x37, true),
        b'/' => (0x38, false),
        b'?' => (0x38, true),
        _ => return None,
    })
}

async fn press<R: idevice::ReadWrite>(keys: &mut IndigoHidClient<R>, usage: u64) -> Result<()> {
    keys.send_keyboard(usage, ButtonState::Down).await?;
    tokio::time::sleep(Duration::from_millis(60)).await;
    keys.send_keyboard(usage, ButtonState::Up).await?;
    Ok(())
}

async fn tap<R: idevice::ReadWrite>(
    touch: &mut UniversalHidServiceClient<R>,
    point: (f64, f64),
    width: f64,
    height: f64,
) -> Result<()> {
    let x = (point.0 / (width - 1.0) * 65535.0)
        .round()
        .clamp(0.0, 65535.0) as u16;
    let y = (point.1 / (height - 1.0) * 65535.0)
        .round()
        .clamp(0.0, 65535.0) as u16;
    touch
        .send_touchscreen(TOUCHSCREEN_STATE_CONTACT, x, y, None)
        .await?;
    tokio::time::sleep(Duration::from_millis(150)).await;
    touch
        .send_touchscreen(TOUCHSCREEN_STATE_RELEASE, x, y, None)
        .await?;
    tokio::time::sleep(Duration::from_millis(450)).await;
    Ok(())
}

fn refused(why: &str) -> Box<dyn std::error::Error + Send + Sync> {
    format!("Nothing was entered: {why}. Inspect the phone; do not automatically retry.").into()
}

async fn unlock_checked(udid: &str, pin: &str) -> Result<()> {
    let mut mux = UsbmuxdConnection::default().await?;
    let device = mux.get_device(udid).await?;
    let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "poki-unlock-skill");
    let proxy = CoreDeviceProxy::connect(&provider).await?;
    let port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let mut rsd = RsdHandshake::new(adapter.connect(port).await?).await?;
    let read = Duration::from_secs(8);
    // A passcode entry already up before the wake may hold digits the owner started typing: the
    // tree cannot show keypad dots, so only an empty field is accepted then.
    if let Ok(before) = ax::read_tree_with_timeout(&mut adapter, &rsd, false, read).await {
        match lock_screen(&before) {
            Ok(Screen {
                entry: Entry::EmptyField,
                ..
            }) => {}
            Ok(_) => {
                return Err(refused(
                    "the keypad was already up and may hold the owner's digits",
                ));
            }
            Err(why @ "the passcode field already holds text") => return Err(refused(why)),
            Err(_) => {}
        }
    }
    let mut media = stream::start_screen_media_stream(&mut adapter, &mut rsd, 1).await?;
    let outcome: Result<u128> = async {
        tokio::time::sleep(Duration::from_millis(1000)).await;
        let mut buttons = IndigoHidClient::connect_rsd(&mut adapter, &mut rsd).await?;
        buttons.send_button(0x0c, 0x40, ButtonState::Down).await?;
        tokio::time::sleep(Duration::from_millis(80)).await;
        buttons.send_button(0x0c, 0x40, ButtonState::Up).await?;
        tokio::time::sleep(Duration::from_millis(2000)).await;
        let tree = ax::read_tree_with_timeout(&mut adapter, &rsd, false, read)
            .await
            .map_err(|_| refused("the lock screen could not be read"))?;
        let screen = lock_screen(&tree).map_err(refused)?;
        plan(pin, &screen).map_err(refused)?;
        // Again right before the first key: the screen must still be the same entry.
        let tree = ax::read_tree_with_timeout(&mut adapter, &rsd, false, read)
            .await
            .map_err(|_| refused("the lock screen could not be read again"))?;
        let again = lock_screen(&tree).map_err(refused)?;
        if std::mem::discriminant(&again.entry) != std::mem::discriminant(&screen.entry) {
            return Err(refused(
                "the lock screen changed while it was being checked",
            ));
        }
        let start = std::time::Instant::now();
        match &again.entry {
            Entry::Keypad { digits, submit } => {
                let submit = submit.ok_or_else(|| refused("the keypad's OK key is not shown"))?;
                let mut touch =
                    UniversalHidServiceClient::connect_rsd(&mut adapter, &mut rsd).await?;
                tokio::time::sleep(Duration::from_millis(1000)).await;
                for digit in pin.bytes() {
                    tap(
                        &mut touch,
                        digits[(digit - b'0') as usize],
                        again.width,
                        again.height,
                    )
                    .await?;
                }
                tap(&mut touch, submit, again.width, again.height).await?;
                tokio::time::sleep(Duration::from_millis(1000)).await;
                drop(touch);
            }
            Entry::EmptyField => {
                for c in pin.bytes() {
                    let (usage, shift) = key_for(c).ok_or("unsupported character")?;
                    if shift {
                        buttons.send_keyboard(LEFT_SHIFT, ButtonState::Down).await?;
                    }
                    press(&mut buttons, usage).await?;
                    if shift {
                        buttons.send_keyboard(LEFT_SHIFT, ButtonState::Up).await?;
                    }
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
                press(&mut buttons, RETURN).await?;
                tokio::time::sleep(Duration::from_millis(1000)).await;
            }
        }
        drop(buttons);
        Ok(start.elapsed().as_millis())
    }
    .await;
    let stopped = media.client.stop_media_stream().await;
    let elapsed = outcome?;
    stopped?;
    println!(
        "{}",
        serde_json::json!({"input_sent": true, "unlock_verified": false,
        "tap_phase_ms": elapsed, "instruction": "Inspect a fresh screenshot before reporting success. Do not automatically retry."})
    );
    Ok(())
}

#[cfg(test)]
mod unlock_tests {
    use super::*;
    use serde_json::json;

    fn tree(front: &str, extra: Vec<Json>) -> Json {
        let mut elements = vec![
            json!({"role":"Application","label":"SpringBoard","frame":{"x":0,"y":0,"width":402,"height":874}}),
            json!({"role":"StaticText","label":"Enter Passcode","frame":{"x":100,"y":150,"width":200,"height":30}}),
        ];
        elements.extend(extra);
        json!({"foreground_app":{"bundle_id":front},"elements":elements})
    }

    fn keypad(with_ok: bool) -> Vec<Json> {
        let mut keys: Vec<Json> = (0..10)
            .map(|d| json!({"role":"Button","label":if d == 2 { "2, ABC".to_string() } else { d.to_string() },
                "frame":{"x":50 + (d % 3) * 100,"y":300 + (d / 3) * 90,"width":80,"height":80}}))
            .collect();
        if with_ok {
            keys.push(json!({"role":"Button","label":"OK","frame":{"x":250,"y":660,"width":80,"height":80}}));
        }
        keys
    }

    fn field(value: &str) -> Json {
        json!({"role":"SecureTextField","value":value,"placeholder":"Passcode","frame":{"x":50,"y":250,"width":300,"height":44}})
    }

    #[test]
    fn an_empty_field_on_the_lock_screen_takes_any_passcode() {
        let screen = lock_screen(&tree(SPRINGBOARD, vec![field("")])).unwrap();
        assert_eq!(screen.entry, Entry::EmptyField);
        assert_eq!(plan("Bear 2 honey!", &screen), Ok(()));
        assert_eq!(plan("12345678", &screen), Ok(()));
        let placeholder = lock_screen(&tree(SPRINGBOARD, vec![field("Passcode")])).unwrap();
        assert_eq!(placeholder.entry, Entry::EmptyField);
    }

    #[test]
    fn a_custom_numeric_code_needs_the_whole_keypad_and_ok() {
        let screen = lock_screen(&tree(SPRINGBOARD, keypad(true))).unwrap();
        assert!(matches!(
            screen.entry,
            Entry::Keypad {
                submit: Some(_),
                ..
            }
        ));
        assert_eq!(plan("12345678", &screen), Ok(()));
        assert!(plan("abc12345", &screen).is_err());
        let no_ok = lock_screen(&tree(SPRINGBOARD, keypad(false))).unwrap();
        assert!(plan("12345678", &no_ok).is_err());
        let mut short = keypad(true);
        short.remove(5);
        assert!(lock_screen(&tree(SPRINGBOARD, short)).is_err());
        let mut twice = keypad(true);
        twice.push(
            json!({"role":"Button","label":"7","frame":{"x":10,"y":10,"width":20,"height":20}}),
        );
        assert!(lock_screen(&tree(SPRINGBOARD, twice)).is_err());
    }

    #[test]
    fn nothing_is_entered_anywhere_but_an_empty_lock_screen_entry() {
        // Another app in front, even with a secure field: the passcode would land in that app.
        assert!(lock_screen(&tree("com.tencent.xin", vec![field("")])).is_err());
        assert!(lock_screen(&json!({"elements":[]})).is_err());
        // Text already in the field.
        assert!(lock_screen(&tree(SPRINGBOARD, vec![field("••")])).is_err());
        assert!(
            lock_screen(&tree(
                SPRINGBOARD,
                [keypad(true), vec![field("•")]].concat()
            ))
            .is_err()
        );
        // No passcode title: SpringBoard's Home Screen or a notification.
        let mut no_title = tree(SPRINGBOARD, vec![field("")]);
        no_title["elements"].as_array_mut().unwrap().remove(1);
        assert!(lock_screen(&no_title).is_err());
        // A field off the screen does not count.
        let off = json!({"role":"SecureTextField","value":"","frame":{"x":50,"y":900,"width":300,"height":44}});
        assert!(lock_screen(&tree(SPRINGBOARD, vec![off])).is_err());
        // Two fields: which one has focus is not known.
        assert!(lock_screen(&tree(SPRINGBOARD, vec![field(""), field("")])).is_err());
    }

    #[test]
    fn only_printable_ascii_maps_to_keys() {
        assert_eq!(key_for(b'a'), Some((0x04, false)));
        assert_eq!(key_for(b'Z'), Some((0x1D, true)));
        assert_eq!(key_for(b'0'), Some((0x27, false)));
        assert_eq!(key_for(b'?'), Some((0x38, true)));
        assert_eq!(key_for(b'\n'), None);
        assert_eq!(key_for(0xC3), None);
        assert!(keypad_code("1234") && keypad_code("813790"));
        assert!(!keypad_code("12345") && !keypad_code("abcd"));
    }
}

async fn unlock(udid: &str, pin: &str, keypad: &Keypad) -> Result<()> {
    let mut mux = UsbmuxdConnection::default().await?;
    let device = mux.get_device(udid).await?;
    let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "poki-unlock-skill");
    let proxy = CoreDeviceProxy::connect(&provider).await?;
    let port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let mut rsd = RsdHandshake::new(adapter.connect(port).await?).await?;
    let mut media = stream::start_screen_media_stream(&mut adapter, &mut rsd, 1).await?;
    let outcome: Result<u128> = async {
        tokio::time::sleep(Duration::from_millis(1000)).await;
        let mut buttons = IndigoHidClient::connect_rsd(&mut adapter, &mut rsd).await?;
        buttons.send_button(0x0c, 0x40, ButtonState::Down).await?;
        tokio::time::sleep(Duration::from_millis(80)).await;
        buttons.send_button(0x0c, 0x40, ButtonState::Up).await?;
        tokio::time::sleep(Duration::from_millis(2000)).await;
        let mut touch = UniversalHidServiceClient::connect_rsd(&mut adapter, &mut rsd).await?;
        tokio::time::sleep(Duration::from_millis(1000)).await;
        let start = std::time::Instant::now();
        for digit in pin.bytes() {
            let [x, y] = keypad.digits[(digit - b'0') as usize];
            let x = (x / (keypad.width - 1.0) * 65535.0).round() as u16;
            let y = (y / (keypad.height - 1.0) * 65535.0).round() as u16;
            touch
                .send_touchscreen(TOUCHSCREEN_STATE_CONTACT, x, y, None)
                .await?;
            tokio::time::sleep(Duration::from_millis(150)).await;
            touch
                .send_touchscreen(TOUCHSCREEN_STATE_RELEASE, x, y, None)
                .await?;
            tokio::time::sleep(Duration::from_millis(450)).await;
        }
        tokio::time::sleep(Duration::from_millis(1000)).await;
        // Keep both input connections alive through the final wait.
        drop(touch);
        drop(buttons);
        Ok(start.elapsed().as_millis())
    }
    .await;
    let stopped = media.client.stop_media_stream().await;
    let elapsed = outcome?;
    stopped?;
    println!(
        "{}",
        serde_json::json!({"input_sent": true, "unlock_verified": false,
        "tap_phase_ms": elapsed, "instruction": "Inspect a fresh screenshot before reporting success. Do not automatically retry."})
    );
    Ok(())
}
