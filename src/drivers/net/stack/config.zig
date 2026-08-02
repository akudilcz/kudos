//! Runtime network configuration. The address fields are the
//! single source of truth for our IP/netmask/gateway/DNS. They are `0.0.0.0`
//! until the DHCP client (src/drivers/net/stack/dhcp.zig) commits a lease at init — never a
//! hardcoded placeholder, so an unconfigured stack fails loudly rather than
//! masquerading as a working LAN.

pub var our_ip = [4]u8{ 0, 0, 0, 0 };
pub var netmask = [4]u8{ 0, 0, 0, 0 };
pub var gateway = [4]u8{ 0, 0, 0, 0 };
pub var dns_server = [4]u8{ 0, 0, 0, 0 };

/// Our MAC, filled in from the NIC at init.
pub var our_mac = [6]u8{ 0, 0, 0, 0, 0, 0 };
