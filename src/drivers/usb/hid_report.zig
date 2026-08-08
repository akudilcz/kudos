//! USB HID descriptor parsing + report decode. Pure logic — every function takes plain byte
//! slices; the control transfers, DMA-buffer volatile snapshots, and event
//! injection live in the driver (xhci.zig). Mirrors Linux usbhid: devices are
//! driven in REPORT protocol per their report descriptor (usbhid_start never
//! issues SET_PROTOCOL) — so the descriptor parse here decides exactly which
//! bytes of every report are buttons/X/Y, and a wrong answer is a mouse that
//! "enumerates but never moves".
//!
//! Every scan walks ONLY the bytes the caller actually transferred — walking a
//! stale buffer tail past the real descriptor end is the ReleaseFast misparse
//! bug; truncated/malformed descriptors must degrade to a safe
//! default, never over-read.

/// What kind of input device an interface is — its report layout and where its
/// reports route. `tablet` is an absolute pointer (e.g. QEMU's usb-tablet): a
/// HID interface with protocol 0 whose report carries absolute X/Y rather than
/// relative deltas.
pub const Kind = enum { keyboard, mouse, tablet };

/// How a protocol-0 HID interface reports a pointer, decided from its report
/// descriptor: an absolute pointer (tablet), a relative pointer (ordinary
/// non-boot mouse), or neither (media keys / consumer control — not a pointer).
pub const PointerKind = enum { absolute, relative, none };

/// Where the X/Y axes live in a mouse's report, learned from its report
/// descriptor. `x_byte` is the byte offset of the X field (Y follows at
/// x_byte + size_bytes), `size_bytes` is 1 or 2. `buttons_byte` holds the
/// button bits. Defaults describe the HID BOOT report (buttons@0, X@1, Y@2,
/// 8-bit).
pub const MouseLayout = struct {
    buttons_byte: u8 = 0,
    x_byte: u8 = 1,
    size_bytes: u8 = 1, // 1 = 8-bit deltas (boot), 2 = 16-bit (e.g. G Pro)
};

/// Parse a mouse interface's report descriptor into a MouseLayout: track the
/// running BIT position through each Input item (report_size × report_count)
/// and record where the Generic-Desktop X axis lands and how wide it is. Also
/// records the first button field's byte. Falls back to the boot layout if the
/// descriptor has no GD-X input. Handles a leading Report ID (adds one byte at
/// the front of every report). `desc` is the report-descriptor bytes the
/// transfer actually returned — never the full DMA buffer.
pub fn mouseLayout(desc: []const u8) MouseLayout {
    var out = MouseLayout{};
    const n = desc.len;

    var page: u16 = 0;
    var rsize: u32 = 0; // report size (bits per field)
    var rcount: u32 = 0; // report count (number of fields)
    // Bit offset WITHIN the current report — reset at every Report ID. A device
    // that splits reports by ID (buttons under report 1, motion under report 8,
    // common on gaming mice) otherwise piles report 1's bits onto the offset of
    // report 8's X, so X reads one byte too far and the scroll byte drives the
    // cursor. Field offsets are per-report (HID 1.11 §5.6, §8), not cumulative.
    var bit_pos: u32 = 0;
    var has_report_id = false;
    var committed = false; // the first report carrying X wins
    // Pending usages queued for the next Input item.
    var pending_x = false;
    var pending_buttons = false;
    // The report currently being scanned (since the last Report ID).
    var cur_x_byte: u8 = 0;
    var cur_size: u8 = 1;
    var cur_buttons_byte: u8 = 0;
    var cur_has_x = false;
    var cur_has_buttons = false;

    var i: usize = 0;
    while (i + 1 <= n) {
        const item = desc[i];
        if (item == 0) break;
        const size_code: usize = item & 0x3;
        const item_len: usize = if (size_code == 3) 4 else size_code;
        const tag = item & 0xFC;
        if (i + 1 + item_len > n) break;
        var data: u32 = 0;
        var b: usize = 0;
        while (b < item_len) : (b += 1) data |= @as(u32, desc[i + 1 + b]) << @intCast(b * 8);

        switch (tag) {
            0x04 => page = @truncate(data), // Usage Page
            0x84 => { // Report ID (global) — byte 0 of a NEW report begins here.
                has_report_id = true;
                // Commit the report we just finished if it carried X (first wins),
                // then start a fresh per-report offset.
                if (cur_has_x and !committed) {
                    out.x_byte = cur_x_byte;
                    out.size_bytes = cur_size;
                    out.buttons_byte = if (cur_has_buttons) cur_buttons_byte else 0;
                    committed = true;
                }
                bit_pos = 0;
                cur_has_x = false;
                cur_has_buttons = false;
                pending_x = false;
                pending_buttons = false;
            },
            0x74 => rsize = data, // Report Size
            0x94 => rcount = data, // Report Count
            0x08 => { // Usage (local)
                if (page == 0x01 and @as(u16, @truncate(data)) == 0x30) pending_x = true;
                if (page == 0x09) pending_buttons = true;
            },
            0x18 => { // Usage Minimum — buttons declared as a range (page 0x09)
                if (page == 0x09) pending_buttons = true;
            },
            0x80 => { // Input (main): this field batch occupies rsize*rcount bits
                if (pending_buttons and !cur_has_buttons) {
                    cur_buttons_byte = @intCast(bit_pos / 8);
                    cur_has_buttons = true;
                }
                if (pending_x and !cur_has_x) {
                    cur_x_byte = @intCast(bit_pos / 8);
                    cur_size = @intCast((rsize + 7) / 8);
                    cur_has_x = true;
                }
                bit_pos += rsize * rcount;
                pending_x = false;
                pending_buttons = false;
            },
            0xA0, 0xC0 => {
                pending_x = false;
                pending_buttons = false;
            },
            else => {},
        }
        i += 1 + item_len;
    }
    // The last report has no following Report ID to trigger its commit.
    if (cur_has_x and !committed) {
        out.x_byte = cur_x_byte;
        out.size_bytes = cur_size;
        out.buttons_byte = if (cur_has_buttons) cur_buttons_byte else 0;
        committed = true;
    }
    if (!committed) return MouseLayout{}; // no GD-X input — assume boot layout
    // A leading Report ID shifts every field right by the one report-ID byte.
    if (has_report_id) {
        out.buttons_byte += 1;
        out.x_byte += 1;
    }
    return out;
}

