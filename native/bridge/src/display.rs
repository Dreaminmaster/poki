use super::Result;
use idevice::{
    core_device::CoreDeviceServiceClient, rsd::RsdHandshake, tcp::handle::AdapterHandle,
};
use serde_json::Value;
use std::{collections::BTreeMap, sync::Mutex, time::Duration};

/// The active panel of a phone that has more than one built-in panel.
pub struct Display {
    pub id: i64,
    pub unique_id: String,
    pub primary: bool,
    pub width: f64,
    pub height: f64,
    pub orientation: Option<u64>,
    /// Clockwise rotation of the panel's content from its native orientation, in degrees.
    pub rotation: u16,
}

/// Where one request goes. Without a display these are main's values: display 1 for input media,
/// the DVT screenshot, unrotated touch, the cached AX subscription and a 4 s read before text input.
pub struct Route<'a> {
    pub media_display: i64,
    /// The panel whose touchscreen takes the input; `None` is the main touchscreen.
    pub touch_panel: Option<&'a str>,
    /// The panel to capture through CoreDevice; `None` takes the DVT screenshot.
    pub capture: Option<&'a str>,
    pub rotation: u16,
    pub live_ax: bool,
    pub pre_input_read: Duration,
}

pub fn route(display: Option<&Display>) -> Route<'_> {
    Route {
        media_display: display.map_or(1, |d| d.id),
        touch_panel: display.map(|d| d.unique_id.as_str()),
        capture: display.filter(|d| !d.primary).map(|d| d.unique_id.as_str()),
        rotation: display.map_or(0, |d| d.rotation),
        live_ax: display.is_some(),
        pre_input_read: if display.is_some() { LIVE_READ } else { CACHED_READ },
    }
}
const CACHED_READ: Duration = Duration::from_secs(4);
// Reading a second panel element by element took 4.4 to 4.9 s warm on the phone it was measured
// on, so the cached read's 4 s cannot hold it.
const LIVE_READ: Duration = Duration::from_secs(10);

/// Maps a point normalized to the screen as the user sees it (0..=65535 on both axes) onto the
/// touchscreen's native axes. The digitizer reports in the panel's native orientation, so a panel
/// showing rotated content needs the inverse rotation. Calibrated on a two-panel iPhone whose inner
/// panel reported `rot90` in landscape: unrotated, a tap aimed at screen (150, 621) of 951 x 669
/// points opened the control at the top left. Of the four quarter turns, only
/// screen = (1 - native_y, native_x) puts the touch there, at about (67, 106).
pub fn to_panel(rotation: u16, x: u16, y: u16) -> (u16, u16) {
    match rotation {
        90 => (y, u16::MAX - x),
        180 => (u16::MAX - x, u16::MAX - y),
        270 => (u16::MAX - y, x),
        _ => (x, y),
    }
}

// What each phone seen by this process said about its built-in panels. Their number does not
// change, so a phone that reported one panel is not asked again. Neither is one that failed to
// answer GIVES_UP_AFTER times in a row: it then keeps main's path without paying for the query.
static PANELS: Mutex<BTreeMap<String, Panels>> = Mutex::new(BTreeMap::new());
#[derive(Clone, Copy, PartialEq, Debug)]
enum Panels {
    One,
    Several,
    Unanswered(u8),
}
const GIVES_UP_AFTER: u8 = 3;
const QUERY_WITHIN: Duration = Duration::from_secs(2);

/// The active panel of a phone with more than one built-in panel, and `None` for every other
/// phone. A phone that does not advertise CoreDevice device information, reports one built-in
/// panel, or does not answer the query is treated as having one panel and keeps main's path. Once a
/// phone has reported several panels, a failed query is an error: main's path would then read and
/// touch the wrong panel.
pub async fn active(adapter: &mut AdapterHandle, rsd: &RsdHandshake) -> Result<Option<Display>> {
    active_within(adapter, rsd, QUERY_WITHIN).await
}

pub async fn active_within(
    adapter: &mut AdapterHandle,
    rsd: &RsdHandshake,
    limit: Duration,
) -> Result<Option<Display>> {
    let known = panels_known(rsd);
    let Some(port) = rsd
        .services
        .get(DEVICE_INFO)
        .filter(|_| known != Some(false))
        .map(|service| service.port)
    else {
        return Ok(None);
    };
    let phone = phone(rsd);
    // Boxed so the query does not enlarge every input and read future that awaits it; inline, the
    // tap path overflowed the 2 MiB stack of a debug test thread.
    let answer = tokio::time::timeout(limit.min(QUERY_WITHIN), Box::pin(query(adapter, port)))
        .await
        .unwrap_or_else(|_| Err("Display query timed out".into()));
    let (multiple, display) = decide(known == Some(true), answer);
    let mut panels = PANELS.lock().unwrap();
    let before = panels.get(&phone).copied();
    panels.insert(phone, remember(before, multiple));
    display
}

