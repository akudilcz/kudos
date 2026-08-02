//! The object name table, shared by buffers and textures.
//!
//! GL object lifetime has a step that surprises people, and both object types have it,
//! so it lives here once.
//!
//! **A name is not an object.** `glGenBuffers` returns *names*: integers the
//! implementation promises not to hand out again. Nothing exists yet. The object comes
//! into being when the name is first BOUND — which is exactly why `glIsBuffer` returns
//! false for a name that has only been generated. Two states, not one.
//!
//! **Zero is not a name.** It means "no object bound", so it is never generated, never
//! deleted, and binding it unbinds.
//!
//! A device handle appears later still: a bound buffer has no storage until
//! `glBufferData` gives it some. So a record can exist with no handle, and drawing from
//! it is an error rather than a fault.

const idraw = @import("idraw");

/// How many live names one table holds. A fixed table, because the alternative is an
/// allocation on a path an application can drive in a loop.
pub const MAX_OBJECTS: u32 = 256;

pub const Record = struct {
    /// Reserved by gen, or claimed directly by bind — the standard permits an
    /// application to bind a name it never generated.
    named: bool = false,
    /// True once bound at least once. This is what glIs* reports.
    is_object: bool = false,
    /// The device's storage, once something has given it any.
    handle: ?u32 = null,
    size: usize = 0,
    usage: idraw.Usage = .static,
    /// Free-form per-type state (a texture's format and levels).
    aux: u32 = 0,
    /// A CPU copy of a buffer's contents.
    ///
    /// The GPU's copy cannot be read back, and an array of GL_FIXED living in a buffer
    /// object has to be widened to float before any fetcher can decode it — so the only
    /// way to serve that combination is to remember what was uploaded. The cost is a
    /// second copy of every buffer; the alternative is a legal ES program that cannot
    /// be drawn.
    shadow: []u8 = &.{},
};

pub const Error = error{OutOfNames};

pub const Table = struct {
    recs: [MAX_OBJECTS]Record = .{Record{}} ** MAX_OBJECTS,

    fn index(name: u32) ?usize {
        if (name == 0 or name > MAX_OBJECTS) return null;
        return name - 1;
    }

    /// glGen*: reserve `n` unused names. The standard does not promise they are
    /// contiguous or ascending, only that they are unused.
    pub fn gen(self: *Table, n: u32, out: [*]u32) Error!void {
        var made: u32 = 0;
        for (&self.recs, 0..) |*r, i| {
            if (made == n) break;
            if (r.named) continue;
            r.* = .{ .named = true };
            out[made] = @intCast(i + 1);
            made += 1;
        }
        if (made != n) {
            // Reserve nothing rather than some: a partial gen would hand the
            // application names it did not ask for and cannot free.
            for (out[0..made]) |name| self.delete(name);
            return Error.OutOfNames;
        }
    }

    /// Binding a name makes it an object, whether or not it was ever generated.
    pub fn ensureNamed(self: *Table, name: u32) Error!void {
        const i = index(name) orelse return Error.OutOfNames;
        self.recs[i].named = true;
        self.recs[i].is_object = true;
    }

    pub fn isObject(self: *const Table, name: u32) bool {
        const i = index(name) orelse return false;
        return self.recs[i].is_object;
    }

    /// Read-only lookup, for the lowering — which takes the state by const pointer and
    /// must not be able to change it on the way past.
    pub fn recordConst(self: *const Table, name: u32) ?*const Record {
        const i = index(name) orelse return null;
        if (!self.recs[i].named) return null;
        return &self.recs[i];
    }

    pub fn record(self: *Table, name: u32) ?*Record {
        const i = index(name) orelse return null;
        if (!self.recs[i].named) return null;
        return &self.recs[i];
    }

    pub fn deviceHandle(self: *Table, name: u32) ?u32 {
        const r = self.record(name) orelse return null;
        return r.handle;
    }

    pub fn setDeviceHandle(self: *Table, name: u32, h: u32, size: usize, usage: idraw.Usage) void {
        const r = self.record(name) orelse return;
        r.handle = h;
        r.size = size;
        r.usage = usage;
    }

    pub fn delete(self: *Table, name: u32) void {
        const i = index(name) orelse return;
        self.recs[i] = .{}; // the name returns to the pool
    }
};