/// Classify a protocol-0 HID interface from its HID report descriptor
/// (GET_DESCRIPTOR type 0x22 — fetched by the caller, only the returned bytes
/// passed here). Recognizes every pointer shape and DEFAULTS TO A RELATIVE
/// MOUSE WHEN AMBIGUOUS, because a misread relative mouse still moves the
/// cursor (recoverable) while skipping kills the device outright:
///   - GD-X usage consumed by an Input item, Relative flag clear -> .absolute
///   - GD-X usage consumed by an Input item, Relative flag set   -> .relative
///   - a GD Pointer (0x01) / Mouse (0x02) usage seen, or an X usage seen but no
///     decisive Input item (truncated/odd descriptor)            -> .relative
///   - descriptor fully scanned with no GD X/Pointer/Mouse usage  -> .none (skip)
/// Is this report descriptor a KEYBOARD? Same flat item scan as classifyPointer.
///
/// Needed because a HID interface with bInterfaceProtocol == 0 declares no BOOT
/// protocol, so the interface descriptor alone cannot say what it is. Classifying
/// such an interface for pointer-ness alone silently drops every non-boot keyboard.
///
/// The tell is the Keyboard/Keypad usage page (0x07) appearing in the item stream, or
/// a Generic-Desktop Keyboard (0x06) / Keypad (0x07) application usage. Either is
/// decisive: no pointing device declares them.
pub fn isKeyboard(desc: []const u8) bool {
    const n = desc.len;
    var page: u16 = 0;
    var i: usize = 0;
    while (i + 1 <= n) {
        const item = desc[i];
        if (item == 0) break;
        const size_code: usize = item & 0x3;
        const item_len: usize = if (size_code == 3) 4 else size_code;
        const tag = item & 0xFC;
        if (i + 1 + item_len > n) break;
        var data: u32 = 0;
        var b: usize = 0;
        while (b < item_len) : (b += 1) data |= @as(u32, desc[i + 1 + b]) << @intCast(b * 8);

        switch (tag) {
            0x04 => { // Usage Page (global)
                page = @truncate(data);
                if (page == 0x07) return true; // Keyboard/Keypad page: decisive
            },
            0x08 => { // Usage (local)
                if (page == 0x01) {
                    const u: u16 = @truncate(data);
                    if (u == 0x06 or u == 0x07) return true; // GD Keyboard / Keypad
                }
            },
            else => {},
        }
        i += 1 + item_len;
    }
    return false;
}