fn remember(before: Option<Panels>, multiple: Option<bool>) -> Panels {
    match (multiple, before) {
        (Some(true), _) => Panels::Several,
        (Some(false), _) => Panels::One,
        // A phone known to have several panels keeps that through a failed query.
        (None, Some(Panels::Several)) => Panels::Several,
        (None, Some(Panels::Unanswered(n))) if n + 1 >= GIVES_UP_AFTER => Panels::One,
        (None, Some(Panels::Unanswered(n))) => Panels::Unanswered(n + 1),
        (None, _) => Panels::Unanswered(1),
    }
}

const DEVICE_INFO: &str = "com.apple.coredevice.deviceinfo";
fn phone(rsd: &RsdHandshake) -> String {
    rsd.properties
        .get("UniqueDeviceID")
        .and_then(plist::Value::as_string)
        .unwrap_or(rsd.uuid.as_str())
        .to_owned()
}
// `None` while the phone has not yet answered the display query.
fn panels_known(rsd: &RsdHandshake) -> Option<bool> {
    if !super::ROUTES_BY_PANEL || !rsd.services.contains_key(DEVICE_INFO) {
        return Some(false);
    }
    match PANELS.lock().unwrap().get(&phone(rsd)) {
        Some(Panels::One) => Some(false),
        Some(Panels::Several) => Some(true),
        Some(Panels::Unanswered(_)) | None => None,
    }
}

/// Whether the phone has more than one built-in panel, asking it when that is not yet known.
/// `None` when it did not answer.
pub async fn multiple(adapter: &mut AdapterHandle, rsd: &RsdHandshake) -> Option<bool> {
    if panels_known(rsd).is_none() {
        let _ = active(adapter, rsd).await;
    }
    panels_known(rsd)
}

/// How long the accessibility read before text input may take on this phone.
pub async fn pre_input_read(adapter: &mut AdapterHandle, rsd: &RsdHandshake) -> Duration {
    if multiple(adapter, rsd).await == Some(true) {
        LIVE_READ
    } else {
        CACHED_READ
    }
}

async fn query(adapter: &mut AdapterHandle, port: u16) -> Result<Value> {
    let mut client = CoreDeviceServiceClient::new(adapter.connect(port).await?).await?;
    let info = client
        .invoke_with_plist(
            "com.apple.coredevice.feature.getdisplayinfo",
            plist::Dictionary::new(),
        )
        .await?;
    Ok(serde_json::to_value(info)?)
}

// What one answer settles: whether the phone has several panels, when the answer says, and the
// display to route by.
fn decide(known_multiple: bool, answer: Result<Value>) -> (Option<bool>, Result<Option<Display>>) {
    let failure = match answer {
        Ok(info) => match info["displays"].as_array() {
            Some(displays) => {
                let integrated: Vec<_> =
                    displays.iter().filter(|d| d["external"] == false).collect();
                if integrated.len() < 2 {
                    return (Some(false), Ok(None));
                }
                return (Some(true), select(&integrated, &info).map(Some));
            }
            None => "Display list is missing".into(),
        },
        Err(error) => error,
    };
    (None, if known_multiple { Err(failure) } else { Ok(None) })
}

