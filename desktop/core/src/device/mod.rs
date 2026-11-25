//! The iPhone, over USB through usbmuxd or over Wi-Fi with a pairing record.
//!
//! A [`Phone`] is a UDID plus how to reach it; [`Phone::provider`] gives idevice's connection
//! factory for every service. Nothing here drives the phone's screen: pairing, Developer Mode,
//! installing and files are all lockdown services the person confirms on the phone themselves.
pub mod container;
pub mod ddi;
pub mod devmode;
pub mod info;
pub mod install;
pub mod logs;
pub mod pairing;
pub mod running;

use crate::{Error, Result};
use idevice::{
    pairing_file::PairingFile,
    provider::{IdeviceProvider, TcpProvider, UsbmuxdProvider},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use serde::{Deserialize, Serialize};
use std::{future::Future, net::IpAddr, pin::Pin};

pub const LABEL: &str = "poki-setup";

/// How the phone is reached right now.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Link {
    /// Through usbmuxd over the cable.
    Usb,
    /// Through usbmuxd, which found it on the network (macOS and Windows list Wi-Fi-synced phones).
    Muxed { address: IpAddr },
    /// Straight to lockdown on TCP 62078 with our pairing record (any platform, same Wi-Fi).
    Wifi { address: IpAddr },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Phone {
    pub udid: String,
    pub link: Link,
    /// usbmuxd's own id for the attachment, when it came from usbmuxd.
    #[serde(default)]
    pub mux_id: Option<u32>,
}

/// usbmuxd lists a phone once per way it reaches it (a cable and Wi-Fi sync, sometimes two
/// addresses), all with the same udid. People pick a phone, not a link: keep one entry per udid,
/// the USB one when there is one, then the order usbmuxd gave.
fn one_per_phone(mut phones: Vec<Phone>) -> Vec<Phone> {
    phones.sort_by_key(|p| !matches!(p.link, Link::Usb));
    let mut seen = std::collections::HashSet::new();
    phones.retain(|p| seen.insert(p.udid.clone()));
    phones
}

impl Phone {
    /// The phones usbmuxd knows, one entry per phone: USB first, then network ones.
    pub async fn list() -> Result<Vec<Phone>> {
        let mut mux = UsbmuxdConnection::default().await?;
        let devices = mux.get_devices().await?;
        let phones: Vec<Phone> = devices
            .into_iter()
            .map(|d| Phone {
                link: match d.connection_type {
                    Connection::Usb => Link::Usb,
                    Connection::Network(ip) => Link::Muxed { address: ip },
                    Connection::Unknown(_) => Link::Usb,
                },
                udid: d.udid,
                mux_id: Some(d.device_id),
            })
            .collect();
        Ok(one_per_phone(phones))
    }

    /// Every way usbmuxd reaches each phone, with its usbmuxd id: cables first, then Wi-Fi sync.
    /// poki-mcp tries them in that order (issue #609).
    pub async fn list_all_links() -> Result<Vec<(Phone, u32)>> {
        let mut mux = UsbmuxdConnection::default().await?;
        let mut all: Vec<(Phone, u32)> = mux
            .get_devices()
            .await?
            .into_iter()
            .map(|d| {
                let link = match d.connection_type {
                    Connection::Network(ip) => Link::Muxed { address: ip },
                    _ => Link::Usb,
                };
                (Phone { udid: d.udid, link, mux_id: Some(d.device_id) }, d.device_id)
            })
            .collect();
        all.sort_by_key(|(p, _)| !matches!(p.link, Link::Usb));
        Ok(all)
    }

    /// A phone on the same Wi-Fi, reached with the pairing record this computer saved for it.
    pub fn over_wifi(udid: impl Into<String>, address: IpAddr) -> Phone {
        Phone { udid: udid.into(), link: Link::Wifi { address }, mux_id: None }
    }

    /// idevice's connection factory for this phone. Over USB it connects through usbmuxd and opens
    /// every session with the record [`pairing::settle`] last saw the phone accept, so that each
    /// step uses the same trust (see [`SettledUsb`]); over Wi-Fi it needs the pairing record from
    /// [`pairing::saved`].
    pub fn provider(&self) -> Result<Box<dyn IdeviceProvider>> {
        match &self.link {
            Link::Usb | Link::Muxed { .. } => Ok(Box::new(SettledUsb {
                mux: UsbmuxdProvider {
                    addr: UsbmuxdAddr::from_env_var().unwrap_or_default(),
                    tag: 1,
                    udid: self.udid.clone(),
                    device_id: self.mux_id.unwrap_or(0),
                    label: LABEL.into(),
                },
            })),
            Link::Wifi { address } => {
                let pairing_file = pairing::saved(&self.udid)?
                    .ok_or_else(|| Error::device("No pairing record for this iPhone on this computer. Plug it in once to pair."))?;
                Ok(Box::new(TcpProvider { addr: *address, scope_id: None, pairing_file, label: LABEL.into() }))
            }
        }
    }

    pub fn is_usb(&self) -> bool { matches!(self.link, Link::Usb) }
}

/// usbmuxd's connection factory, with one change: sessions open with the record the phone last
/// accepted from this computer ([`pairing::settle`]) instead of whatever record usbmuxd holds.
///
/// usbmuxd's record and the one Poki Setup saved can drift apart: Apple Devices on Windows or
/// Finder on the Mac may keep an old record the phone forgot (after Reset Location & Privacy, an
/// erase or an update), or may not take the record Poki Setup gave it. Pairing then checked one
/// record and every later step (profiles, install, remote pairing) used the other, and failed
/// with "not paired" right after pairing worked (#421). Only when nothing was settled in this run
/// is usbmuxd's record used, as before.
#[derive(Debug)]
pub struct SettledUsb {
    mux: UsbmuxdProvider,
}

impl IdeviceProvider for SettledUsb {
    fn connect(&self, port: u16) -> Pin<Box<dyn Future<Output = std::result::Result<idevice::Idevice, idevice::IdeviceError>> + Send>> {
        self.mux.connect(port)
    }

    fn label(&self) -> &str {
        self.mux.label()
    }

    fn get_pairing_file(&self) -> Pin<Box<dyn Future<Output = std::result::Result<PairingFile, idevice::IdeviceError>> + Send>> {
        match pairing::settled(&self.mux.udid) {
            Some(record) => Box::pin(async move { Ok(record) }),
            None => self.mux.get_pairing_file(),
        }
    }
}

/// The pairing record usbmuxd holds for a UDID (macOS and Windows keep one per trusted phone).
pub async fn mux_pairing_record(udid: &str) -> Result<Option<PairingFile>> {
    let mut mux = UsbmuxdConnection::default().await?;
    match mux.get_pair_record(udid).await {
        Ok(p) => Ok(Some(p)),
        Err(idevice::IdeviceError::NotFound) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod list_tests {
    use super::*;

    /// usbmuxd here is a port nobody listens on, so a provider that asks usbmuxd for its record
    /// fails, as it did with a stale Apple Devices record: every step after pairing must use the
    /// record the phone accepted instead (#421).
    #[tokio::test]
    async fn usb_sessions_use_the_record_the_phone_accepted_not_usbmuxds() {
        let phone = Phone { udid: "SETTLED-USB".into(), link: Link::Usb, mux_id: Some(1) };
        let unreachable = UsbmuxdProvider { addr: UsbmuxdAddr::TcpSocket("127.0.0.1:1".parse().unwrap()), tag: 1, udid: phone.udid.clone(), device_id: 1, label: LABEL.into() };
        assert!(unreachable.get_pairing_file().await.is_err(), "usbmuxd's record is out of reach in this test");

        pairing::remember_for_test(&phone.udid, Some("HOST-ACCEPTED"));
        let provider = SettledUsb { mux: unreachable };
        let record = provider.get_pairing_file().await.expect("the settled record, without asking usbmuxd");
        assert_eq!(record.host_id, "HOST-ACCEPTED");

        pairing::remember_for_test(&phone.udid, None);
        assert!(provider.get_pairing_file().await.is_err(), "nothing settled: usbmuxd's record, as before");
        assert!(matches!(phone.provider(), Ok(_)));
    }

    #[test]
    fn a_phone_on_cable_and_wifi_is_listed_once_by_cable() {
        let wifi = |u: &str| Phone { udid: u.into(), link: Link::Muxed { address: "192.168.1.5".parse().unwrap() }, mux_id: Some(2) };
        let usb = |u: &str| Phone { udid: u.into(), link: Link::Usb, mux_id: Some(1) };
        let l = one_per_phone(vec![wifi("A"), usb("A"), wifi("B"), wifi("B")]);
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].udid, "A");
        assert!(matches!(l[0].link, Link::Usb));
        assert_eq!(l[1].udid, "B");
    }
}