pub fn classifyPointer(desc: []const u8) PointerKind {
    const n = desc.len;

    // Flat scan of the report-item stream. Track the current Usage Page, whether
    // a Generic-Desktop X usage is pending, and any pointer/mouse hint seen.
    var page: u16 = 0;
    var saw_x = false; // a GD-X usage declared but not yet consumed by a main item
    var pointer_hint = false; // a GD Pointer/Mouse application usage was present
    var i: usize = 0;
    while (i + 1 <= n) {
        const item = desc[i];
        if (item == 0) break; // 0x00 is not a valid item prefix -> end/padding
        const size_code: usize = item & 0x3;
        const item_len: usize = if (size_code == 3) 4 else size_code; // 0,1,2,4 bytes
        const tag = item & 0xFC; // type+tag, size bits cleared
        if (i + 1 + item_len > n) break; // item body runs past real data
        var data: u32 = 0;
        var b: usize = 0;
        while (b < item_len) : (b += 1) data |= @as(u32, desc[i + 1 + b]) << @intCast(b * 8);

        switch (tag) {
            0x04 => page = @truncate(data), // Usage Page (global)
            0x08 => { // Usage (local)
                if (page == 0x01) {
                    const u: u16 = @truncate(data);
                    if (u == 0x30) saw_x = true; // X
                    if (u == 0x01 or u == 0x02) pointer_hint = true; // Pointer / Mouse
                }
            },
            0x80 => { // Input (main): data bit2 = 0 -> Absolute, 1 -> Relative
                if (saw_x) return if ((data & 0x04) != 0) .relative else .absolute;
                saw_x = false; // usages are consumed by a main item
            },
            0xA0, 0xC0 => saw_x = false, // Collection / End Collection consume usages
            else => {},
        }
        i += 1 + item_len;
    }
    // No decisive X Input item. If we saw any pointer signature at all, treat it
    // as a relative mouse rather than dropping a possibly-real pointer.
    return if (pointer_hint or saw_x) .relative else .none;
}

/// One interrupt-IN endpoint paired with the interface it actually belongs to
/// — the walk's product. Composite devices expose several interfaces; mixing
/// one's endpoint with another's number made SET_PROTOCOL target the wrong
/// interface on real hardware.
pub const Pick = struct {
    iface: u8 = 0,
    ep_addr: u8 = 0,
    ep_mps: u32 = 8,
    ep_interval: u8 = 0, // endpoint bInterval (descriptor offset 6)
    kind: Kind = .mouse,
    // The interface's declared report-descriptor length (HID 1.11 §6.2.1,
    // wDescriptorLength at bytes 7-8 of the HID class descriptor). The rdesc
    // GET_DESCRIPTOR requests exactly this, like Linux's
    // hid_get_class_descriptor — a fixed over-length read is mis-served by
    // some devices behind hubs. 0 = the interface declared no HID descriptor
    // (malformed for a HID interface; the read is refused rather than guessed).
    rdesc_len: u16 = 0,
};

