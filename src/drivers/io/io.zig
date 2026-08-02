//! x86 port I/O primitives. Single source of truth for in/out instructions
//! used by klog, PIC, the 8042 reset, PCI, and the NIC.

/// Write a byte to I/O `port`.
pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

/// Read a byte from I/O `port`.
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Write a 16-bit word to I/O `port`.
pub fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port),
    );
}

/// Read a 16-bit word from I/O `port`.
pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

/// Write a 32-bit dword to I/O `port` (used for PCI config data at 0xCFC).
pub fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port),
    );
}

/// Read a 32-bit dword from I/O `port` (used for PCI config data at 0xCFC).
pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

/// Short delay by writing to an unused port (legacy 0x80).
pub fn wait() void {
    outb(0x80, 0);
}
