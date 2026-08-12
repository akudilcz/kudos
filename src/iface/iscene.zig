//! Scene mailbox behind the `gl` capability: a module records an OpenGL ES 1.1
//! subset on its own core, the desktop replays it into the module's window
//! inside the one desktop GL frame (MOD-015).
//!
//! Data crosses by COPY into these static pools on the module's core; core 0
//! reads only the pools. Two slots, SPSC: the module records into one while the
//! desktop replays the other.
//!
//! The encoding is kernel-internal — a module binds `abi.GlApi`, never a `Cmd` —
//! so it can change without touching the ABI. Validated before replay
//! (`validate`): a bad command costs the frame, never a wild GL call. There is
//! no colour-array op: a lit per-vertex-colour draw wedges the 4090.

const std = @import("std");
const abi = @import("abi");

/// One recorded command. `a`..`d` are op-specific scalars (GL enums, counts,
/// floats as bits); `off`/`n` span the float or index pool.
pub const Cmd = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    off: u32 = 0,
    n: u32 = 0,
};

/// The recordable subset. One arm each in `validate` and the replay; a missed
/// arm is a compile error.
pub const Op = enum(u16) {
    /// a = GL capability enum (validate's allow-list).
    enable,
    disable,
    /// a = GL_MODELVIEW | GL_PROJECTION.
    matrix_mode,
    load_identity,
    /// off/n = 16 floats, column-major (glLoadMatrixf's layout).
    load_matrix,
    mult_matrix,
    /// a..d = angle_deg, x, y, z as f32 bits.
    rotate,
    /// a..c = x, y, z as f32 bits.
    translate,
    scale,
    /// a..d = r, g, b, a as f32 bits — the MATERIAL colour.
    color,
    /// off/n = n*3 floats; subsequent draws index this data.
    vertices,
    /// off/n = n*3 floats; enables lit shading.
    normals,
    /// a = primitive mode, b = first vertex, c = count.
    draw_arrays,
    /// a = primitive mode, off/n = n u16 indices in the index pool.
    draw_elements,
    /// a..d = r, g, b, a as f32 bits.
    clear_color,
    depth_func,
    /// a = GL_CW | GL_CCW.
    front_face,
};

/// Slot capacities. A frame is a handful of commands; the float pool holds a
/// ~10k-vertex mesh with normals. Two slots of everything, ~1.3 MB of BSS.
pub const MAX_CMDS = 512;
pub const MAX_FLOATS = 64 * 1024;
pub const MAX_INDICES = 16 * 1024;

pub const Slot = struct {
    cmds: [MAX_CMDS]Cmd = undefined,
    ncmds: u32 = 0,
    floats: [MAX_FLOATS]f32 = undefined,
    nfloats: u32 = 0,
    indices: [MAX_INDICES]u16 = undefined,
    nindices: u32 = 0,
    /// Recording overran a pool: the frame is incomplete, drop it whole.
    overflowed: bool = false,
};

/// Scene windows the machine can host, one mailbox each (`iface/iwindow.zig`
/// owns the same count).
pub const MAX_WINDOWS: usize = abi.WINDOW_MAX_COUNT;

/// Per window: two slots, the producer recording into one while the consumer
/// replays the other.
var slots: [MAX_WINDOWS][2]Slot = @splat(@splat(.{}));
var write_idx: [MAX_WINDOWS]u1 = @splat(0);
var read_idx: [MAX_WINDOWS]u1 = @splat(0);
/// Publish flags; the release/acquire barrier for slot content.
var ready: [MAX_WINDOWS][2]bool = @splat(@splat(false));

// ── producer (the capability adapter, on the module's core) ───────────────────

pub fn recording(win: usize) *Slot {
    return &slots[win][write_idx[win]];
}

/// Whether the producer may publish. The gate is the slot the flip moves
/// recording INTO — the other one: publishing hands the current slot to the
/// consumer, and the producer needs the other back. Gating the current slot
/// instead lets the producer record over a frame mid-replay.
pub fn canPublish(win: usize) bool {
    return !@atomicLoad(bool, &ready[win][write_idx[win] ^ 1], .acquire);
}

/// Publish the recorded slot and move recording to the other, which
/// `canPublish` proved is the producer's.
pub fn publish(win: usize) void {
    @atomicStore(bool, &ready[win][write_idx[win]], true, .release);
    write_idx[win] ^= 1;
    resetSlot(&slots[win][write_idx[win]]);
}

pub fn resetSlot(s: *Slot) void {
    s.ncmds = 0;
    s.nfloats = 0;
    s.nindices = 0;
    s.overflowed = false;
}

/// Append one command; a full array poisons the frame.
pub fn record(s: *Slot, cmd: Cmd) void {
    if (s.ncmds == MAX_CMDS) {
        s.overflowed = true;
        return;
    }
    s.cmds[s.ncmds] = cmd;
    s.ncmds += 1;
}

/// Copy floats into the pool, returning the span's offset; poisons the frame
/// when they do not fit.
pub fn pushFloats(s: *Slot, data: []const f32) u32 {
    if (s.nfloats + data.len > MAX_FLOATS) {
        s.overflowed = true;
        return 0;
    }
    const off = s.nfloats;
    @memcpy(s.floats[off..][0..data.len], data);
    s.nfloats += @intCast(data.len);
    return off;
}