/// Every HID interface pickHidEndpoint found that this driver can drive. A
/// composite device exposes more than one — a keyboard that also presents a
/// boot-mouse interface (media keys / an integrated pointer), or a mouse that
/// presents a keyboard interface for its macro keys — and each BOOT interface is
/// bound to its own interrupt endpoint (a boot keyboard+mouse composite is driven
/// as both), toward Linux usbhid's every-interface model. `kbd`/`mouse` are boot
/// interfaces (class 3, subclass 1, protocol 1/2), used directly. `candidate` is
/// the first protocol-0 interface (class 3, protocol 0); it has no boot protocol,
/// so the caller classifies it from its report descriptor, and it is driven ONLY
/// when the device exposes NO boot interface (the media-keys interface of a
/// composite keyboard has the identical class/proto as a tablet and must not be
/// taken for one). LIMIT: full every-interface parity holds only for boot+boot
/// composites — a device mixing a boot interface with a protocol-0 one drives
/// only the boot side, and only the FIRST protocol-0 interface is recorded. Boot
/// keyboards — and only boot keyboards — take SET_PROTOCOL(boot) (wantsBootProtocol);
/// a mouse honoring it streams 3-byte boot reports a 16-bit layout (G Pro)
/// misreads (dead cursor on bare metal), and a protocol-0 interface would STALL.
///
/// A combo keyboard commonly exposes TWO boot-keyboard interfaces — a 6-key-rollover
/// boot interface and a second (NKRO / consumer) boot interface — and which one
/// actually streams ordinary key presses varies by board; arming only the first
/// leaves a keyboard that enumerates but never reports. Both boot keyboards are
/// therefore recorded (`kbd`, `kbd2`) and driven, mirroring the boot keyboard+mouse
/// both-driven rule. `mouse`/`candidate` stay single (no device needs two of those).
pub const PickSet = struct {
    kbd: ?Pick = null, // first boot keyboard interface (SET_PROTOCOL boot)
    kbd2: ?Pick = null, // second boot keyboard interface, if the device has one
    mouse: ?Pick = null, // first boot mouse interface (left in report protocol)
    candidate: ?Pick = null, // first protocol-0 interface (classify from rdesc)

    /// The device exposes at least one boot interface — the candidate is then
    /// ignored (a boot device is driven through its boot interfaces).
    pub fn hasBoot(self: PickSet) bool {
        return self.kbd != null or self.mouse != null;
    }
    /// Nothing this driver can drive.
    pub fn empty(self: PickSet) bool {
        return self.kbd == null and self.mouse == null and self.candidate == null;
    }
};

/// Whether a HID interface takes SET_PROTOCOL(boot): a BOOT keyboard only. A boot
/// mouse is left in report protocol (Linux usbhid parity — a mouse honoring boot
/// protocol streams 3-byte reports a descriptor-derived layout misreads), and a
/// protocol-0 candidate (`is_candidate`) has no boot protocol at all and would
/// STALL. The driver additionally forces boot protocol for a boot mouse whose
/// report descriptor is UNREADABLE — a defined boot-protocol+boot-layout pairing —
/// but that is IO-dependent and stays at the call site.
pub fn wantsBootProtocol(is_candidate: bool, kind: Kind) bool {
    return !is_candidate and kind == .keyboard;
}

/// Walk a configuration descriptor (the bytes actually transferred — reading
/// only the first 64 bytes hides any interface past byte 64) pairing each
/// interrupt-IN endpoint with the interface it belongs to, and record every
/// drivable HID interface: the first boot keyboard, the first boot mouse, and
/// the first protocol-0 candidate (classified later by the caller). A composite
/// keyboard+mouse yields both a `kbd` and a `mouse`, so both get driven.
pub fn pickHidEndpoint(desc: []const u8) PickSet {
    var out: PickSet = .{};
    if (desc.len == 0) return out;

    var cur_iface: u8 = 0;
    var cur_kind: ?Kind = null; // set when the current interface is one we drive
    var cur_is_boot = false; // boot subclass → needs SET_PROTOCOL(boot)
    var cur_rdesc_len: u16 = 0; // declared wDescriptorLength of the current interface
    var off: usize = desc[0];
    while (off + 2 <= desc.len) {
        const blen = desc[off];
        const btype = desc[off + 1];
        if (blen == 0) break;
        if (off + blen > desc.len) break; // descriptor body runs past real data
        if (btype == 4) { // interface descriptor
            cur_iface = desc[off + 2];
            const class = desc[off + 5];
            const subclass = desc[off + 6];
            const protocol = desc[off + 7];
            // Boot keyboard/mouse (subclass 1, proto 1/2), or a CANDIDATE absolute
            // pointer (HID class, proto 0 = no boot protocol, e.g. usb-tablet).
            cur_is_boot = (class == 3 and subclass == 1);
            cur_kind = if (cur_is_boot and protocol == 1) .keyboard else if (cur_is_boot and protocol == 2) .mouse else if (class == 3 and protocol == 0) .tablet else null;
            cur_rdesc_len = 0; // each interface declares its own HID descriptor
        } else if (btype == 0x21 and blen >= 9) { // HID class descriptor (follows its interface)
            // wDescriptorLength of the FIRST class descriptor entry (type 0x22,
            // the report descriptor) — HID 1.11 §6.2.1 layout.
            cur_rdesc_len = @as(u16, desc[off + 7]) | (@as(u16, desc[off + 8]) << 8);
        } else if (btype == 5) { // endpoint descriptor
            const addr = desc[off + 2];
            const is_int_in = (desc[off + 3] & 0x3) == 3 and (addr & 0x80) != 0;
            if (is_int_in and cur_kind != null) {
                const pick = Pick{
                    .iface = cur_iface,
                    .ep_addr = addr,
                    .ep_mps = @as(u32, desc[off + 4]) | (@as(u32, desc[off + 5]) << 8),
                    .ep_interval = desc[off + 6],
                    .kind = cur_kind.?,
                    .rdesc_len = cur_rdesc_len,
                };
                // Record the FIRST of each drivable interface. A boot keyboard and
                // a boot mouse are both kept (a composite device drives both); a
                // protocol-0 candidate is kept only for a device with no boot
                // interface (the caller classifies it from its report descriptor).
                if (cur_is_boot and pick.kind == .keyboard) {
                    if (out.kbd == null) out.kbd = pick else if (out.kbd2 == null) out.kbd2 = pick;
                } else if (cur_is_boot and pick.kind == .mouse) {
                    if (out.mouse == null) out.mouse = pick;
                } else if (out.candidate == null) {
                    out.candidate = pick;
                }
            }
        }
        off += blen;
    }
    return out;
}

