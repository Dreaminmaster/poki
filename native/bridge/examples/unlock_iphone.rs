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
use std::{io::Read, time::Duration};

#[path = "../src/stream.rs"]
mod stream;

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
    // Only the line ending: a custom alphanumeric passcode may start or end with a space.
    let pin = pin.trim_end_matches(['\r', '\n']);
    if !(4..=128).contains(&pin.len()) || !pin.bytes().all(|c| key_for(c).is_some()) {
        return Err("Expected a passcode of 4 to 128 characters typed on a US keyboard; nothing sent".into());
    }
    tokio::time::timeout(Duration::from_secs(25), unlock(&args[2], pin, &keypad)).await??;
    Ok(())
}

/// iOS's own keypad codes (4 or 6 digits) submit themselves on the keypad, where the taps were
/// verified on a phone. A custom numeric code of another length, or an alphanumeric one, goes in as
/// hardware keyboard keys and Return, which the lock screen's field accepts for both.
fn on_keypad(pin: &str) -> bool {
    (pin.len() == 4 || pin.len() == 6) && pin.bytes().all(|c| c.is_ascii_digit())
}

const LEFT_SHIFT: u64 = 0xE1;
const RETURN: u64 = 0x28;

/// The HID keyboard usage (page 0x07, US layout) for a printable ASCII character, and whether it
/// needs Shift.
fn key_for(c: u8) -> Option<(u64, bool)> {
    Some(match c {
        b'a'..=b'z' => (0x04 + (c - b'a') as u64, false),
        b'A'..=b'Z' => (0x04 + (c - b'A') as u64, true),
        b'1'..=b'9' => (0x1E + (c - b'1') as u64, false),
        b'0' => (0x27, false),
        b' ' => (0x2C, false),
        b'!' => (0x1E, true), b'@' => (0x1F, true), b'#' => (0x20, true), b'$' => (0x21, true),
        b'%' => (0x22, true), b'^' => (0x23, true), b'&' => (0x24, true), b'*' => (0x25, true),
        b'(' => (0x26, true), b')' => (0x27, true),
        b'-' => (0x2D, false), b'_' => (0x2D, true), b'=' => (0x2E, false), b'+' => (0x2E, true),
        b'[' => (0x2F, false), b'{' => (0x2F, true), b']' => (0x30, false), b'}' => (0x30, true),
        b'\\' => (0x31, false), b'|' => (0x31, true), b';' => (0x33, false), b':' => (0x33, true),
        b'\'' => (0x34, false), b'"' => (0x34, true), b'`' => (0x35, false), b'~' => (0x35, true),
        b',' => (0x36, false), b'<' => (0x36, true), b'.' => (0x37, false), b'>' => (0x37, true),
        b'/' => (0x38, false), b'?' => (0x38, true),
        _ => return None,
    })
}

async fn press(keys: &mut IndigoHidClient, usage: u64) -> Result<()> {
    keys.send_keyboard(usage, ButtonState::Down).await?;
    tokio::time::sleep(Duration::from_millis(60)).await;
    keys.send_keyboard(usage, ButtonState::Up).await?;
    Ok(())
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
        let start = std::time::Instant::now();
        if !on_keypad(pin) {
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
            drop(buttons);
            return Ok(start.elapsed().as_millis());
        }
        let mut touch = UniversalHidServiceClient::connect_rsd(&mut adapter, &mut rsd).await?;
        tokio::time::sleep(Duration::from_millis(1000)).await;
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
