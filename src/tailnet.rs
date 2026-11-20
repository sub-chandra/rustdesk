#[cfg(windows)]
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub(crate) const ENABLED: bool = cfg!(windows);

#[cfg(windows)]
pub(crate) fn configure() {
    use hbb_common::config;

    *config::APP_NAME.write().unwrap() = "RustDeskTailnet".to_owned();
    config::HARD_SETTINGS
        .write()
        .unwrap()
        .insert("disable-account".into(), "Y".into());
    config::OVERWRITE_SETTINGS.write().unwrap().extend([
        ("direct-server".into(), "Y".into()),
        ("allow-auto-update".into(), "N".into()),
        ("enable-tunnel".into(), "N".into()),
    ]);
}

#[cfg(windows)]
pub(crate) fn contains(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [a, b, ..] = ip.octets();
            a == 100 && (64..128).contains(&b)
        }
        IpAddr::V6(ip) => {
            let [a, b, c, ..] = ip.segments();
            [a, b, c] == [0xfd7a, 0x115c, 0xa1e0]
        }
    }
}

#[cfg(any(windows, test))]
fn trusted_address(allowlist: &str, ip: std::net::IpAddr) -> bool {
    allowlist
        .split(',')
        .any(|entry| entry.trim().parse::<std::net::IpAddr>() == Ok(ip))
}

#[cfg(any(windows, test))]
fn paired_desktops(pair: &str, local: std::net::IpAddr, peer: std::net::IpAddr) -> bool {
    let Some((first, second)) = pair.split_once(';') else {
        return false;
    };
    (trusted_address(first, local) && trusted_address(second, peer))
        || (trusted_address(second, local) && trusted_address(first, peer))
}

pub(crate) fn passwordless_desktop(peer: &str, local: std::net::IpAddr) -> bool {
    #[cfg(windows)]
    if let Ok(ip) = peer.parse::<IpAddr>() {
        let addresses = hbb_common::config::Config::get_option(
            base::config::keys::OPTION_TAILNET_PASSWORDLESS_PEERS,
        );
        return addresses != "disabled"
            && contains(local)
            && contains(ip)
            && route_uses_adapter(ip)
            && (trusted_address(&addresses, ip)
                || paired_desktops(
                    option_env!("RUSTDESK_TAILNET_PAIRED_DESKTOPS").unwrap_or_default(),
                    local,
                    ip,
                ));
    }
    let _ = (peer, local);
    false
}

#[cfg(windows)]
pub(crate) fn endpoint(peer: &str) -> Option<SocketAddr> {
    let address = peer.parse::<IpAddr>().map_or_else(
        |_| peer.parse::<SocketAddr>().ok(),
        |ip| {
            Some(SocketAddr::new(
                ip,
                hbb_common::config::RELAY_PORT as u16 + 1,
            ))
        },
    )?;
    (address.port() != 0 && contains(address.ip())).then_some(address)
}

#[cfg(windows)]
pub(crate) fn route_uses_adapter(ip: IpAddr) -> bool {
    use windows::{
        core::w,
        Win32::{
            Foundation::NO_ERROR,
            NetworkManagement::IpHelper::{
                ConvertInterfaceAliasToLuid, ConvertInterfaceLuidToIndex, GetBestInterfaceEx,
            },
            Networking::WinSock::{
                AF_INET, AF_INET6, IN6_ADDR, IN6_ADDR_0, IN_ADDR, IN_ADDR_0, SOCKADDR_IN,
                SOCKADDR_IN6, SOCKADDR_INET,
            },
        },
    };

    let address = match ip {
        IpAddr::V4(ip) => SOCKADDR_INET {
            Ipv4: SOCKADDR_IN {
                sin_family: AF_INET,
                sin_addr: IN_ADDR {
                    S_un: IN_ADDR_0 {
                        S_addr: u32::from_ne_bytes(ip.octets()),
                    },
                },
                ..Default::default()
            },
        },
        IpAddr::V6(ip) => SOCKADDR_INET {
            Ipv6: SOCKADDR_IN6 {
                sin6_family: AF_INET6,
                sin6_addr: IN6_ADDR {
                    u: IN6_ADDR_0 { Byte: ip.octets() },
                },
                ..Default::default()
            },
        },
    };
    let mut luid = Default::default();
    let mut adapter = 0;
    let mut route = 0;
    unsafe {
        ConvertInterfaceAliasToLuid(w!("Tailscale"), &mut luid) == NO_ERROR
            && ConvertInterfaceLuidToIndex(&luid, &mut adapter) == NO_ERROR
            && GetBestInterfaceEx(std::ptr::addr_of!(address).cast(), &mut route) == 0
            && route == adapter
    }
}

