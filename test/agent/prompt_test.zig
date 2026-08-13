//! Host test of src/agent/prompt.zig — the guard that keeps the model's API
//! documentation in lockstep with the real ABI.

const std = @import("std");
const prompt = @import("prompt");
const abi = prompt.abi_ref;

test "every callable Api field is documented in the system prompt" {
    inline for (@typeInfo(abi.Api).@"struct".fields) |f| {
        if (comptime (f.name[0] == '_' or std.mem.eql(u8, f.name, "version") or std.mem.eql(u8, f.name, "ctx"))) continue;
        std.testing.expect(std.mem.indexOf(u8, prompt.SYSTEM, f.name) != null) catch {
            std.debug.print("prompt is missing Api.{s}\n", .{f.name});
            return error.MissingApiDoc;
        };
    }
}

test "system prompt states the required entry signature" {
    try std.testing.expect(std.mem.indexOf(u8, prompt.SYSTEM, "pub fn main(api: *const abi.Api) i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.SYSTEM, "position-independent") != null);
}

test "every bindable capability, and every call on it, reaches both prompts (MOD-007)" {
    // An undocumented capability is never bound; one with undocumented calls is
    // bound and then guessed at. Both prompts carry the list because a feature
    // binds through the same registry an app does.
    inline for (abi.CAPABILITIES) |cap| {
        inline for (.{ prompt.SYSTEM, prompt.IMPROVE_SYSTEM }) |text| {
            std.testing.expect(std.mem.indexOf(u8, text, @tagName(cap.id)) != null) catch {
                std.debug.print("a prompt is missing capability {s}\n", .{@tagName(cap.id)});
                return error.MissingCapabilityDoc;
            };
            inline for (@typeInfo(cap.vtable).@"struct".fields) |f| {
                if (comptime (f.name[0] == '_' or std.mem.eql(u8, f.name, "version"))) continue;
                std.testing.expect(std.mem.indexOf(u8, text, f.name) != null) catch {
                    std.debug.print("a prompt is missing {s}.{s}\n", .{ @tagName(cap.id), f.name });
                    return error.MissingCapabilityCallDoc;
                };
            }
        }
    }
}

test "the prompts state how a capability is bound, and that it can be refused" {
    // The two things a module author gets wrong without being told: that binding
    // happens through a call rather than a struct field, and that null is a normal
    // answer rather than a failure to work around.
    inline for (.{ prompt.SYSTEM, prompt.IMPROVE_SYSTEM }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, text, "get_interface") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "null") != null);
    }
}

test "every callable FeatureApi field is documented in the improve prompt" {
    inline for (@typeInfo(abi.FeatureApi).@"struct".fields) |f| {
        if (comptime (f.name[0] == '_' or std.mem.eql(u8, f.name, "version") or std.mem.eql(u8, f.name, "ctx"))) continue;
        std.testing.expect(std.mem.indexOf(u8, prompt.IMPROVE_SYSTEM, f.name) != null) catch {
            std.debug.print("improve prompt is missing FeatureApi.{s}\n", .{f.name});
            return error.MissingFeatureApiDoc;
        };
    }
}

test "improve prompt states the feature entry signature and the copy-by-value rule" {
    try std.testing.expect(std.mem.indexOf(u8, prompt.IMPROVE_SYSTEM, "pub fn register(api: *const abi.FeatureApi) i32") != null);
    // The load-bearing lifetime rule: the pointer does not outlive register.
    try std.testing.expect(std.mem.indexOf(u8, prompt.IMPROVE_SYSTEM, "does NOT outlive") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.IMPROVE_SYSTEM, "Copy the struct BY VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.IMPROVE_SYSTEM, "Position independence") != null);
}