/// Device Context Index (DCI) of an endpoint from its bEndpointAddress:
/// 2*ep_number + (IN ? 1 : 0).
///
/// THE DIRECTION BIT MUST COME FROM THE ADDRESS, never be assumed. Hard-coding it to 1
/// happens to be right for an interrupt-IN endpoint and wrong for a bulk-OUT one, so a
/// keyboard works and a USB disk does not: a stick with IN 0x81 / OUT 0x02 lands its OUT
/// context where "ep2 IN" belongs, and one with IN 0x81 / OUT 0x01 computes the SAME
/// index for both pipes — one context silently overwriting the other, and both
/// endpoints ringing a single doorbell.
pub fn dci(ep_addr: u8) u32 {
    return @as(u32, ep_addr & 0x0F) * 2 + @intFromBool(ep_addr & 0x80 != 0);
}

/// A decoded relative-mouse report: button bits (low 3) + signed X/Y deltas.
pub const MouseEvent = struct {
    buttons: u8,
    dx: i32,
    dy: i32,
};

/// Decode one mouse report per its descriptor-derived `layout`, with a
/// short-report fallback. Normally `layout` (boot `[buttons, dx8, dy8]`, or a
/// Report-ID shift / 16-bit deltas) places the fields. But some mice STREAM a
/// report shorter than their descriptor declares — a non-compliant
/// `[report-id][dx8][dy8]` the descriptor under-declares. The Logitech G Pro is
/// one: its descriptor declares an 8-byte report-ID-less 16-bit report (X at byte
/// 2), but on the wire it sends a 4-byte Report-ID-8 report with 8-bit dx at byte
/// 1, dy at byte 2. When the report doesn't fit `layout`, fall back to the HID
/// boot layout (dx8@1, dy8@2) — exactly where a report-ID-prefixed 8-bit motion
/// report puts its deltas, and `buttons & 0x7` masks the report-ID byte off.
/// Returns null only when neither layout fits.
///
/// `report` MUST be sliced to the ACTUAL transferred length. A buffer padded past
/// the real report defeats the fit check, so a long layout is read over short data
/// (the descriptor's 16-bit X read from the short report's Y byte, Y from stale
/// bytes past the report) — a scrambled cursor, the exact G Pro failure.
pub fn decodeMouse(report: []const u8, layout: MouseLayout) ?MouseEvent {
    if (decodeMouseLayout(report, layout)) |ev| return ev;
    // The report was too short for its descriptor's layout: the device
    // under-declared its wire format. Retry as a boot-style short report — unless
    // `layout` already IS the boot layout, in which case nothing shorter remains.
    if (layout.buttons_byte == 0 and layout.x_byte == 1 and layout.size_bytes == 1) return null;
    return decodeMouseLayout(report, .{});
}

/// Decode strictly per `layout`, or null if the report is too short for it.
fn decodeMouseLayout(report: []const u8, layout: MouseLayout) ?MouseEvent {
    const xb: usize = layout.x_byte;
    const yb: usize = xb + layout.size_bytes;
    const need: usize = @max(@as(usize, layout.buttons_byte) + 1, yb + layout.size_bytes);
    if (report.len < need) return null;
    const buttons = report[layout.buttons_byte] & 0x7;
    const dx: i32 = if (layout.size_bytes == 2)
        @as(i16, @bitCast(@as(u16, report[xb]) | (@as(u16, report[xb + 1]) << 8)))
    else
        @as(i8, @bitCast(report[xb]));
    const dy: i32 = if (layout.size_bytes == 2)
        @as(i16, @bitCast(@as(u16, report[yb]) | (@as(u16, report[yb + 1]) << 8)))
    else
        @as(i8, @bitCast(report[yb]));
    return .{ .buttons = buttons, .dx = dx, .dy = dy };
}