fn select(integrated: &[&Value], info: &Value) -> Result<Display> {
    let active: Vec<_> = integrated
        .iter()
        .copied()
        .filter(|d| d["active"] == true)
        .collect();
    if active.len() != 1 {
        return Err("Exactly one active integrated display is required".into());
    }
    let d = active[0];
    let id = d["displayId"]
        .as_i64()
        .filter(|id| *id > 0)
        .ok_or("Invalid display ID")?;
    let unique_id = d["uniqueId"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or("Display unique ID is missing")?
        .to_owned();
    let scale = d["pointScale"]
        .as_f64()
        .filter(|v| v.is_finite() && *v > 0.0 && *v <= 5.0)
        .ok_or("Invalid display scale")?;
    let dimension = |index: usize| -> Result<f64> {
        Ok(d["bounds"][1][index]
            .as_f64()
            .filter(|v| v.is_finite() && *v > 0.0)
            .ok_or("Invalid active display bounds")?
            / scale)
    };
    let orientation = match info["orientation"]["currentDeviceOrientation"].as_str() {
        Some("portrait") => Some(1),
        Some("portraitUpsideDown") => Some(2),
        Some("landscapeLeft") => Some(3),
        Some("landscapeRight") => Some(4),
        _ => None,
    };
    let rotation = match d["currentOrientation"].as_str() {
        None | Some("rot0") => 0,
        Some("rot90") => 90,
        Some("rot180") => 180,
        Some("rot270") => 270,
        Some(other) => return Err(format!("Unknown display orientation {other}").into()),
    };
    Ok(Display {
        id,
        unique_id,
        primary: d["primary"]
            .as_bool()
            .ok_or("Display primary flag is missing")?,
        width: dimension(0)?,
        height: dimension(1)?,
        orientation,
        rotation,
    })
}

pub fn touch_surface(
    panel: &str,
    surfaces: &[idevice::core_device::hid::HidSurface],
) -> Result<u64> {
    let product = format!("CoreDevice touchscreen({panel})");
    let touch: Vec<_> = surfaces
        .iter()
        .filter(|s| s.primary_usage_page == Some(13) && s.primary_usage == Some(4))
        .collect();
    let matched: Vec<_> = touch
        .iter()
        .copied()
        .filter(|s| s.product.as_deref() == Some(product.as_str()))
        .collect();
    if matched.len() == 1 {
        return Ok(matched[0].service_id);
    }
    Err("Cannot identify exactly one touchscreen for the active display".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn fixture() -> Value {
        json!({"displays":[
            {"displayId":1,"uniqueId":"outer","external":false,"active":false,"primary":true,"pointScale":3,"bounds":[[0,0],[1398,2034]]},
            {"displayId":2,"uniqueId":"inner","external":false,"active":true,"primary":false,"pointScale":3,"bounds":[[0,0],[2007,2853]]},
            {"displayId":3,"external":true,"active":true}],"orientation":{"currentDeviceOrientation":"portrait"}})
    }
    fn select(info: &Value) -> Result<Display> {
        decide(false, Ok(info.clone())).1.map(|d| d.expect("several panels"))
    }
    #[test]
    fn selects_active_panel_and_uses_current_bounds() {
        let d = select(&fixture()).unwrap();
        assert_eq!((d.id, d.unique_id.as_str(), d.primary), (2, "inner", false));
        assert_eq!((d.width, d.height, d.orientation), (669.0, 951.0, Some(1)));
        assert_eq!(d.rotation, 0);
    }
    #[test]
    fn a_phone_with_one_built_in_panel_keeps_the_single_display_defaults() {
        // Device information answers, and nothing in the answer may change the route: the panel is
        // rotated, is not flagged primary and has an external display beside it.
        let one = json!({"displays":[
            {"displayId":7,"uniqueId":"only","external":false,"active":true,"primary":false,"pointScale":3,"bounds":[[0,0],[1206,2622]],"currentOrientation":"rot90"},
            {"displayId":3,"uniqueId":"tv","external":true,"active":true,"primary":false,"pointScale":1,"bounds":[[0,0],[1920,1080]]}],
            "orientation":{"currentDeviceOrientation":"landscapeLeft"}});
        // Fields this module cannot read on that one panel do not matter either.
        let mut odd = one.clone();
        odd["displays"][0]["currentOrientation"] = json!("sideways");
        odd["displays"][0]["pointScale"] = json!(0);
        for info in [one, odd, json!({"displays":[]})] {
            let (multiple, display) = decide(false, Ok(info));
            assert_eq!(multiple, Some(false), "the phone is remembered as having one panel");
            let display = display.unwrap();
            assert!(display.is_none());
            let route = route(display.as_ref());
            assert_eq!((route.media_display, route.capture, route.rotation), (1, None, 0));
            assert_eq!(route.touch_panel, None, "input goes to the main touchscreen");
            assert!(!route.live_ax);
            assert_eq!(route.pre_input_read, Duration::from_secs(4));
        }
    }
    #[test]
    fn a_failed_or_unreadable_display_query_keeps_the_defaults_until_several_panels_were_seen() {
        let failures = || -> [Result<Value>; 2] {
            [Err("connection refused".into()), Ok(json!({"unexpected":true}))]
        };
        for answer in failures() {
            let (multiple, display) = decide(false, answer);
            assert_eq!(multiple, None, "a failure says nothing about the phone");
            assert!(display.unwrap().is_none());
        }
        // The same failures on a phone already seen with several panels stop the request.
        for answer in failures() {
            assert!(decide(true, answer).1.is_err());
        }
        // A phone that never answers stops being asked; one seen with several panels is not demoted.
        let mut state = None;
        for expected in [Panels::Unanswered(1), Panels::Unanswered(2), Panels::One] {
            state = Some(remember(state, None));
            assert_eq!(state, Some(expected));
        }
        assert_eq!(remember(Some(Panels::Unanswered(2)), Some(true)), Panels::Several);
        assert_eq!(remember(Some(Panels::Several), None), Panels::Several);
    }
    #[test]
    fn a_second_panel_changes_every_route() {
        let mut info = fixture();
        info["displays"][1]["currentOrientation"] = json!("rot90");
        let (multiple, display) = decide(false, Ok(info));
        assert_eq!(multiple, Some(true));
        let display = display.unwrap().unwrap();
        let route = route(Some(&display));
        assert_eq!((route.media_display, route.capture, route.rotation), (2, Some("inner"), 90));
        assert_eq!(route.touch_panel, Some("inner"));
        assert!(route.live_ax);
        assert_eq!(route.pre_input_read, Duration::from_secs(10));
        // With the primary panel active the screenshot stays on DVT.
        let mut info = fixture();
        info["displays"][0]["active"] = json!(true);
        info["displays"][1]["active"] = json!(false);
        let outer = select(&info).unwrap();
        assert_eq!(super::route(Some(&outer)).capture, None);
    }
    #[test]
    fn reads_panel_rotation_and_refuses_unknown_values() {
        let mut info = fixture();
        info["displays"][1]["currentOrientation"] = json!("rot90");
        assert_eq!(select(&info).unwrap().rotation, 90);
        info["displays"][1]["currentOrientation"] = json!("sideways");
        assert!(select(&info).is_err());
    }
    #[test]
    fn maps_screen_points_onto_native_touch_axes() {
        let m = u16::MAX;
        assert_eq!(to_panel(0, 100, 200), (100, 200));
        // rot90 landscape: screen top-left is the panel's top-right, screen bottom-left its top-left.
        assert_eq!(to_panel(90, 0, 0), (0, m));
        assert_eq!(to_panel(90, 0, m), (m, m));
        assert_eq!(to_panel(90, m, 0), (0, 0));
        assert_eq!(to_panel(180, 0, 0), (m, m));
        assert_eq!(to_panel(270, 0, 0), (m, 0));
        for r in [90, 180, 270] {
            let (mut x, mut y) = (1234, 54321);
            for _ in 0..4 {
                (x, y) = to_panel(r, x, y);
            }
            assert_eq!((x, y), (1234, 54321), "rotation {r} applied a full turn is the identity");
        }
    }
    #[test]
    fn refuses_missing_ambiguous_or_uncalibrated_panels() {
        for (field, value) in [
            ("pointScale", json!(0)),
            ("uniqueId", json!("")),
            ("bounds", json!([[0, 0], [0, 0]])),
        ] {
            let mut info = fixture();
            info["displays"][1][field] = value;
            assert!(select(&info).is_err());
        }
        let mut info = fixture();
        info["displays"][0]["active"] = json!(true);
        assert!(select(&info).is_err());
        info["displays"][0]["active"] = json!(false);
        info["displays"][1]["active"] = json!(false);
        assert!(select(&info).is_err());
    }
    #[test]
    fn selects_touchscreen_by_unique_id_and_refuses_ambiguity() {
        use idevice::core_device::hid::HidSurface;
        let surface = |id, name: &str| HidSurface {
            service_id: id,
            product: Some(format!("CoreDevice touchscreen({name})")),
            primary_usage_page: Some(13),
            primary_usage: Some(4),
        };
        let display = select(&fixture()).unwrap();
        let panel = route(Some(&display)).touch_panel.unwrap();
        let mut surfaces = vec![surface(257, "outer"), surface(258, "inner")];
        assert_eq!(touch_surface(panel, &surfaces).unwrap(), 258);
        surfaces.push(surface(259, "inner"));
        assert!(touch_surface(panel, &surfaces).is_err());
        assert!(touch_surface(panel, &[surface(257, "outer")]).is_err());
    }
}
