//! Host tests of src/drivers/usb/hid_report.zig.

const std = @import("std");
const hid_report = @import("hid_report");
const HID_CLASS_DESC = hid_report.HID_CLASS_DESC;
const KeyPresses = hid_report.KeyPresses;
const Kind = hid_report.Kind;
const MouseEvent = hid_report.MouseEvent;
const MouseLayout = hid_report.MouseLayout;
const PointerKind = hid_report.PointerKind;
const RDESC_BOOT_KEYBOARD = hid_report.RDESC_BOOT_KEYBOARD;
const RDESC_BOOT_MOUSE = hid_report.RDESC_BOOT_MOUSE;
const RDESC_G_PRO = hid_report.RDESC_G_PRO;
const RDESC_TABLET = hid_report.RDESC_TABLET;
const TabletEvent = hid_report.TabletEvent;
const cfg = hid_report.cfg;
const classifyPointer = hid_report.classifyPointer;
const dci = hid_report.dci;
const decodeKeyboard = hid_report.decodeKeyboard;
const decodeMouse = hid_report.decodeMouse;
const decodeTablet = hid_report.decodeTablet;
const epDesc = hid_report.epDesc;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const ifaceDesc = hid_report.ifaceDesc;
const mouseLayout = hid_report.mouseLayout;
const pickHidEndpoint = hid_report.pickHidEndpoint;

test "boot mouse config: recorded as the mouse pick, dci from ep address" {
    const desc = cfg(&(ifaceDesc(0, 3, 1, 2) ++ HID_CLASS_DESC ++ epDesc(0x81, 4, 10)));
    const res = pickHidEndpoint(&desc);
    try expect(res.mouse != null and res.kbd == null);
    const m = res.mouse.?;
    try expectEqual(Kind.mouse, m.kind);
    try expectEqual(@as(u8, 0), m.iface);
    try expectEqual(@as(u8, 0x81), m.ep_addr);
    try expectEqual(@as(u32, 4), m.ep_mps);
    try expectEqual(@as(u8, 10), m.ep_interval);
    try expectEqual(@as(u32, 3), dci(m.ep_addr)); // (1 & 0xF)*2 + 1
    // Declared wDescriptorLength extracted from the HID class descriptor (0x40).
    try expectEqual(@as(u16, 0x40), m.rdesc_len);
}

test "boot keyboard config: recorded as the keyboard pick" {
    const desc = cfg(&(ifaceDesc(0, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x82, 8, 24)));
    const res = pickHidEndpoint(&desc);
    try expect(res.kbd != null and res.mouse == null);
    try expectEqual(Kind.keyboard, res.kbd.?.kind);
    try expectEqual(@as(u32, 5), dci(0x82));
}

test "composite keyboard+mouse: BOTH boot interfaces recorded, so both get driven" {
    // A Keychron 3434:d030 leads with its boot-MOUSE interface (media keys /
    // integrated pointer), then the boot keyboard. Recording only the first drove
    // the whole device as a mouse and lost the keyboard (the lemon kbd=0). Both
    // must be recorded so both endpoints are bound.
    const desc = cfg(&(ifaceDesc(0, 3, 1, 2) ++ HID_CLASS_DESC ++ epDesc(0x81, 8, 10) ++
        ifaceDesc(1, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x82, 8, 24)));
    const res = pickHidEndpoint(&desc);
    try expect(res.kbd != null and res.mouse != null);
    try expectEqual(@as(u8, 1), res.kbd.?.iface);
    try expectEqual(@as(u8, 0x82), res.kbd.?.ep_addr);
    try expectEqual(@as(u8, 0), res.mouse.?.iface);
    try expectEqual(@as(u8, 0x81), res.mouse.?.ep_addr);
}

test "wantsBootProtocol: only a boot keyboard takes SET_PROTOCOL(boot)" {
    try expect(hid_report.wantsBootProtocol(false, .keyboard)); // boot keyboard: yes
    try expect(!hid_report.wantsBootProtocol(false, .mouse)); // boot mouse: report protocol
    try expect(!hid_report.wantsBootProtocol(false, .tablet));
    try expect(!hid_report.wantsBootProtocol(true, .keyboard)); // protocol-0: no boot protocol
    try expect(!hid_report.wantsBootProtocol(true, .mouse));
}

