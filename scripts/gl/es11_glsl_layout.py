#!/usr/bin/env python3
"""Generate the shaders' uniform-block declaration from the uniform-image ABI.

The constant buffer is an ABI with several sides: es/uniforms.zig packs the bytes, the
shaders read them, and the software backend (drivers/gl/soft.zig) reads them too. Nothing
checks that they agree — a disagreement does not fail to build, it renders garbage, or
renders correctly until someone adds a field. That is the worst shape a bug can have.

So there is one side. The field offsets are defined once, on the seam (idraw.uniform);
this reads them from there and emits the GLSL, which means the layout cannot drift: move
a field in idraw.uniform, regenerate, and the shader moves with it.

The offsets are all 16-byte aligned by construction, which is exactly what std140 wants,
so the generated block's natural layout lands on them — and the assertions below check
that rather than assuming it.

Usage (from the repo root):

    python3 scripts/gl/es11_glsl_layout.py            # write the GLSL
    python3 scripts/gl/es11_glsl_layout.py --check    # is the committed copy current?

`--check` is what the gate runs (scripts/tests/check.sh). Generating a file and then
trusting everyone to regenerate it is the same as not generating it.
"""

import os
import re
import sys

OUTPUT = os.path.join(os.path.dirname(__file__), "..", "..",
                      "src", "drivers", "gl", "shaders", "gles_state.glsl")

UNIFORMS = os.path.join(os.path.dirname(__file__), "..", "..",
                        "src", "drivers", "gl", "es", "uniforms.zig")
# The field offsets are the ABI, and they live on the seam so gles, the shaders and the
# software backend all read the one definition. uniforms.zig packs to them; this reads them.
IDRAW = os.path.join(os.path.dirname(__file__), "..", "..",
                     "src", "iface", "idraw.zig")
LIMITS = os.path.join(os.path.dirname(__file__), "..", "..",
                      "src", "drivers", "gl", "es", "limits.zig")
STATE = os.path.join(os.path.dirname(__file__), "..", "..",
                     "src", "drivers", "gl", "es", "state.zig")

# Where the shaders find their resources. Bindings 0 and 1 are the two texture units, so
# the unit index IS the binding; the state block follows them. shader_factory.c declares
# the same set, and the kernel mirrors it when it binds the descriptors.
UNIT_BINDING_BASE = 0
STATE_BINDING = 2


def consts(path, pattern):
    src = open(path).read()
    out = {}
    for name, value in re.findall(pattern, src):
        out[name] = int(value, 0)
    return out


def enum_values(decl_re, prefix, src):
    """Turn a Zig enum's declaration order into #defines.

    Zig numbers a plain enum by declaration order, and so does the bytecode in
    uniforms.zig — which means adding a case in the middle silently renumbers every
    case after it. Nothing would fail to build; the shader would just start reading
    MODULATE where the state said DECAL. Reading the order out of the source is the
    only version of this that cannot rot.
    """
    m = re.search(decl_re, src)
    if not m:
        sys.exit(f"could not find {prefix} in es/state.zig — did the enum move?")
    names = [n.strip() for n in m.group(1).split(",") if n.strip()]
    return [(f"{prefix}{n.upper()}", i) for i, n in enumerate(names)]


