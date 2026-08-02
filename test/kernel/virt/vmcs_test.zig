//! Host tests of src/kernel/virt/vmcs.zig — the VMCS field-encoding invariant.
//!
//! The load-bearing property: a field's width and type are not free-standing
//! labels but are *encoded in the field number itself* (SDM Vol 3D §B.1). If a
//! constant here is mistyped, `width()`/`fieldType()` decode a different class
//! than the name implies, so cross-checking each named field against its expected
//! class catches a wrong literal — the exact failure a raw VMWRITE would only
//! reveal at runtime under nested VMX.

const std = @import("std");
const vmcs = @import("vmcs");
const Field = vmcs.Field;
const Width = vmcs.Width;
const Kind = vmcs.Kind;
const expectEqual = std.testing.expectEqual;

test "spot-check field encodings against SDM Appendix B literals" {
    try expectEqual(@as(u32, 0x0000), @intFromEnum(Field.vpid));
    try expectEqual(@as(u32, 0x4002), @intFromEnum(Field.proc_ctls));
    try expectEqual(@as(u32, 0x401E), @intFromEnum(Field.proc_ctls2));
    try expectEqual(@as(u32, 0x201A), @intFromEnum(Field.ept_pointer));
    try expectEqual(@as(u32, 0x4400), @intFromEnum(Field.vm_instruction_error));
    try expectEqual(@as(u32, 0x4402), @intFromEnum(Field.exit_reason));
    try expectEqual(@as(u32, 0x681E), @intFromEnum(Field.guest_rip));
    try expectEqual(@as(u32, 0x6C16), @intFromEnum(Field.host_rip));
    try expectEqual(@as(u32, 0x6800), @intFromEnum(Field.guest_cr0));
    try expectEqual(@as(u32, 0x2400), @intFromEnum(Field.guest_phys_addr));
}

test "width decodes from encoding bits 14:13" {
    try expectEqual(Width.w16, Field.guest_cs_sel.width());
    try expectEqual(Width.w64, Field.ept_pointer.width());
    try expectEqual(Width.w64, Field.vmcs_link_pointer.width());
    try expectEqual(Width.w32, Field.exit_reason.width());
    try expectEqual(Width.w32, Field.guest_cs_limit.width());
    try expectEqual(Width.natural, Field.guest_rip.width());
    try expectEqual(Width.natural, Field.exit_qualification.width());
}

test "fieldType decodes from encoding bits 11:10" {
    try expectEqual(Kind.control, Field.pin_ctls.fieldType());
    try expectEqual(Kind.control, Field.ept_pointer.fieldType());
    try expectEqual(Kind.exit_info, Field.exit_reason.fieldType());
    try expectEqual(Kind.exit_info, Field.exit_qualification.fieldType());
    try expectEqual(Kind.guest, Field.guest_cr3.fieldType());
    try expectEqual(Kind.guest, Field.guest_cs_sel.fieldType());
    try expectEqual(Kind.host, Field.host_rip.fieldType());
    try expectEqual(Kind.host, Field.host_cr0.fieldType());
}

// Every named field's decoded (type, width) must match the category its name
// declares. Grouping the enum by prefix and asserting the decode is what turns a
// single mistyped hex literal into a test failure instead of a VM-entry fault.
test "named field matches its decoded category" {
    const Case = struct { f: Field, k: Kind, w: Width };
    const cases = [_]Case{
        .{ .f = .vpid, .k = .control, .w = .w16 },
        .{ .f = .guest_es_sel, .k = .guest, .w = .w16 },
        .{ .f = .host_cs_sel, .k = .host, .w = .w16 },
        .{ .f = .msr_bitmap, .k = .control, .w = .w64 },
        .{ .f = .guest_ia32_efer, .k = .guest, .w = .w64 },
        .{ .f = .host_ia32_pat, .k = .host, .w = .w64 },
        .{ .f = .exception_bitmap, .k = .control, .w = .w32 },
        .{ .f = .exit_instruction_len, .k = .exit_info, .w = .w32 },
        .{ .f = .guest_tr_ar, .k = .guest, .w = .w32 },
        .{ .f = .host_ia32_sysenter_cs, .k = .host, .w = .w32 },
        .{ .f = .cr0_guest_host_mask, .k = .control, .w = .natural },
        .{ .f = .io_rip, .k = .exit_info, .w = .natural },
        .{ .f = .guest_gdtr_base, .k = .guest, .w = .natural },
        .{ .f = .host_gdtr_base, .k = .host, .w = .natural },
    };
    for (cases) |c| {
        try expectEqual(c.k, c.f.fieldType());
        try expectEqual(c.w, c.f.width());
    }
}

test "exit reasons and the entry-failure flag" {
    try expectEqual(@as(u16, 10), @intFromEnum(vmcs.ExitReason.cpuid));
    try expectEqual(@as(u16, 12), @intFromEnum(vmcs.ExitReason.hlt));
    try expectEqual(@as(u16, 30), @intFromEnum(vmcs.ExitReason.io_instruction));
    try expectEqual(@as(u16, 48), @intFromEnum(vmcs.ExitReason.ept_violation));
    try expectEqual(@as(u16, 33), @intFromEnum(vmcs.ExitReason.entry_fail_guest_state));
    try expectEqual(@as(u32, 0x8000_0000), vmcs.EXIT_REASON_ENTRY_FAILURE);
}

test "entry interruption-info composes a valid external interrupt" {
    const info = vmcs.EntryIntrInfo.externalInterrupt(0x40);
    try expectEqual(@as(u32, 0x40), info & 0xFF); // vector in bits 7:0
    try expectEqual(vmcs.EntryIntrInfo.VALID, info & vmcs.EntryIntrInfo.VALID);
    try expectEqual(@as(u32, 0), info & (7 << 8)); // interruption type 0 = external
}

test "VIRT-015: a guest that faults its way to shutdown decodes as a guest exit" {
    // How a guest panic or reboot arrives: the guest faults with no handler of
    // its own left, and the processor reports a triple fault as the EXIT REASON
    // — the guest's own exit, carrying the guest's RIP. vcpu.zig switches on
    // this value and virt.zig marks the guest halted; there is no arm that can
    // turn it into a Kudos fault, because it is the guest that stopped.
    try expectEqual(@as(u16, 2), @intFromEnum(vmcs.ExitReason.triple_fault));
    // And it is NOT a VM-entry failure: bit 31 of the exit-reason field is what
    // separates "the host could not enter" from "the guest died", and it is
    // clear here — so a guest shutdown can never read as a host-side failure.
    const raw: u32 = @intFromEnum(vmcs.ExitReason.triple_fault);
    try expectEqual(@as(u32, 0), raw & 0x8000_0000);
    try expectEqual(raw, (0x8000_0000 | raw) & 0x7FFF_FFFF);
}