test "both boot keyboards are recorded (combo board: 6KRO + NKRO/consumer)" {
    // A combo keyboard exposes two boot-keyboard interfaces and which one streams
    // ordinary keys varies by board — arming only the first left the lemon keyboard
    // silent (kbd_rep=0). Both are recorded (kbd + kbd2) so both endpoints bind.
    const desc = cfg(&(ifaceDesc(0, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x81, 8, 10) ++
        ifaceDesc(1, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x82, 8, 10)));
    const res = pickHidEndpoint(&desc);
    try expect(res.kbd != null and res.kbd2 != null and res.mouse == null);
    try expectEqual(@as(u8, 0), res.kbd.?.iface); // first boot keyboard
    try expectEqual(@as(u8, 0x81), res.kbd.?.ep_addr);
    try expectEqual(@as(u8, 1), res.kbd2.?.iface); // second boot keyboard
    try expectEqual(@as(u8, 0x82), res.kbd2.?.ep_addr);
}

test "a third boot keyboard is dropped (only two are recorded)" {
    // MAX_DEV_HID caps a device at a pointer + two keyboards; a spec-legal but
    // unusual third boot keyboard has nowhere to go and is not recorded.
    const desc = cfg(&(ifaceDesc(0, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x81, 8, 10) ++
        ifaceDesc(1, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x82, 8, 10) ++
        ifaceDesc(2, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x83, 8, 10)));
    const res = pickHidEndpoint(&desc);
    try expectEqual(@as(u8, 0x81), res.kbd.?.ep_addr);
    try expectEqual(@as(u8, 0x82), res.kbd2.?.ep_addr); // third (0x83) has nowhere to go
}

test "combo keyboard with an integrated pointer: mouse + both keyboards all recorded" {
    // The lemon Keychron topology: a boot mouse interface plus two boot keyboards.
    // All three are picked so the driver can bind every endpoint.
    const desc = cfg(&(ifaceDesc(0, 3, 1, 2) ++ HID_CLASS_DESC ++ epDesc(0x82, 8, 10) ++
        ifaceDesc(1, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x84, 8, 10) ++
        ifaceDesc(2, 3, 1, 1) ++ HID_CLASS_DESC ++ epDesc(0x87, 8, 10)));
    const res = pickHidEndpoint(&desc);
    try expect(res.mouse != null and res.kbd != null and res.kbd2 != null);
    try expectEqual(@as(u8, 0x82), res.mouse.?.ep_addr);
    try expectEqual(@as(u8, 0x84), res.kbd.?.ep_addr);
    try expectEqual(@as(u8, 0x87), res.kbd2.?.ep_addr);
}

test "composite device: endpoint paired with ITS interface; boot present alongside a candidate" {
    // iface0: vendor class (skipped). iface1: protocol-0 HID candidate. iface2:
    // boot mouse. The boot mouse is recorded; the candidate is kept but hasBoot()
    // tells the caller to ignore it (a boot device is driven via boot interfaces).
    const desc = cfg(&(ifaceDesc(0, 0xFF, 0, 0) ++ epDesc(0x81, 64, 1) ++
        ifaceDesc(1, 3, 0, 0) ++ HID_CLASS_DESC ++ epDesc(0x82, 8, 4) ++
        ifaceDesc(2, 3, 1, 2) ++ HID_CLASS_DESC ++ epDesc(0x83, 16, 1)));
    const res = pickHidEndpoint(&desc);
    try expect(res.hasBoot());
    try expectEqual(@as(u8, 2), res.mouse.?.iface);
    try expectEqual(@as(u8, 0x83), res.mouse.?.ep_addr);
    try expectEqual(@as(u16, 0x40), res.mouse.?.rdesc_len);
    try expectEqual(@as(u8, 1), res.candidate.?.iface); // recorded, but ignored (hasBoot)
}

test "interface without a HID class descriptor: rdesc_len is 0 (read refused, not guessed)" {
    // A malformed HID interface that skips its HID descriptor entirely: the
    // pick still works (endpoint present) but rdesc_len stays 0, and it must
    // NOT inherit the previous interface's declared length.
    const desc = cfg(&(ifaceDesc(0, 3, 0, 0) ++ HID_CLASS_DESC ++ epDesc(0x81, 8, 4) ++
        ifaceDesc(1, 3, 1, 2) ++ epDesc(0x82, 4, 10)));
    const res = pickHidEndpoint(&desc);
    try expectEqual(@as(u8, 1), res.mouse.?.iface); // boot mouse
    try expectEqual(@as(u16, 0), res.mouse.?.rdesc_len); // no HID desc on iface 1
}