/// What changed between two keyboard boot reports. `keys[0..count]` are HID
/// usages pressed THIS report and `released[0..released_count]` those let go
/// (held keys appear in neither — the decode is edge-triggered); `next_last` is
/// this report's keycode slots, stored by the caller for the next diff.
///
/// Releases matter to anything that is not a line editor: a guest's evdev stack
/// is told a key is down until it is told otherwise, so a press with no matching
/// release is a key held forever. `mods`/`last_mods` carry the modifier bitmap
/// for the same reason — modifiers never appear in the key array at all.
pub const KeyPresses = struct {
    shift: bool,
    keys: [6]u8 = .{0} ** 6,
    count: usize = 0,
    released: [6]u8 = .{0} ** 6,
    released_count: usize = 0,
    /// This report's modifier bitmap, and the previous one's: bit i is usage
    /// 0xE0 + i, so a caller diffs them into the same press/release events.
    mods: u8 = 0,
    last_mods: u8 = 0,
    next_last: [6]u8 = .{0} ** 6,
};

/// Diff one HID keyboard boot report `[mods, _, k0..k5]` against the previous
/// report's keycode slots and modifier bitmap, so each key edge fires once.
/// Returns null for a report shorter than the 8-byte boot format.
pub fn decodeKeyboard(report: []const u8, last_keys: [6]u8, last_mods: u8) ?KeyPresses {
    if (report.len < 8) return null;
    const mods = report[0];
    var out = KeyPresses{
        .shift = (mods & 0x22) != 0, // left|right shift → uppercase
        .mods = mods,
        .last_mods = last_mods,
    };
    for (report[2..8]) |u| {
        if (u == 0) continue;
        if (!holds(&last_keys, u)) {
            out.keys[out.count] = u;
            out.count += 1;
        }
    }
    // A usage in the previous report and not in this one was let go. The two
    // loops are the same diff run in opposite directions.
    for (last_keys) |u| {
        if (u == 0) continue;
        if (!holds(report[2..8], u)) {
            out.released[out.released_count] = u;
            out.released_count += 1;
        }
    }
    @memcpy(&out.next_last, report[2..8]); // remember this report for the next diff
    return out;
}

/// Whether `slots` holds usage `u`.
fn holds(slots: []const u8, u: u8) bool {
    for (slots) |s| {
        if (s == u) return true;
    }
    return false;
}

// HID absolute-pointer logical maximum (usb-tablet report descriptor Logical Max).
pub const TABLET_LOGICAL_MAX: usize = 0x7FFF;

/// A decoded absolute-pointer report: button bits + X/Y scaled to the screen.
pub const TabletEvent = struct {
    buttons: u8,
    x: i32,
    y: i32,
};

/// Decode one absolute-pointer (usb-tablet) report `[buttons, x_lo, x_hi,
/// y_lo, y_hi, wheel]` with X/Y in logical units 0..32767, scaled to a
/// `width`×`height` screen. Returns null when the endpoint can't carry the
/// 5-byte minimum (buttons + 16-bit X + 16-bit Y).
///
/// QEMU rescales the host pointer to the logical range by the *window* size;
/// when the SDL window is resized or shown fullscreen, the scaling can briefly
/// emit values OUTSIDE 0..0x7FFF (the top bit set, i.e. >= 0x8000). Read as
/// raw u16 those wrap to ~65000 and the cursor jumps to / sticks in a corner.
/// Clamp to the declared logical range so any out-of-spec sample maps to a
/// screen edge, not a wrap.
pub fn decodeTablet(report: []const u8, mps: u32, width: usize, height: usize) ?TabletEvent {
    if (mps < 5) return null; // need at least buttons + 16-bit X + 16-bit Y
    if (report.len < 5) return null;
    const buttons = report[0] & 0x7;
    const ax_raw = @min(@as(usize, report[1]) | (@as(usize, report[2]) << 8), TABLET_LOGICAL_MAX);
    const ay_raw = @min(@as(usize, report[3]) | (@as(usize, report[4]) << 8), TABLET_LOGICAL_MAX);
    const ax: i32 = @intCast(ax_raw * (width - 1) / TABLET_LOGICAL_MAX);
    const ay: i32 = @intCast(ay_raw * (height - 1) / TABLET_LOGICAL_MAX);
    return .{ .buttons = buttons, .x = ax, .y = ay };
}