/// As `pushFloats`, for u16 indices.
pub fn pushIndices(s: *Slot, data: []const u16) u32 {
    if (s.nindices + data.len > MAX_INDICES) {
        s.overflowed = true;
        return 0;
    }
    const off = s.nindices;
    @memcpy(s.indices[off..][0..data.len], data);
    s.nindices += @intCast(data.len);
    return off;
}

// ── consumer (the desktop, core 0, at frame time) ────────────────────────────

/// The frame to replay for this window, or null. Holding it keeps the producer
/// out of the slot until `release`.
pub fn takeFrame(win: usize) ?*const Slot {
    if (!@atomicLoad(bool, &ready[win][read_idx[win]], .acquire)) return null;
    return &slots[win][read_idx[win]];
}

pub fn release(win: usize) void {
    @atomicStore(bool, &ready[win][read_idx[win]], false, .release);
    read_idx[win] ^= 1;
}

/// Blank one window's slots (its window closed).
pub fn reset(win: usize) void {
    resetSlot(&slots[win][0]);
    resetSlot(&slots[win][1]);
    @atomicStore(bool, &ready[win][0], false, .release);
    @atomicStore(bool, &ready[win][1], false, .release);
}

/// Blank every window's slots (a module's run ended).
pub fn resetAll() void {
    var i: usize = 0;
    while (i < MAX_WINDOWS) : (i += 1) reset(i);
}

// ── validation (pure) ────────────────────────────────────────────────────────

/// GL enums the recorder accepts, spelled as the specification spells them.
/// abi.zig repeats the ones a MODULE needs (it may import nothing); a test pins
/// the two sets equal.
pub const GL_MODELVIEW: u32 = 0x1700;
pub const GL_PROJECTION: u32 = 0x1701;
pub const GL_TRIANGLES: u32 = 0x0004;
pub const GL_TRIANGLE_STRIP: u32 = 0x0005;
pub const GL_TRIANGLE_FAN: u32 = 0x0006;
pub const GL_LINES: u32 = 0x0001;
pub const GL_DEPTH_TEST: u32 = 0x0B71;
pub const GL_CULL_FACE: u32 = 0x0B44;
pub const GL_LIGHTING: u32 = 0x0B50;
pub const GL_CW: u32 = 0x0900;
pub const GL_CCW: u32 = 0x0901;
pub const GL_NEVER: u32 = 0x0200;
pub const GL_ALWAYS: u32 = 0x0207;

/// Why a frame was refused — one value per rule, so the counter names the bug.
pub const Verdict = enum {
    ok,
    overflow,
    /// A span points outside the pool that was filled.
    bad_span,
    /// A draw reads past the vertex data provided.
    draw_past_data,
    index_past_data,
    bad_enum,
    /// A matrix span is not exactly 16 floats.
    bad_matrix,
};

/// Check every rule the replay depends on. A frame that passes is replayed
/// without re-checking.
pub fn validate(s: *const Slot) Verdict {
    if (s.overflowed) return .overflow;
    var nverts: u32 = 0; // from the latest `vertices` op
    for (s.cmds[0..s.ncmds]) |cmd| {
        switch (cmd.op) {
            .enable, .disable => switch (cmd.a) {
                GL_DEPTH_TEST, GL_CULL_FACE, GL_LIGHTING => {},
                else => return .bad_enum,
            },
            .matrix_mode => switch (cmd.a) {
                GL_MODELVIEW, GL_PROJECTION => {},
                else => return .bad_enum,
            },
            .load_identity, .rotate, .translate, .scale, .color, .clear_color => {},
            .load_matrix, .mult_matrix => {
                if (cmd.n != 16) return .bad_matrix;
                if (cmd.off + cmd.n > s.nfloats) return .bad_span;
            },
            .vertices, .normals => {
                if (cmd.n == 0 or cmd.off + cmd.n * 3 > s.nfloats) return .bad_span;
                if (cmd.op == .vertices) nverts = cmd.n;
            },
            .draw_arrays => {
                if (!primOk(cmd.a)) return .bad_enum;
                if (cmd.b + cmd.c > nverts) return .draw_past_data;
            },
            .draw_elements => {
                if (!primOk(cmd.a)) return .bad_enum;
                if (cmd.off + cmd.n > s.nindices) return .bad_span;
                for (s.indices[cmd.off .. cmd.off + cmd.n]) |ix| {
                    if (ix >= nverts) return .index_past_data;
                }
            },
            .depth_func => {
                if (cmd.a < GL_NEVER or cmd.a > GL_ALWAYS) return .bad_enum;
            },
            .front_face => switch (cmd.a) {
                GL_CW, GL_CCW => {},
                else => return .bad_enum,
            },
        }
    }
    return .ok;
}

fn primOk(mode: u32) bool {
    return switch (mode) {
        GL_TRIANGLES, GL_TRIANGLE_STRIP, GL_TRIANGLE_FAN, GL_LINES => true,
        else => false,
    };
}
