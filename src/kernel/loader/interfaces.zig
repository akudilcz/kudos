//! The kudos capability-interface registry behind `abi.Api.get_interface`.
//! Resolves an app's `{id, version}` request to a published capability vtable
//! pointer, or null.
//!
//! Default posture is deny: a sandboxed `.kudos` app is handed NO capability
//! beyond the base `Api`. A capability (an `abi.Interface` such as `.draw`,
//! `.vfs`, `.net`) is published here only once someone has judged its vtable fit
//! to expose to untrusted code — this is the one place that decision is recorded,
//! so widening the app surface means editing this file.

const abi = @import("abi");

/// Resolve a capability request. Returns the vtable for `{id, version}`, or null
/// when the kernel does not publish that interface at a compatible version.
pub fn get(id: u32, version: u32) ?*const anyopaque {
    _ = id;
    _ = version;
    // Nothing is published to sandboxed apps yet. Each `abi.Interface` gets a
    // vetted vtable and an arm here as it is exposed.
    return null;
}