const std = @import("std");

// ---- Descriptor fixtures (byte-exact, real-world layouts) ----

// HID 1.11 §B.2 boot mouse report descriptor: 3 buttons, 8-bit relative X/Y,
// no Report ID — the wire layout QEMU's usb-mouse and any boot mouse streams.
pub const RDESC_BOOT_MOUSE = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x02, // Usage (Mouse)
    0xA1, 0x01, // Collection (Application)
    0x09, 0x01, //   Usage (Pointer)
    0xA1, 0x00, //   Collection (Physical)
    0x05, 0x09, //     Usage Page (Buttons)
    0x19, 0x01, //     Usage Minimum (1)
    0x29, 0x03, //     Usage Maximum (3)
    0x15, 0x00, //     Logical Minimum (0)
    0x25, 0x01, //     Logical Maximum (1)
    0x95, 0x03, //     Report Count (3)
    0x75, 0x01, //     Report Size (1)
    0x81, 0x02, //     Input (Data, Variable, Absolute) — buttons
    0x95, 0x01, //     Report Count (1)
    0x75, 0x05, //     Report Size (5)
    0x81, 0x01, //     Input (Constant) — padding
    0x05, 0x01, //     Usage Page (Generic Desktop)
    0x09, 0x30, //     Usage (X)
    0x09, 0x31, //     Usage (Y)
    0x15, 0x81, //     Logical Minimum (-127)
    0x25, 0x7F, //     Logical Maximum (127)
    0x75, 0x08, //     Report Size (8)
    0x95, 0x02, //     Report Count (2)
    0x81, 0x06, //     Input (Data, Variable, Relative) — X/Y
    0xC0, //   End Collection
    0xC0, // End Collection
};

// Logitech G Pro / G-series gaming-mouse report descriptor (the layout of the
// suspected native-mouse-dead device, vendor 0x046d): Report ID 2, SIXTEEN
// button bits, then 16-bit X/Y (logical ±32767), 8-bit wheel, consumer AC Pan.
// Wire report: [0x02, btn_lo, btn_hi, x_lo, x_hi, y_lo, y_hi, wheel, pan].
pub const RDESC_G_PRO = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x02, // Usage (Mouse)
    0xA1, 0x01, // Collection (Application)
    0x85, 0x02, //   Report ID (2)
    0x09, 0x01, //   Usage (Pointer)
    0xA1, 0x00, //   Collection (Physical)
    0x05, 0x09, //     Usage Page (Buttons)
    0x19, 0x01, //     Usage Minimum (1)
    0x29, 0x10, //     Usage Maximum (16)
    0x15, 0x00, //     Logical Minimum (0)
    0x25, 0x01, //     Logical Maximum (1)
    0x95, 0x10, //     Report Count (16)
    0x75, 0x01, //     Report Size (1)
    0x81, 0x02, //     Input (Data, Variable, Absolute) — 16 buttons
    0x05, 0x01, //     Usage Page (Generic Desktop)
    0x16, 0x01, 0x80, // Logical Minimum (-32767)
    0x26, 0xFF, 0x7F, // Logical Maximum (32767)
    0x75, 0x10, //     Report Size (16)
    0x95, 0x02, //     Report Count (2)
    0x09, 0x30, //     Usage (X)
    0x09, 0x31, //     Usage (Y)
    0x81, 0x06, //     Input (Data, Variable, Relative) — 16-bit X/Y
    0x15, 0x81, //     Logical Minimum (-127)
    0x25, 0x7F, //     Logical Maximum (127)
    0x75, 0x08, //     Report Size (8)
    0x95, 0x01, //     Report Count (1)
    0x09, 0x38, //     Usage (Wheel)
    0x81, 0x06, //     Input (Data, Variable, Relative) — wheel
    0x05, 0x0C, //     Usage Page (Consumer)
    0x0A, 0x38, 0x02, // Usage (AC Pan)
    0x95, 0x01, //     Report Count (1)
    0x81, 0x06, //     Input (Data, Variable, Relative) — AC Pan
    0xC0, //   End Collection
    0xC0, // End Collection
};