def main():
    off = consts(IDRAW, r"pub const (OFF_\w+|LIGHT_STRIDE|TEXENV_STRIDE): usize = (0x[0-9A-Fa-f]+);")
    lim = consts(LIMITS, r"pub const (MAX_LIGHTS|MAX_CLIP_PLANES|MAX_TEXTURE_UNITS): u32 = (\d+);")
    if not off or not lim:
        sys.exit("could not read the layout constants; did idraw.uniform or es/limits.zig move?")

    max_lights = lim["MAX_LIGHTS"]
    max_units = lim["MAX_TEXTURE_UNITS"]
    max_clip = lim["MAX_CLIP_PLANES"]

    # Walk the block in declaration order and check every field lands where uniforms.zig
    # says. std140 rounds a struct or array element up to 16 bytes, which is why the Zig
    # side aligns everything to 16 in the first place — this is where the two agree.
    cursor = 0
    fields = []

    def field(decl, size, want, comment=""):
        nonlocal cursor
        if cursor != want:
            sys.exit(f"layout mismatch: {decl} would sit at 0x{cursor:X}, "
                     f"uniforms.zig says 0x{want:X}. Add padding or reorder.")
        fields.append((decl, cursor, comment))
        cursor += size

    field("mat4 mvp;", 64, off["OFF_MVP"], "projection * modelview, clip-corrected")
    field("mat4 modelview;", 64, off["OFF_MODELVIEW"], "for eye-space position")
    field("mat3 normal_matrix;", 48, off["OFF_NORMAL_MATRIX"], "three vec4s in std140")
    field(f"mat4 tex_matrix[{max_units}];", 64 * max_units, off["OFF_TEX_MATRIX"])
    field("vec4 material[5];", 80, off["OFF_MATERIAL"],
          "ambient, diffuse, specular, emission, (shininess,0,0,0)")
    field("vec4 light_model_ambient;", 16, off["OFF_LIGHT_MODEL_AMBIENT"])
    field("vec4 fog_color;", 16, off["OFF_FOG_COLOR"])
    field("vec4 fog_params;", 16, off["OFF_FOG_PARAMS"], "density, start, end, 1/(end-start)")
    field("vec4 misc;", 16, off["OFF_MISC"], "alpha_ref, point_size, 0, 0")
    field(f"vec4 clip_plane[{max_clip}];", 16 * max_clip, off["OFF_CLIP_PLANES"])
    field(f"Light lights[{max_lights}];", off["LIGHT_STRIDE"] * max_lights, off["OFF_LIGHTS"])
    field(f"TexEnv texenv[{max_units}];", off["TEXENV_STRIDE"] * max_units, off["OFF_TEXENV"])

    out = []
    w = out.append
    w("// OpenGL ES 1.1 fixed-function state, as the shaders read it.\n")
    w("//\n")
    w("// GENERATED. DO NOT EDIT. Regenerate with:\n")
    w("//\n")
    w("//     python3 scripts/gl/es11_glsl_layout.py\n")
    w("//\n")
    w("// Read out of src/drivers/gl/es/uniforms.zig, which packs these bytes. The two\n")
    w("// sides of a constant-buffer ABI that disagree do not fail to build — they render\n")
    w("// garbage — so there is only one side, and this is the other end of it.\n")
    w("//\n")
    w(f"// NOT push constants: this block is {cursor} bytes and NVK's maxPushConstantsSize\n")
    w("// is 256. It is a uniform buffer, bound as a cbuf by address, which also keeps it away\n")
    w("// from the LOAD_CONSTANT_BUFFER window that hangs the engine past 16 dwords.\n")
    w("//\n")
    w("// What follows is that block, GlState, together with the limits that size it, the\n")
    w("// Light and TexEnv structs it holds, and the texture-environment bytecode vocabulary.\n")
    w("\n")
    w("// The standard's minimums, as es/limits.zig states them. The shaders size their\n")
    w("// loops from these rather than from a literal that would drift.\n")
    w(f"#define MAX_LIGHTS            {max_lights}\n")
    w(f"#define MAX_CLIP_PLANES       {max_clip}\n")
    w(f"#define MAX_TEXTURE_UNITS     {max_units}\n")
    w("\n")
    w("struct Light {\n")
    w("    vec4 ambient;\n")
    w("    vec4 diffuse;\n")
    w("    vec4 specular;\n")
    w("    vec4 position;      // eye space; w = 0 directional, 1 positional\n")
    w("    vec4 spot_dir;      // xyz direction, w = cos(cutoff); -1 means not a spotlight\n")
    w("    vec4 attenuation;   // constant, linear, quadratic, spot_exponent\n")
    w("};\n\n")
    w("struct TexEnv {\n")
    w("    vec4 color;\n")
    w("    // The COMBINE bytecode. Four words carrying 905,969,664 settings per unit — the\n")
    w("    // reason this is interpreted rather than compiled into a program per state.\n")
    w("    uvec4 words;\n")
    w("};\n\n")
    w(f"layout(std140, set = 0, binding = {STATE_BINDING}) uniform GlState {{\n")
    for decl, at, comment in fields:
        pad = " " * max(1, 34 - len(decl))
        c = f"  // 0x{at:03X}" + (f"  {comment}" if comment else "")
        w(f"    {decl}{pad}{c}\n")
    w("} gl;\n\n")

    # The unit bindings are declared, not defined, here: only the fragment stage samples,
    # and a sampler declared in this header would land in the vertex program too — where
    # the set layout does not grant it a stage. So the numbers live here and the
    # declarations live in gles.frag.
    for u in range(max_units):
        w(f"#define TEX{u}_BINDING          {UNIT_BINDING_BASE + u}\n")
    w("\n")

    # The bytecode's own vocabulary, read out of es/state.zig's enums.
    state_src = open(STATE).read()
    groups = [
        ("// TEXTURE_ENV_MODE — the five fixed functions, then COMBINE.",
         enum_values(r"mode: enum \{([^}]+)\}", "ENV_", state_src)),
        ("// COMBINE_RGB.",
         enum_values(r"combine_rgb: enum \{([^}]+)\}", "CRGB_", state_src)),
        ("// COMBINE_ALPHA — no DOT3: a dot product has no alpha-only meaning.",
         enum_values(r"combine_alpha: enum \{([^}]+)\}", "CALPHA_", state_src)),
        ("// SRC_n — where an argument comes from.",
         enum_values(r"pub const Source = enum \{([^}]+)\};", "SRC_", state_src)),
        ("// OPERAND_n for RGB — two bits, because rgb may read either colour or alpha.",
         enum_values(r"pub const OperandRgb = enum \{([^}]+)\};", "OPRGB_", state_src)),
        ("// OPERAND_n for ALPHA — one bit: an alpha operand can only read alpha.",
         enum_values(r"pub const OperandAlpha = enum \{([^}]+)\};", "OPA_", state_src)),
    ]
    w("// ── the texture-environment bytecode ─────────────────────────────────────────\n")
    w("//\n")
    w("// Names and values read from es/state.zig, packed by es/uniforms.zig's envWord0..3.\n")
    w("// Zig numbers an enum by declaration order and so does the bytecode, so these are\n")
    w("// generated rather than transcribed — inserting a case renumbers its successors,\n")
    w("// and a transcribed copy would keep compiling while reading the wrong function.\n")
    for comment, vals in groups:
        w(f"{comment}\n")
        for name, i in vals:
            w(f"#define {name}{' ' * max(1, 26 - len(name))}{i}u\n")
        w("\n")

    # The field positions. These mirror envWord0..3 in es/uniforms.zig; that packer and
    # this unpacker are the two ends of one ABI, and the RasterSim diff is what holds
    # them together.
    w("// Where each field sits, mirroring es/uniforms.zig's envWord0..3.\n")
    w("#define ENV_MODE(w0)              ((w0) & 7u)\n")
    w("#define ENV_CRGB(w0)              (((w0) >> 3) & 0xFu)\n")
    w("#define ENV_CALPHA(w0)            (((w0) >> 7) & 7u)\n")
    w("#define ENV_SRC_RGB(w1, i)        (((w1) >> (2u * (i))) & 3u)\n")
    w("#define ENV_SRC_ALPHA(w1, i)      (((w1) >> (6u + 2u * (i))) & 3u)\n")
    w("#define ENV_OP_RGB(w2, i)         (((w2) >> (2u * (i))) & 3u)\n")
    w("#define ENV_OP_ALPHA(w2, i)       (((w2) >> (6u + (i))) & 1u)\n")
    w("// The scales are shifts: 1, 2, 4 become 0, 1, 2.\n")
    w("#define ENV_RGB_SCALE(w3)         float(1u << ((w3) & 3u))\n")
    w("#define ENV_ALPHA_SCALE(w3)       float(1u << (((w3) >> 2) & 3u))\n")
    w("\n")
    w(f"// GLSTATE_BYTES = {cursor}\n")
    w("//\n")
    w("// That is es/uniforms.zig's SIZE, arrived at independently by walking this block.\n")
    w("// If the two ever disagree the shaders read the wrong bytes, so --check refuses.\n")
    return "".join(out)


if __name__ == "__main__":
    text = main()
    if "--check" in sys.argv:
        try:
            have = open(OUTPUT).read()
        except FileNotFoundError:
            sys.exit(f"{OUTPUT} does not exist; run: python3 scripts/gl/es11_glsl_layout.py")
        if have != text:
            sys.exit("gles_state.glsl is stale — es/uniforms.zig has moved under it.\n"
                     "  Regenerate: python3 scripts/gl/es11_glsl_layout.py")
    else:
        with open(OUTPUT, "w") as f:
            f.write(text)
        print(f"wrote {OUTPUT} ({len(text)} bytes)", file=sys.stderr)
