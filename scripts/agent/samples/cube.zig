//! A rotating cube in the module's own window, on the GPU — the reference
//! `Interface.gl` app: bind the capability, open a window, record a lit frame
//! per loop, stop when the window closes. Everything a generated 3D app does,
//! in the fewest lines that do it honestly.
//!
//! No std imports beyond the ABI: matrices are hand-rolled (a projection and a
//! rotation are a dozen multiplies), because position independence forbids
//! nothing here — it is simply all this app needs.

const abi = @import("abi.zig");

const W: u32 = 480;
const H: u32 = 360;

/// 6 faces * 2 triangles * 3 vertices, positions and face normals unrolled —
/// flat arrays, no pointers to globals (the position-independence contract).
const NVERTS: u32 = 36;

fn cubeVertex(i: u32) [3]f32 {
    // Face f (0..5), corner c (0..5) of two triangles: 0,1,2 / 0,2,3 of the
    // quad. Quads wound counter-clockwise seen from outside.
    const f = i / 6;
    const corners = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const corner = corners[i % 6];
    // Quad corners in the face's plane.
    const u: f32 = if (corner == 1 or corner == 2) 1 else -1;
    const v: f32 = if (corner == 2 or corner == 3) 1 else -1;
    return switch (f) {
        0 => .{ u, v, 1 }, // +Z
        1 => .{ -u, v, -1 }, // -Z
        2 => .{ 1, v, -u }, // +X
        3 => .{ -1, v, u }, // -X
        4 => .{ u, 1, -v }, // +Y
        else => .{ u, -1, v }, // -Y
    };
}

fn cubeNormal(i: u32) [3]f32 {
    return switch (i / 6) {
        0 => .{ 0, 0, 1 },
        1 => .{ 0, 0, -1 },
        2 => .{ 1, 0, 0 },
        3 => .{ -1, 0, 0 },
        4 => .{ 0, 1, 0 },
        else => .{ 0, -1, 0 },
    };
}

/// A perspective projection (the frustum glFrustum builds), column-major as
/// load_matrix expects. Vertical FOV fixed by `top`; near/far generous.
fn projection(aspect: f32) [16]f32 {
    const near: f32 = 1.0;
    const far: f32 = 20.0;
    const top: f32 = 0.5; // ~53 degree vertical field of view at near=1
    const right = top * aspect;
    var m = [_]f32{0} ** 16;
    m[0] = near / right;
    m[5] = near / top;
    m[10] = -(far + near) / (far - near);
    m[11] = -1;
    m[14] = -2 * far * near / (far - near);
    return m;
}

pub fn main(api: *const abi.Api) i32 {
    const raw_win = api.get_interface(api.ctx, @intFromEnum(abi.Interface.window), 1) orelse {
        const msg = "this kudos does not publish the window interface to this run\n";
        api.print(api.ctx, msg, msg.len);
        return 1;
    };
    const wins: *const abi.WindowApi = @ptrCast(@alignCast(raw_win));
    const raw_gl = api.get_interface(api.ctx, @intFromEnum(abi.Interface.gl), 1) orelse {
        const msg = "this kudos does not publish the gl interface to this run\n";
        api.print(api.ctx, msg, msg.len);
        return 1;
    };
    const gl: *const abi.GlApi = @ptrCast(@alignCast(raw_gl));

    const title = "rotating cube";
    const win = wins.create(api.ctx, title, title.len, W, H, abi.WINDOW_SCENE);
    if (win == 0) {
        const msg = "no window (is the desktop up? are all window slots taken?)\n";
        api.print(api.ctx, msg, msg.len);
        return 1;
    }

    // Build the mesh once, on the stack of main — small enough (36 * 3 floats
    // twice), and the interface copies it every frame anyway.
    var verts: [NVERTS * 3]f32 = undefined;
    var norms: [NVERTS * 3]f32 = undefined;
    var i: u32 = 0;
    while (i < NVERTS) : (i += 1) {
        const p = cubeVertex(i);
        const n = cubeNormal(i);
        verts[i * 3 + 0] = p[0];
        verts[i * 3 + 1] = p[1];
        verts[i * 3 + 2] = p[2];
        norms[i * 3 + 0] = n[0];
        norms[i * 3 + 1] = n[1];
        norms[i * 3 + 2] = n[2];
    }
    const proj = projection(@as(f32, @floatFromInt(W)) / @as(f32, @floatFromInt(H)));

    while (!api.cancelled(api.ctx) and !wins.closed(api.ctx, win)) {
        // The angle comes from the machine's clock, not a frame counter, so the
        // spin rate is real time however the compositor paces us: 40°/s.
        const angle: f32 = @as(f32, @floatFromInt(api.millis(api.ctx) % 9000)) * (360.0 / 9000.0);

        if (!gl.frame(api.ctx, win)) break; // the window went away
        gl.enable(api.ctx, abi.GL_DEPTH_TEST);
        gl.enable(api.ctx, abi.GL_CULL_FACE);
        gl.enable(api.ctx, abi.GL_LIGHTING);
        gl.clear_color(api.ctx, 0.07, 0.08, 0.11, 1.0);

        gl.matrix_mode(api.ctx, abi.GL_PROJECTION);
        gl.load_matrix(api.ctx, &proj);
        gl.matrix_mode(api.ctx, abi.GL_MODELVIEW);
        gl.load_identity(api.ctx);
        gl.translate(api.ctx, 0, 0, -5);
        gl.rotate(api.ctx, 20, 1, 0, 0); // a fixed tilt, so three faces show
        gl.rotate(api.ctx, angle, 0, 1, 0); // the spin

        gl.color(api.ctx, 0.30, 0.55, 0.95, 1.0); // kudos blue
        gl.vertices(api.ctx, &verts, NVERTS);
        gl.normals(api.ctx, &norms, NVERTS);
        gl.draw_arrays(api.ctx, abi.GL_TRIANGLES, 0, NVERTS);

        gl.end_frame(api.ctx); // publishes, and paces us to the compositor
    }
    return 0;
}