// HID 1.11 §E.6 boot keyboard report descriptor — no pointer usages at all.
pub const RDESC_BOOT_KEYBOARD = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x06, // Usage (Keyboard)
    0xA1, 0x01, // Collection (Application)
    0x05, 0x07, //   Usage Page (Key Codes)
    0x19, 0xE0, //   Usage Minimum (224)
    0x29, 0xE7, //   Usage Maximum (231)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x08, //   Report Count (8)
    0x81, 0x02, //   Input (Data, Variable, Absolute) — modifier byte
    0x95, 0x01, //   Report Count (1)
    0x75, 0x08, //   Report Size (8)
    0x81, 0x01, //   Input (Constant) — reserved byte
    0x95, 0x06, //   Report Count (6)
    0x75, 0x08, //   Report Size (8)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x65, //   Logical Maximum (101)
    0x05, 0x07, //   Usage Page (Key Codes)
    0x19, 0x00, //   Usage Minimum (0)
    0x29, 0x65, //   Usage Maximum (101)
    0x81, 0x00, //   Input (Data, Array) — 6-key rollover slots
    0xC0, // End Collection
};

// QEMU usb-tablet report descriptor core: absolute 16-bit X/Y (Logical Max
// 0x7FFF), 3 buttons — the .absolute classification case.
pub const RDESC_TABLET = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x02, // Usage (Mouse)
    0xA1, 0x01, // Collection (Application)
    0x09, 0x01, //   Usage (Pointer)
    0xA1, 0x00, //   Collection (Physical)
    0x05, 0x09, //     Usage Page (Buttons)
    0x19, 0x01, //     Usage Minimum (1)
    0x29, 0x03, //     Usage Maximum (3)
    0x15, 0x00, //     Logical Minimum (0)
    0x25, 0x01, //     Logical Maximum (1)
    0x95, 0x03, //     Report Count (3)
    0x75, 0x01, //     Report Size (1)
    0x81, 0x02, //     Input — buttons
    0x95, 0x01, //     Report Count (1)
    0x75, 0x05, //     Report Size (5)
    0x81, 0x01, //     Input (Constant) — padding
    0x05, 0x01, //     Usage Page (Generic Desktop)
    0x09, 0x30, //     Usage (X)
    0x09, 0x31, //     Usage (Y)
    0x15, 0x00, //     Logical Minimum (0)
    0x26, 0xFF, 0x7F, // Logical Maximum (32767)
    0x35, 0x00, //     Physical Minimum (0)
    0x46, 0xFF, 0x7F, // Physical Maximum (32767)
    0x75, 0x10, //     Report Size (16)
    0x95, 0x02, //     Report Count (2)
    0x81, 0x02, //     Input (Data, Variable, ABSOLUTE) — X/Y
    0xC0, //   End Collection
    0xC0, // End Collection
};

/// Build a config descriptor: 9-byte config header followed by `body`.
/// wTotalLength is stamped from the real total so the fixture is self-consistent.
pub fn cfg(comptime body: []const u8) [9 + body.len]u8 {
    const total: u16 = 9 + body.len;
    return [_]u8{
        9,  2, @truncate(total & 0xFF), @truncate(total >> 8),
        1,  1, 0,                       0xA0,
        50,
    } ++ body[0..body.len].*;
}

/// A 9-byte interface descriptor (bNumEndpoints 1) for the given triple.
pub fn ifaceDesc(num: u8, class: u8, subclass: u8, protocol: u8) [9]u8 {
    return .{ 9, 4, num, 0, 1, class, subclass, protocol, 0 };
}

/// A 7-byte endpoint descriptor: interrupt type, the given address/MPS/interval.
pub fn epDesc(addr: u8, mps: u16, interval: u8) [7]u8 {
    return .{ 7, 5, addr, 0x03, @truncate(mps & 0xFF), @truncate(mps >> 8), interval };
}

// The standard 9-byte HID class descriptor that sits between interface and
// endpoint on real devices — the walk must skip it by bLength, not assume
// interface descriptors are followed directly by endpoints.
pub const HID_CLASS_DESC = [_]u8{ 9, 0x21, 0x11, 0x01, 0x00, 0x01, 0x22, 0x40, 0x00 };