test "composite device without boot interface: protocol-0 candidate for classification" {
    const desc = cfg(&(ifaceDesc(0, 0xFF, 0, 0) ++ epDesc(0x81, 64, 1) ++
        ifaceDesc(1, 3, 0, 0) ++ HID_CLASS_DESC ++ epDesc(0x82, 8, 4)));
    const res = pickHidEndpoint(&desc);
    try expect(!res.hasBoot());
    try expectEqual(@as(u8, 1), res.candidate.?.iface);
    try expectEqual(@as(u8, 0x82), res.candidate.?.ep_addr);
    try expectEqual(Kind.tablet, res.candidate.?.kind); // candidate default; classified later
}

test "config with no HID interface at all: empty pick-set" {
    const desc = cfg(&(ifaceDesc(0, 0xFF, 0, 0) ++ epDesc(0x81, 64, 1)));
    try expect(pickHidEndpoint(&desc).empty());
}

test "truncated config descriptor: partial walk, no over-read" {
    const full = cfg(&(ifaceDesc(0, 3, 1, 2) ++ HID_CLASS_DESC ++ epDesc(0x81, 4, 10)));
    // Cut mid-endpoint-descriptor: the interface was seen but its endpoint's
    // body runs past the transferred bytes — no pick, no crash.
    try expect(pickHidEndpoint(full[0 .. full.len - 3]).empty());
    // Cut inside the interface descriptor.
    try expect(pickHidEndpoint(full[0..12]).empty());
    // Header only / empty / bLength 0.
    try expect(pickHidEndpoint(full[0..9]).empty());
    try expect(pickHidEndpoint(full[0..0]).empty());
    const zero_blen = [_]u8{ 9, 2, 12, 0, 1, 1, 0, 0xA0, 50, 0, 0, 0 };
    try expect(pickHidEndpoint(&zero_blen).empty());
}

test "boot mouse report descriptor parses to the boot layout" {
    const lo = mouseLayout(&RDESC_BOOT_MOUSE);
    try expectEqual(@as(u8, 0), lo.buttons_byte);
    try expectEqual(@as(u8, 1), lo.x_byte);
    try expectEqual(@as(u8, 1), lo.size_bytes);
    try expectEqual(PointerKind.relative, classifyPointer(&RDESC_BOOT_MOUSE));
}

test "G Pro report descriptor: Report-ID shift, 16 button bits, 16-bit deltas" {
    const lo = mouseLayout(&RDESC_G_PRO);
    // Report ID byte 0, buttons at bytes 1-2 (16 bits), X at bytes 3-4.
    try expectEqual(@as(u8, 1), lo.buttons_byte);
    try expectEqual(@as(u8, 3), lo.x_byte);
    try expectEqual(@as(u8, 2), lo.size_bytes);
    try expectEqual(PointerKind.relative, classifyPointer(&RDESC_G_PRO));
}

test "keyboard report descriptor: no pointer — classify none, layout falls back to boot" {
    try expectEqual(PointerKind.none, classifyPointer(&RDESC_BOOT_KEYBOARD));
    const lo = mouseLayout(&RDESC_BOOT_KEYBOARD); // no GD-X input — boot default
    try expectEqual(@as(u8, 1), lo.x_byte);
    try expectEqual(@as(u8, 1), lo.size_bytes);
}

// PER-005: absolute pointing devices (tablet) are supported — the descriptor
// classifies as absolute and decodeTablet scales, clamps and guards the wrap.
test "tablet report descriptor classifies absolute" {
    try expectEqual(PointerKind.absolute, classifyPointer(&RDESC_TABLET));
}

test "truncated report descriptor: no over-read, ambiguity defaults to relative" {
    // Cut the G Pro descriptor right before the X/Y Input item (byte 44 ends
    // after "09 30 09 31"): X usage was seen but never consumed — must default
    // to .relative (safe), and the layout must fall back to boot rather than
    // half-parse.
    const upto_xy = RDESC_G_PRO[0..44];
    try expectEqual(PointerKind.relative, classifyPointer(upto_xy));
    const lo = mouseLayout(upto_xy);
    try expectEqual(@as(u8, 1), lo.x_byte); // boot fallback
    // Cut mid-item (a 2-byte item's prefix as the last byte): parse stops clean.
    try expectEqual(PointerKind.none, classifyPointer(RDESC_G_PRO[0..1]));
    try expectEqual(PointerKind.none, classifyPointer(RDESC_G_PRO[0..0]));
}

