//! Desktop control and readback — the seam between anything that wants to DRIVE
//! the desktop and the desktop itself (spec AGT-023, AGT-024).
//!
//! The agent lives in the console group and the desktop in ui/, and ui/ is the
//! group ABOVE: it calls into console (shell.execute), so console must never
//! call back into it. The way a lower group asks the desktop to do something is
//! therefore the way the guest boot path asks for a VM (ivirt.postBootRequest) —
//! park a REQUEST, and let the desktop apply it on its own core, in the same
//! input pass where a hotkey or a mouse click would have done the same thing.
//! Nothing here touches a window; the window list belongs to the desktop.
//!
//! The other direction is a PUBLISH: the desktop writes what it can see — the
//! window list, and the heads-up display's own numbers — into fixed buffers that
//! anyone may read. A reader gets the desktop's last word, never a pointer into
//! its live state.
//!
//! LEAF: fixed buffers and atomics, no ui types and no allocation, so the kernel
//! and the host tests both compile it. Single-slot on purpose — a queue would
//! let a caller stack up window operations faster than the desktop applies them,
//! and "the machine took my last instruction" is the honest contract.

const std = @import("std");

/// The application kinds the desktop can open directly — the vocabulary of
/// `spawnApp` and of the shell/agent commands that ask for one.
///
/// It lives HERE, in the contract, rather than in either group that uses it:
/// the console's Desktop contract names it (a shell command spawns a window)
/// and the apps group's hosted union names it (an app instance IS one of
/// these), and neither group may import the other. Anything else makes the
/// catalogue of what this machine can open the property of whichever group
/// happened to need it first.
pub const AppKind = enum {
    term,
    system,
    clock,
    calc,
    vm,

    /// The kind a person or an agent named, or null if this machine has no
    /// such application. ONE home for the spelling of these names, so the
    /// shell, the agent tool and the remote-request inbox cannot drift over
    /// what `calc` is called.
    pub fn fromName(name: []const u8) ?AppKind {
        inline for (@typeInfo(AppKind).@"enum".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @field(AppKind, f.name);
        }
        return null;
    }
};

/// What can be asked of one window. The set is exactly what a person can do to
/// a window with the mouse and the hotkeys, which is the whole point: a
/// capability the user has and the agent does not is a capability the agent
/// will fake by clicking coordinates.
pub const Action = enum(u8) {
    /// Raise and focus the front-most visible window whose title contains the
    /// name — where keystrokes land afterwards.
    focus,
    /// Fill the screen, or put it back where it was (the title-bar button).
    maximise,
    /// Send it to the dock.
    minimise,
    /// Bring it back from the dock.
    restore,
    /// Close it, exactly as its red button does.
    close,
};

/// The longest window name a request carries. A title is a short label; a needle
/// longer than this is a caller confusing "name" with "description".
pub const MAX_NAME: usize = 48;

/// How much published text each readback holds. The window list is one line per
/// window and the dashboard is a screenful of numbers; both are bounded because
/// this is a fixed buffer in the kernel image, and a reader that wants more
/// detail asks the thing that owns it.
pub const MAX_WINDOWS_TEXT: usize = 1024;
pub const MAX_DASHBOARD_TEXT: usize = 2048;

// ── the request: parked by anyone, applied by the desktop ───────────────────

var pending: bool = false;
var pending_action: Action = .focus;
var name_buf: [MAX_NAME]u8 = undefined;
var name_len: usize = 0;

/// One window operation, as taken by the desktop.
pub const Request = struct {
    action: Action,
    /// The window to act on: a substring of its title. Empty means the focused
    /// window, which is what "maximise this" means when nobody named anything.
    name: []const u8,
};

/// ANY CALLER (the agent, a shell command): ask the desktop for `action` on the
/// window whose title contains `name`. False when a request is already waiting —
/// the desktop applies one per input pass, and silently replacing an unapplied
/// request would drop an instruction the caller was told had been taken.
pub fn postAction(action: Action, name: []const u8) bool {
    if (@atomicLoad(bool, &pending, .acquire)) return false;
    const n = @min(name.len, MAX_NAME);
    @memcpy(name_buf[0..n], name[0..n]);
    name_len = n;
    pending_action = action;
    @atomicStore(bool, &pending, true, .release);
    return true;
}

/// THE DESKTOP (its own core, in the input pass): take the pending request.
pub fn takeAction() ?Request {
    if (!@atomicLoad(bool, &pending, .acquire)) return null;
    const r = Request{ .action = pending_action, .name = name_buf[0..name_len] };
    @atomicStore(bool, &pending, false, .release);
    return r;
}

// ── the readback: published by the desktop, read by anyone ──────────────────

var windows_buf: [MAX_WINDOWS_TEXT]u8 = undefined;
var windows_len: usize = 0;

var dashboard_buf: [MAX_DASHBOARD_TEXT]u8 = undefined;
var dashboard_len: usize = 0;

/// THE DESKTOP: publish the window list as text — one line per window, in the
/// desktop's own order, marked with what a person can see at a glance (which
/// one has focus, which are in the dock). Truncated rather than refused: a
/// partial list is still an answer, and the alternative is no answer at all.
pub fn publishWindows(text: []const u8) void {
    const n = @min(text.len, MAX_WINDOWS_TEXT);
    @memcpy(windows_buf[0..n], text[0..n]);
    @atomicStore(usize, &windows_len, n, .release);
}

/// The desktop's last published window list. Empty before the first publish —
/// which is a true statement about a machine whose desktop has not yet drawn.
pub fn windows() []const u8 {
    return windows_buf[0..@atomicLoad(usize, &windows_len, .acquire)];
}

/// THE DESKTOP: publish the heads-up display's own sample as text, so what the
/// F1 display shows and what a reader is told are the same numbers from the
/// same instant rather than two samples taken by two samplers.
pub fn publishDashboard(text: []const u8) void {
    const n = @min(text.len, MAX_DASHBOARD_TEXT);
    @memcpy(dashboard_buf[0..n], text[0..n]);
    @atomicStore(usize, &dashboard_len, n, .release);
}

/// The desktop's last published dashboard sample.
pub fn dashboard() []const u8 {
    return dashboard_buf[0..@atomicLoad(usize, &dashboard_len, .acquire)];
}

/// Drop every parked request and published text — the host tests' way back to a
/// known state, and the only writer of `pending` outside `postAction`.
pub fn reset() void {
    @atomicStore(bool, &pending, false, .release);
    name_len = 0;
    @atomicStore(usize, &windows_len, 0, .release);
    @atomicStore(usize, &dashboard_len, 0, .release);
}
