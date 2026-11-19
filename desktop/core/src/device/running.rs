//! Whether Poki is running on the device, and closing it before an update replaces it.
//! Two routes, tried in order:
//! - CoreDevice's app service through the CoreDevice tunnel (iOS 17 and later): lists processes
//!   and sends SIGKILL, the way Xcode stops an app.
//! - Instruments (process list, killPid:), through the same tunnel or through lockdown before iOS 17.
//! Both need the developer disk image, which setup mounts first. Every step is logged.
use super::Phone;
use crate::{Error, Result};
use idevice::core_device::AppServiceClient;
use idevice::dvt::{device_info::DeviceInfoClient, process_control::ProcessControlClient, remote_server::RemoteServerClient};
use idevice::{IdeviceService, ReadWrite, RsdService, core_device_proxy::CoreDeviceProxy, rsd::RsdHandshake, tcp::handle::AdapterHandle};
use std::time::Duration;

/// A running Poki process (the app itself, not its extensions).
#[derive(Debug, Clone, serde::Serialize)]
pub struct Running {
    pub pid: u64,
    pub name: String,
}

const SIGKILL: u32 = 9;

/// The CoreDevice tunnel and its service hub (iOS 17 and later).
struct Tunnel {
    adapter: AdapterHandle,
    rsd: RsdHandshake,
}

async fn tunnel(phone: &Phone) -> std::result::Result<Tunnel, String> {
    let provider = phone.provider().map_err(|e| e.to_string())?;
    let go = async {
        let proxy = CoreDeviceProxy::connect(&*provider).await?;
        let port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
        let rsd = RsdHandshake::new(adapter.connect(port).await?).await?;
        Ok::<_, idevice::IdeviceError>(Tunnel { adapter, rsd })
    };
    match tokio::time::timeout(Duration::from_secs(20), go).await {
        Ok(Ok(t)) => Ok(t),
        Ok(Err(e)) => Err(format!("CoreDevice tunnel: {e}")),
        Err(_) => Err("CoreDevice tunnel: timed out".into()),
    }
}

/// One way of seeing and ending processes on the device.
enum Route {
    Apps { client: AppServiceClient<Box<dyn ReadWrite>>, _tunnel: Tunnel },
    Instruments { server: RemoteServerClient<Box<dyn ReadWrite>>, _tunnel: Option<Tunnel> },
}

async fn within<T>(secs: u64, what: &str, f: impl std::future::Future<Output = std::result::Result<T, idevice::IdeviceError>>) -> std::result::Result<T, String> {
    match tokio::time::timeout(Duration::from_secs(secs), f).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(format!("{what}: {e}")),
        Err(_) => Err(format!("{what}: timed out")),
    }
}

/// The routes that connect, best first. Fails only when none does, with every reason.
async fn routes(phone: &Phone) -> Result<Vec<Route>> {
    let mut out = Vec::new();
    let mut why = Vec::new();
    match tunnel(phone).await {
        Ok(mut t) => {
            match within(15, "app service", AppServiceClient::connect_rsd(&mut t.adapter, &mut t.rsd)).await {
                Ok(client) => out.push(Route::Apps { client, _tunnel: t }),
                Err(e) => why.push(e),
            }
            match tunnel(phone).await {
                Ok(mut t) => match within(15, "Instruments over the tunnel", RemoteServerClient::connect_rsd(&mut t.adapter, &mut t.rsd)).await {
                    Ok(server) => out.push(Route::Instruments { server, _tunnel: Some(t) }),
                    Err(e) => why.push(e),
                },
                Err(e) => why.push(e),
            }
        }
        Err(e) => why.push(e),
    }
    if out.is_empty() {
        let provider = phone.provider()?;
        match within(15, "Instruments over lockdown", RemoteServerClient::<Box<dyn ReadWrite>>::connect(&*provider)).await {
            Ok(server) => out.push(Route::Instruments { server, _tunnel: None }),
            Err(e) => why.push(e),
        }
    }
    for w in &why {
        tracing::warn!(reason = %w, "a way to see the device's apps did not connect");
    }
    if out.is_empty() {
        return Err(Error::device(format!("Poki Setup could not see the apps running on the device ({}).", why.join("; "))));
    }
    Ok(out)
}

impl Route {
    fn name(&self) -> &'static str {
        match self {
            Route::Apps { .. } => "app service",
            Route::Instruments { .. } => "Instruments",
        }
    }

    async fn poki(&mut self, app_path: Option<&str>) -> std::result::Result<Vec<Running>, String> {
        let all: Vec<(u64, String, bool)> = match self {
            Route::Apps { client, .. } => within(15, "listing processes", client.list_processes())
                .await?
                .into_iter()
                .map(|p| {
                    let path = p.executable_url.map(|u| u.relative).unwrap_or_default();
                    let path = path.strip_prefix("file://").map(str::to_string).unwrap_or(path);
                    (p.pid as u64, path, true)
                })
                .collect(),
            Route::Instruments { server, .. } => {
                let mut info = within(15, "opening the process list", DeviceInfoClient::new(server)).await?;
                within(15, "listing processes", info.running_processes()).await?.into_iter().map(|p| (p.pid as u64, p.real_app_name, p.is_application)).collect()
            }
        };
        let found: Vec<Running> = all
            .iter()
            .filter(|(_, path, app)| is_poki(path, *app, app_path))
            .map(|(pid, path, _)| Running { pid: *pid, name: path.rsplit('/').next().unwrap_or_default().to_string() })
            .collect();
        let near: Vec<&String> = all.iter().map(|(_, p, _)| p).filter(|p| p.contains("Poki")).collect();
        tracing::info!(route = self.name(), app_path, processes = all.len(), found = ?found, poki_like = ?near, "looked for Poki on the device");
        Ok(found)
    }

    async fn kill(&mut self, pid: u64) -> std::result::Result<(), String> {
        tracing::info!(route = self.name(), pid, "closing Poki");
        match self {
            Route::Apps { client, .. } => within(15, "sending SIGKILL", client.send_signal(pid as u32, SIGKILL)).await.map(|_| ()),
            Route::Instruments { server, .. } => {
                let mut control = within(15, "opening process control", ProcessControlClient::new(server)).await?;
                within(15, "killPid", control.kill_app(pid)).await
            }
        }
    }
}