test "decodeMouse boot layout: negative 8-bit deltas and button mask" {
    const lo = MouseLayout{};
    const ev = decodeMouse(&[_]u8{ 0x09, 0xFF, 0x80 }, lo).?; // buttons 1|8, dx -1, dy -128
    try expectEqual(@as(u8, 0x1), ev.buttons); // masked to low 3
    try expectEqual(@as(i32, -1), ev.dx);
    try expectEqual(@as(i32, -128), ev.dy);
}

test "decodeMouse G Pro layout: Report-ID offset + negative 16-bit deltas" {
    const lo = mouseLayout(&RDESC_G_PRO);
    // [ID=2, btn_lo=0x05, btn_hi=0, x=-300 (0xFED4), y=+700 (0x02BC), wheel]
    const rep = [_]u8{ 0x02, 0x05, 0x00, 0xD4, 0xFE, 0xBC, 0x02, 0x00 };
    const ev = decodeMouse(&rep, lo).?;
    try expectEqual(@as(u8, 0x5), ev.buttons);
    try expectEqual(@as(i32, -300), ev.dx);
    try expectEqual(@as(i32, 700), ev.dy);
}

test "decodeMouse: a report too short for BOTH the layout and boot returns null" {
    // Too short for the Report-ID layout (needs 7) AND for the 3-byte boot
    // fallback: nothing to decode, no over-read.
    const lo = mouseLayout(&RDESC_G_PRO);
    try expectEqual(@as(?MouseEvent, null), decodeMouse(&[_]u8{ 0x02, 0x05 }, lo)); // 2 bytes
    try expectEqual(@as(?MouseEvent, null), decodeMouse(&[_]u8{ 0, 1 }, MouseLayout{})); // boot needs 3
}

test "decodeMouse short-report fallback: G Pro streams 4-byte Report-ID-8 8-bit" {
    // The real bug (usbmon boot2-usbmon.log): the G Pro descriptor declares an
    // 8-byte 16-bit report (x_byte=2), but the wire carries a 4-byte
    // [0x08][dx8][dy8][0] report. Sliced to its real length, decodeMouse fails the
    // 16-bit layout (needs 6 bytes) and falls back to the boot layout: dx@1, dy@2,
    // buttons = report[0] & 0x7 (the 0x08 Report-ID bit masks off to 0).
    const lo = mouseLayout(&RDESC_GPRO_REAL);
    try expectEqual(@as(u8, 2), lo.x_byte); // 16-bit descriptor layout
    const r1 = decodeMouse(&[_]u8{ 0x08, 0x02, 0x08, 0x00 }, lo).?; // real sample: +2,+8
    try expectEqual(@as(i32, 2), r1.dx);
    try expectEqual(@as(i32, 8), r1.dy);
    try expectEqual(@as(u8, 0), r1.buttons);
    const r2 = decodeMouse(&[_]u8{ 0x08, 0xFE, 0x02, 0x00 }, lo).?; // -2,+2
    try expectEqual(@as(i32, -2), r2.dx);
    try expectEqual(@as(i32, 2), r2.dy);
    const r3 = decodeMouse(&[_]u8{ 0x08, 0xD5, 0x06, 0x00 }, lo).?; // -43,+6
    try expectEqual(@as(i32, -43), r3.dx);
    try expectEqual(@as(i32, 6), r3.dy);
}

test "decodeMouse: a full-length 16-bit report keeps its own layout (no spurious fallback)" {
    // When the report IS long enough for the descriptor layout, the fallback must
    // NOT fire — a genuine 16-bit mouse decodes at 16 bits, not boot 8 bits.
    const lo = mouseLayout(&RDESC_GPRO_REAL);
    const rep = [_]u8{ 0x00, 0x00, 0x2C, 0x01, 0xD4, 0xFE, 0x00, 0x00 }; // x=+300, y=-300
    const ev = decodeMouse(&rep, lo).?;
    try expectEqual(@as(i32, 300), ev.dx);
    try expectEqual(@as(i32, -300), ev.dy);
}