#[cfg(windows)]
pub(crate) fn adapter_addresses() -> Vec<IpAddr> {
    use windows::{
        core::w,
        Win32::{
            Foundation::NO_ERROR,
            NetworkManagement::{
                IpHelper::{ConvertInterfaceAliasToLuid, FreeMibTable, GetUnicastIpAddressTable},
                Ndis::NET_LUID_LH,
            },
            Networking::WinSock::{AF_INET, AF_INET6, AF_UNSPEC},
        },
    };

    let mut addresses = Vec::new();
    unsafe {
        let mut luid = NET_LUID_LH::default();
        if ConvertInterfaceAliasToLuid(w!("Tailscale"), &mut luid) != NO_ERROR {
            return addresses;
        }
        let mut table = std::ptr::null_mut();
        if GetUnicastIpAddressTable(AF_UNSPEC, &mut table) != NO_ERROR || table.is_null() {
            return addresses;
        }
        let first = std::ptr::addr_of!((*table).Table).cast();
        let rows: &[windows::Win32::NetworkManagement::IpHelper::MIB_UNICASTIPADDRESS_ROW] =
            std::slice::from_raw_parts(first, (*table).NumEntries as usize);
        for row in rows {
            if row.InterfaceLuid.Value != luid.Value {
                continue;
            }
            let ip = match row.Address.si_family {
                AF_INET => IpAddr::V4(Ipv4Addr::from(
                    row.Address.Ipv4.sin_addr.S_un.S_addr.to_ne_bytes(),
                )),
                AF_INET6 => IpAddr::V6(Ipv6Addr::from(row.Address.Ipv6.sin6_addr.u.Byte)),
                _ => continue,
            };
            if contains(ip) {
                addresses.push(ip);
            }
        }
        FreeMibTable(table.cast());
    }
    addresses
}

#[cfg(test)]
mod tests {
    use super::{paired_desktops, trusted_address};

    #[test]
    fn only_exact_tailscale_devices_grant_passwordless_access() {
        let ipv4 = "100.64.0.10".parse().unwrap();
        let ipv6 = "fd7a:115c:a1e0::10".parse().unwrap();

        assert!(trusted_address("100.64.0.11, 100.64.0.10", ipv4));
        assert!(trusted_address("fd7a:115c:a1e0:0::10", ipv6));
        assert!(!trusted_address("", ipv4));
        assert!(!trusted_address("100.64.0.0/10,0.0.0.0,*", ipv4));
        assert!(!trusted_address("100.64.0.100", ipv4));
    }

    #[test]
    fn baked_pair_only_authorizes_connections_between_the_two_devices() {
        let pair = "100.64.0.10,fd7a:115c:a1e0::10;100.64.0.11,fd7a:115c:a1e0::11";
        let first = "100.64.0.10".parse().unwrap();
        let second = "fd7a:115c:a1e0::11".parse().unwrap();
        let third = "100.64.0.12".parse().unwrap();

        assert!(paired_desktops(pair, first, second));
        assert!(paired_desktops(pair, second, first));
        assert!(!paired_desktops(pair, first, first));
        assert!(!paired_desktops(pair, first, third));
        assert!(!paired_desktops(pair, third, first));
        assert!(!paired_desktops("", first, second));
    }
}
