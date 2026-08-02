#!/usr/bin/env python3
"""Regenerate the OpenGL ES 1.1 token and type definitions from the Khronos header.

357 tokens is a mechanical transcription, and a mechanical transcription done by hand
is a list of typos waiting to be debugged against a black screen. This reads the
header instead, so a token is either right or absent.

Source of truth: the Khronos OpenGL ES 1.1 header (GLES/gl.h) — the Khronos ES 1.1 header, generated from
the Khronos XML API registry (MIT). The normative prose is
the OpenGL ES 1.1.12 Full Specification; the header is where the NUMBERS live, because the
specification itself never states them.

Usage (from the repo root):

    python3 scripts/gl/es11_enums.py > src/drivers/gl/es/enums.zig
"""

import os
import re
import sys

HEADER = os.path.join(os.path.dirname(__file__), "..", "..",
                      "references", "raw", "es11-gl.h")

DEFINE = re.compile(r"^#define\s+(GL_\w+)\s+(\S+)\s*$", re.M)

# The C types the API is spelled in, and what each is in Zig. GLfixed and GLclampx are
# the fixed-point profile's; both are plain 32-bit integers holding 16.16, which is why
# neither can be told apart from GLint by the type system alone.
TYPES = """
pub const GLenum = u32;
pub const GLboolean = u8;
pub const GLbitfield = u32;
pub const GLbyte = i8;
pub const GLshort = i16;
pub const GLint = i32;
pub const GLsizei = i32;
pub const GLubyte = u8;
pub const GLushort = u16;
pub const GLuint = u32;
pub const GLfloat = f32;
pub const GLclampf = f32;
/// Signed 16.16 fixed-point: the integer part in the high 16 bits, the fraction in the
/// low 16. Convert with es/fixed.zig — never by hand.
pub const GLfixed = i32;
/// A GLfixed the specification also clamps to [0, 1].
pub const GLclampx = i32;
pub const GLintptr = isize;
pub const GLsizeiptr = isize;
"""


def main():
    src = open(HEADER).read()

    tokens = []
    for name, value in DEFINE.findall(src):
        # Version stamps are build metadata, not API tokens.
        if name.startswith("GL_VERSION_ES_CM") or name in ("GL_OES_VERSION_1_0",):
            continue
        if value.endswith("u"):  # e.g. 0xFFFFFFFFu
            value = value[:-1]
        tokens.append((name, value))

    if not tokens:
        sys.exit(f"no tokens found in {HEADER}")

    out = sys.stdout.write
    out("//! OpenGL ES 1.1 tokens and types — the names the specification is written in.\n")
    out("//!\n")
    out("//! **Generated. DO NOT EDIT.** Regenerate with:\n")
    out("//!\n")
    out("//!     python3 scripts/gl/es11_enums.py > src/drivers/gl/es/enums.zig\n")
    out("//!\n")
    out("//! Read out of the Khronos OpenGL ES 1.1 header (GLES/gl.h) (the Khronos header, generated in turn from\n")
    out("//! the Khronos XML API registry). The specification prose never states these numbers;\n")
    out("//! the header is the only place they exist, so it is the only honest source for them.\n")
    out("//!\n")
    out("//! These are the values that cross the API boundary — what an application passes to\n")
    out("//! glEnable or glTexParameteri. They are NOT how state is stored: everything inside\n")
    out("//! this module works in real Zig enums and structs, and a token is mapped to one at\n")
    out("//! the entry point, once, where an unknown token becomes GL_INVALID_ENUM. A GLenum\n")
    out("//! reaching any deeper than that is a bug.\n")
    out("\n")
    out("// ── types ───────────────────────────────────────────────────────────────────\n")
    out(TYPES)
    out("\n// ── tokens ──────────────────────────────────────────────────────────────────\n\n")

    width = max(len(n) for n, _ in tokens)
    for name, value in tokens:
        ty = "GLbitfield" if _is_bitfield(name) else ("GLenum" if value.startswith("0x") else "GLint")
        out(f"pub const {name}: {ty} = {' ' * (width - len(name))}{value};\n")

    out(f"\n// {len(tokens)} tokens.\n")


def _is_bitfield(name):
    return name.endswith("_BUFFER_BIT") or name in ("GL_ALL_ATTRIB_BITS",)


if __name__ == "__main__":
    main()