test "decodeKeyboard: press/release diff is edge-triggered" {
    var last: [6]u8 = .{0} ** 6;
    // Press 'a' (0x04): fires once.
    const r1 = decodeKeyboard(&[_]u8{ 0, 0, 0x04, 0, 0, 0, 0, 0 }, last, 0).?;
    try expectEqual(@as(usize, 1), r1.count);
    try expectEqual(@as(u8, 0x04), r1.keys[0]);
    last = r1.next_last;
    // Held 'a' + new 'b' (0x05): only 'b' fires.
    const r2 = decodeKeyboard(&[_]u8{ 0, 0, 0x04, 0x05, 0, 0, 0, 0 }, last, 0).?;
    try expectEqual(@as(usize, 1), r2.count);
    try expectEqual(@as(u8, 0x05), r2.keys[0]);
    last = r2.next_last;
    // Release all: nothing fires; next 'a' press fires again.
    const r3 = decodeKeyboard(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, last, 0).?;
    try expectEqual(@as(usize, 0), r3.count);
    last = r3.next_last;
    const r4 = decodeKeyboard(&[_]u8{ 0, 0, 0x04, 0, 0, 0, 0, 0 }, last, 0).?;
    try expectEqual(@as(usize, 1), r4.count);
}

test "decodeKeyboard: shift bits and 6-key rollover" {
    const last: [6]u8 = .{0} ** 6;
    // Right shift (0x20) held, all six slots full: six presses, shift set.
    const r = decodeKeyboard(&[_]u8{ 0x20, 0, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 }, last, 0).?;
    try expectEqual(true, r.shift);
    try expectEqual(@as(usize, 6), r.count);
    // Phantom-state rollover report (all slots ErrorRollOver 0x01): the 0x01
    // usages are edge-triggered like any other — fire once, then never while held.
    const ro = decodeKeyboard(&[_]u8{ 0, 0, 1, 1, 1, 1, 1, 1 }, last, 0).?;
    try expectEqual(@as(usize, 6), ro.count);
    const ro2 = decodeKeyboard(&[_]u8{ 0, 0, 1, 1, 1, 1, 1, 1 }, ro.next_last, 0).?;
    try expectEqual(@as(usize, 0), ro2.count);
    // Short report: null, never a partial parse.
    try expectEqual(@as(?KeyPresses, null), decodeKeyboard(&[_]u8{ 0, 0, 4 }, last, 0));
}

test "decodeTablet: scale, clamp, and the 0x8000 wrap guard" {
    // Mid-range on a 1000x500 screen.
    const mid = decodeTablet(&[_]u8{ 0x01, 0xFF, 0x3F, 0xFF, 0x3F, 0 }, 6, 1000, 500).?;
    try expectEqual(@as(u8, 1), mid.buttons);
    try expectEqual(@as(i32, 499), mid.x); // 0x3FFF/0x7FFF * 999
    try expectEqual(@as(i32, 249), mid.y);
    // Out-of-spec sample >= 0x8000 (QEMU window-resize artifact): clamps to the
    // far edge instead of wrapping to ~65000 and sticking in a corner.
    const wrap = decodeTablet(&[_]u8{ 0x00, 0x00, 0x80, 0xFF, 0xFF, 0 }, 6, 1000, 500).?;
    try expectEqual(@as(i32, 999), wrap.x);
    try expectEqual(@as(i32, 499), wrap.y);
    // Endpoint too small for the 5-byte format / short report: null.
    try expectEqual(@as(?TabletEvent, null), decodeTablet(&[_]u8{ 0, 0, 0, 0, 0 }, 4, 1000, 500));
    try expectEqual(@as(?TabletEvent, null), decodeTablet(&[_]u8{ 0, 0, 0 }, 6, 1000, 500));
}

test "split-report mouse: X/Y under a different Report ID than the buttons" {
    // A gaming-mouse layout: buttons under Report ID 1, motion under Report ID 8.
    // Each report's fields are offset from ITS OWN start — so X sits at byte 1
    // (right after the report-ID byte), NOT byte 2. The old cumulative bit
    // counter piled report 1's 8 bits onto report 8 and read X a byte too far,
    // which is why the scroll byte drove the cursor on the real device.
    const rdesc = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, // Usage Page (GD), Usage (Mouse), Collection (App)
        0x85, 0x01, // Report ID (1)
        0x05, 0x09, 0x19, 0x01, 0x29, 0x05, // Usage Page (Button), Usage Min 1, Max 5
        0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02, // 5 button bits
        0x95, 0x01, 0x75, 0x03, 0x81, 0x03, // 3 padding bits
        0x85, 0x08, // Report ID (8)
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, // Usage Page (GD), Usage X, Usage Y
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06, // 8-bit rel X, Y
        0xC0, // End Collection
    };
    const lo = mouseLayout(&rdesc);
    try expectEqual(@as(u8, 1), lo.x_byte); // X right after the report-ID byte
    try expectEqual(@as(u8, 1), lo.size_bytes); // 8-bit deltas
    try expectEqual(PointerKind.relative, classifyPointer(&rdesc));
}