/// Whether a process is Poki itself. Instruments names an app by its bundle path
/// (`/private/var/containers/Bundle/Application/<id>/Poki.app`) on some iOS versions and by its
/// executable inside it on others, so both count. Its extensions (`Poki.app/PlugIns/…`) do not:
/// they end with it. `app_path` is where installation_proxy says the installed Poki lives.
fn is_poki(real_app_name: &str, is_application: bool, app_path: Option<&str>) -> bool {
    let path = real_app_name.trim_end_matches('/');
    if path.contains("/PlugIns/") || path.contains(".appex") {
        return false;
    }
    let inside = |bundle: &str| {
        let bundle = bundle.trim_end_matches('/');
        path == bundle || path.strip_prefix(bundle).is_some_and(|rest| rest.starts_with('/'))
    };
    match app_path {
        Some(bundle) if !bundle.is_empty() => inside(bundle) || inside(&format!("/private{bundle}")) || bundle.strip_prefix("/private").is_some_and(inside),
        _ => is_application && (path.ends_with("/Poki.app") || path.contains("/Poki.app/")),
    }
}

/// Runs device work on its own thread: idevice's tunnel futures are not `Send`, and the
/// bridge and the Tauri app run every command on a multi-threaded runtime.
async fn on_own_thread<T: Send + 'static>(phone: &Phone, work: impl AsyncFnOnce(&Phone) -> Result<T> + Send + 'static) -> Result<T> {
    let phone = phone.clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let answer = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(Error::from).and_then(|rt| rt.block_on(work(&phone)));
        let _ = tx.send(answer);
    });
    let answer = rx.await.map_err(|_| Error::device("Poki Setup lost its connection to the device."))?;
    if let Err(e) = &answer {
        tracing::warn!(error = %e, "checking or closing Poki failed");
    }
    answer
}

/// Poki's processes now running (in front or in the background).
pub async fn poki(phone: &Phone, app_path: Option<String>) -> Result<Vec<Running>> {
    on_own_thread(phone, async move |p: &Phone| {
        let mut why = Vec::new();
        for mut route in routes(p).await? {
            match route.poki(app_path.as_deref()).await {
                Ok(found) => return Ok(found),
                Err(e) => {
                    tracing::warn!(route = route.name(), reason = %e, "could not list the device's processes");
                    why.push(e);
                }
            }
        }
        Err(Error::device(format!("Poki Setup could not list the apps running on the device ({}).", why.join("; "))))
    })
    .await
}

/// Closes Poki and checks it is gone. Returns how many processes were ended.
pub async fn close_poki(phone: &Phone, app_path: Option<String>) -> Result<usize> {
    on_own_thread(phone, async move |p: &Phone| close_here(p, app_path.as_deref()).await).await
}

async fn close_here(phone: &Phone, app_path: Option<&str>) -> Result<usize> {
    let mut why = Vec::new();
    // Each route keeps its own connection open through the kill and the checks after it:
    // killPid: gets no reply, and closing the connection right after can drop it.
    for mut route in routes(phone).await? {
        let running = match route.poki(app_path).await {
            Ok(r) => r,
            Err(e) => {
                why.push(e);
                continue;
            }
        };
        if running.is_empty() {
            return Ok(0);
        }
        let mut sent = true;
        for p in &running {
            if let Err(e) = route.kill(p.pid).await {
                tracing::warn!(route = route.name(), pid = p.pid, reason = %e, "could not close Poki");
                why.push(e);
                sent = false;
            }
        }
        if !sent {
            continue;
        }
        for _ in 0..15 {
            tokio::time::sleep(Duration::from_millis(300)).await;
            match route.poki(app_path).await {
                Ok(left) if left.is_empty() => {
                    tracing::info!(route = route.name(), "Poki is closed");
                    return Ok(running.len());
                }
                Ok(_) => {}
                Err(e) => {
                    why.push(e);
                    break;
                }
            }
        }
        why.push(format!("{}: Poki was still running after the kill", route.name()));
    }
    tracing::warn!(reasons = ?why, "Poki is still running");
    Err(Error::NeedsPerson(format!("Poki Setup could not close Poki on the device ({}). Close it from the app switcher, then try again.", why.join("; "))))
}

#[cfg(test)]
mod tests {
    use super::is_poki;
    const APP: &str = "/private/var/containers/Bundle/Application/AB-12/Poki.app";

    #[test]
    fn the_bundle_path_or_the_executable_counts() {
        assert!(is_poki(APP, true, None));
        assert!(is_poki(&format!("{APP}/Poki"), true, None));
        assert!(is_poki(APP, false, Some(APP)));
        assert!(is_poki(&format!("{APP}/Poki"), true, Some("/var/containers/Bundle/Application/AB-12/Poki.app")));
    }

    #[test]
    fn extensions_and_other_apps_do_not() {
        assert!(!is_poki(&format!("{APP}/PlugIns/Widget.appex/Widget"), false, Some(APP)));
        assert!(!is_poki("/Applications/MobileSafari.app/MobileSafari", true, Some(APP)));
        assert!(!is_poki("/private/var/containers/Bundle/Application/AB-123/Poki.app", true, Some(APP)));
    }
}