// The ACTUAL report descriptors of the two HID devices on the lemon test rig,
// captured from Linux (`usbhid-dump`) — ground truth, not fabricated. A synthetic
// fixture that merely resembles a device is the regression trap: it passes on the
// laptop while the real hardware decodes wrong. These lock mouseLayout to what the
// physical Logitech G Pro and Keychron actually send.

// Logitech G Pro Wireless (046d:c088), interface 0 (the mouse). NO Report ID:
// 16 button bits (2 bytes), then 16-bit relative X/Y, then wheel + AC-pan.
const RDESC_GPRO_REAL = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x95, 0x10, 0x75, 0x01, 0x15, 0x00,
    0x25, 0x01, 0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x81, 0x02, 0x95, 0x02, 0x75, 0x10, 0x16, 0x01,
    0x80, 0x26, 0xFF, 0x7F, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x81, 0x06, 0x95, 0x01, 0x75, 0x08,
    0x15, 0x81, 0x25, 0x7F, 0x09, 0x38, 0x81, 0x06, 0x95, 0x01, 0x05, 0x0C, 0x0A, 0x38, 0x02, 0x81,
    0x06, 0xC0, 0xC0,
};

// Keychron Link (3434:d030), interface 0 (the integrated pointer). Report ID 3:
// [id][5 buttons + 3 pad = 1 byte][16-bit X/Y][wheel].
const RDESC_KEYCHRON_MOUSE_REAL = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x03, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01,
    0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x05, 0x81, 0x02, 0x75, 0x03, 0x95, 0x01,
    0x81, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x01, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10,
    0x95, 0x02, 0x81, 0x06, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xC0,
    0xC0,
};

// Keychron Link (3434:d030), the boot-keyboard report descriptor: standard
// [modifiers][reserved][6 keycodes], Report ID 1, plus consumer + system-control
// collections. This is what typing must decode through.
const RDESC_KEYCHRON_KBD_REAL = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x26, 0xF1, 0x00, 0x05, 0x07, 0x19, 0x00, 0x2A, 0xF1, 0x00,
    0x81, 0x00, 0xC0, 0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x02, 0x75, 0x10, 0x95, 0x01, 0x15,
    0x01, 0x26, 0x8C, 0x03, 0x19, 0x01, 0x2A, 0x8C, 0x03, 0x81, 0x00, 0xC0, 0x05, 0x01, 0x09, 0x80,
    0xA1, 0x01, 0x85, 0x06, 0x09, 0x81, 0x09, 0x82, 0x09, 0x83, 0x15, 0x00, 0x25, 0x01, 0x19, 0x01,
    0x29, 0x03, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02, 0x95, 0x05, 0x81, 0x01, 0xC0, 0x05, 0x01, 0x09,
    0x06, 0xA1, 0x01, 0x85, 0x0C, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75,
    0x01, 0x95, 0x08, 0x81, 0x02, 0x15, 0x00, 0x25, 0x01, 0x19, 0x00, 0x29, 0x98, 0x75, 0x01, 0x95,
    0x98, 0x81, 0x02, 0xC0,
};

test "REAL Logitech G Pro (046d:c088): no Report ID, 16 buttons then 16-bit X at byte 2" {
    const lo = mouseLayout(&RDESC_GPRO_REAL);
    try expectEqual(@as(u8, 0), lo.buttons_byte); // 16 button bits start at byte 0
    try expectEqual(@as(u8, 2), lo.x_byte); // X after 2 button bytes, no Report ID
    try expectEqual(@as(u8, 2), lo.size_bytes); // 16-bit deltas
    try expectEqual(PointerKind.relative, classifyPointer(&RDESC_GPRO_REAL));
}

test "REAL Keychron pointer (3434:d030): Report ID 3, 1 button byte, 16-bit X at byte 2" {
    const lo = mouseLayout(&RDESC_KEYCHRON_MOUSE_REAL);
    try expectEqual(@as(u8, 1), lo.buttons_byte); // buttons at byte 1 (after Report ID)
    try expectEqual(@as(u8, 2), lo.x_byte); // X after 1 button byte + Report-ID shift
    try expectEqual(@as(u8, 2), lo.size_bytes); // 16-bit deltas
    try expectEqual(PointerKind.relative, classifyPointer(&RDESC_KEYCHRON_MOUSE_REAL));
}

test "REAL Keychron keyboard (3434:d030): classified as a keyboard, not a pointer" {
    try expect(hid_report.isKeyboard(&RDESC_KEYCHRON_KBD_REAL));
    try expectEqual(PointerKind.none, classifyPointer(&RDESC_KEYCHRON_KBD_REAL));
    // A keyboard descriptor carries no GD-X input, so mouseLayout falls back to boot.
    const lo = mouseLayout(&RDESC_KEYCHRON_KBD_REAL);
    try expectEqual(@as(u8, 1), lo.x_byte);
    try expectEqual(@as(u8, 1), lo.size_bytes);
}

test "protocol must match layout: a boot-format frame under the G Pro report-layout scrambles" {
    // The G Pro layout parsed from its REPORT descriptor: 16-bit X at byte 2.
    const layout = mouseLayout(&RDESC_GPRO_REAL);
    try expectEqual(@as(u8, 2), layout.x_byte);
    try expectEqual(@as(u8, 2), layout.size_bytes);
    // A genuine REPORT-protocol frame [buttons:2B][X16=+5][Y16=-5][wheel][pan]
    // decodes correctly under that layout.
    const report_frame = [_]u8{ 0, 0, 5, 0, 0xFB, 0xFF, 0, 0 };
    const good = decodeMouse(&report_frame, layout).?;
    try expectEqual(@as(i32, 5), good.dx);
    try expectEqual(@as(i32, -5), good.dy);
    // The SAME device left in BOOT protocol streams a 3-byte [buttons][X8][Y8]
    // frame; decoded under the report-layout it does NOT recover (+5,-5) — the
    // motion is scrambled. This is why the driver must force report protocol so
    // the wire format matches the layout it decodes with (xhci SET_PROTOCOL).
    const boot_frame = [_]u8{ 0, 5, 0xFB, 0, 0, 0, 0, 0 };
    const bad = decodeMouse(&boot_frame, layout).?;
    try expect(!(bad.dx == 5 and bad.dy == -5));
}

test "decodeKeyboard: a key let go is reported, so nothing stays held forever" {
    // The press diff alone cannot express this: a guest told a key went down and
    // never told it came up holds it down for good.
    const first = decodeKeyboard(&[_]u8{ 0, 0, 0x04, 0x05, 0, 0, 0, 0 }, .{0} ** 6, 0).?;
    try expectEqual(@as(usize, 2), first.count);
    try expectEqual(@as(usize, 0), first.released_count);

    // 'a' let go, 'b' still held, 'c' newly pressed: one of each, no double
    // counting of the held key.
    const next = decodeKeyboard(&[_]u8{ 0, 0, 0x05, 0x06, 0, 0, 0, 0 }, first.next_last, 0).?;
    try expectEqual(@as(usize, 1), next.count);
    try expectEqual(@as(u8, 0x06), next.keys[0]);
    try expectEqual(@as(usize, 1), next.released_count);
    try expectEqual(@as(u8, 0x04), next.released[0]);

    // Everything up: both remaining keys release together.
    const up = decodeKeyboard(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, next.next_last, 0).?;
    try expectEqual(@as(usize, 0), up.count);
    try expectEqual(@as(usize, 2), up.released_count);
}

test "decodeKeyboard: the modifier bitmap crosses intact, with its predecessor" {
    // Modifiers never appear in the key array, so a caller can only diff them
    // from the bitmap — and only if it is given both sides of the diff.
    const r = decodeKeyboard(&[_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0 }, .{0} ** 6, 0).?;
    try expectEqual(@as(u8, 0x02), r.mods); // left shift down
    try expectEqual(@as(u8, 0x00), r.last_mods);
    const r2 = decodeKeyboard(&[_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 }, r.next_last, r.mods).?;
    try expectEqual(@as(u8, 0x00), r2.mods); // and back up
    try expectEqual(@as(u8, 0x02), r2.last_mods);
}
