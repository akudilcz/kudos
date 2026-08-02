//! `gles` — OpenGL ES 1.1, Common profile. The API applications call.
//!
//! This is the module an app imports by name: `const gles = @import("gles");`. It is
//! pure — it holds no hardware, allocates nothing, and can be driven to completion on
//! the host — in the same shape as `keymap`, the pure half of the keyboard driver. It
//! lowers onto `idraw` (src/iface/idraw.zig), which is where an RTX 4090 finally gets
//! involved.
//!
//! ## The shape of this API, versus C's
//!
//! Three differences, all deliberate:
//!
//! **Every entry point takes a `*Context`.** C's OpenGL has a current context because C
//! has no better way to thread one; it makes every call a hidden global read and makes
//! two windows fight. kudos draws N windows at once, so the context is an argument.
//!
//! **`gl` prefixes are gone.** `glRotatef` is `gles.rotatef`: the prefix was C's
//! substitute for a module system and Zig has one. The mapping is exact and mechanical,
//! and a generated list (entrypoints.zig) plus the comptime test at the bottom of this
//! file makes the presence of all 145 entry-point names a build failure when it stops
//! being true. Their behaviour is covered separately by the host tests against the
//! specification's state tables: the surface is checked here, not its conformance.
//!
//! **Nothing returns an error.** That is GL's own design, not a shortcut: a command
//! given something illegal records an error code and *does nothing else* — no state
//! change, no partial effect. The application calls `getError` when it wants to know.
//! This is what lets a program issue a thousand commands without a branch between them.
//!
//! ## What is live
//!
//! State, transforms, objects, queries, validation, the draw path, and texture
//! image upload are implemented and host-tested: a draw picks its program, packs
//! its constants, builds its pipeline, resolves where every attribute's bytes
//! live, and issues; `texImage2D` expands external formats through the unpack
//! path (es/unpack.zig) into device textures — the glyph atlas, images, and
//! model textures all upload through it in production.
//!
//! Below this module, the device implementation and its 216 shader programs are their
//! own work: `gles` is complete against `idraw`, and proven against a fake of it.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification and its reference pages.

const std = @import("std");
const idraw = @import("idraw");
const enums = @import("enums.zig");
const errors = @import("errors.zig");
const fixed = @import("fixed.zig");
const limits = @import("limits.zig");
const matrix = @import("matrix.zig");
const state = @import("state.zig");
pub const entrypoints = @import("entrypoints.zig");
/// The uniform-block layout constants, re-exported for the conformance tests
/// that assert on packed offsets (test/drivers/gl/gles_test.zig) — the offsets ARE the
/// contract with the shader twins.
pub const uniforms = @import("uniforms.zig");

// The tokens and types the standard is written in — `gles.GL_TRIANGLES`,
// `gles.GLfixed`. Explicit re-exports of every public declaration in
// enums.zig (usingnamespace left the language in Zig 0.15): the API
// surface is now visible here, and a token added to enums.zig is exported
// by adding its line — the compile error at the missing site is the reminder.
pub const GLenum = enums.GLenum;
pub const GLboolean = enums.GLboolean;
pub const GLbitfield = enums.GLbitfield;
pub const GLbyte = enums.GLbyte;
pub const GLshort = enums.GLshort;
pub const GLint = enums.GLint;
pub const GLsizei = enums.GLsizei;
pub const GLubyte = enums.GLubyte;
pub const GLushort = enums.GLushort;
pub const GLuint = enums.GLuint;
pub const GLfloat = enums.GLfloat;
pub const GLclampf = enums.GLclampf;
pub const GLfixed = enums.GLfixed;
pub const GLclampx = enums.GLclampx;
pub const GLintptr = enums.GLintptr;
pub const GLsizeiptr = enums.GLsizeiptr;
pub const GL_VERSION_ES_CL_1_0 = enums.GL_VERSION_ES_CL_1_0;
pub const GL_VERSION_ES_CL_1_1 = enums.GL_VERSION_ES_CL_1_1;
pub const GL_DEPTH_BUFFER_BIT = enums.GL_DEPTH_BUFFER_BIT;
pub const GL_STENCIL_BUFFER_BIT = enums.GL_STENCIL_BUFFER_BIT;
pub const GL_COLOR_BUFFER_BIT = enums.GL_COLOR_BUFFER_BIT;
pub const GL_FALSE = enums.GL_FALSE;
pub const GL_TRUE = enums.GL_TRUE;
pub const GL_POINTS = enums.GL_POINTS;
pub const GL_LINES = enums.GL_LINES;
pub const GL_LINE_LOOP = enums.GL_LINE_LOOP;
pub const GL_LINE_STRIP = enums.GL_LINE_STRIP;
pub const GL_TRIANGLES = enums.GL_TRIANGLES;
pub const GL_TRIANGLE_STRIP = enums.GL_TRIANGLE_STRIP;
pub const GL_TRIANGLE_FAN = enums.GL_TRIANGLE_FAN;
pub const GL_NEVER = enums.GL_NEVER;
pub const GL_LESS = enums.GL_LESS;
pub const GL_EQUAL = enums.GL_EQUAL;
pub const GL_LEQUAL = enums.GL_LEQUAL;
pub const GL_GREATER = enums.GL_GREATER;
pub const GL_NOTEQUAL = enums.GL_NOTEQUAL;
pub const GL_GEQUAL = enums.GL_GEQUAL;
pub const GL_ALWAYS = enums.GL_ALWAYS;
pub const GL_ZERO = enums.GL_ZERO;
pub const GL_ONE = enums.GL_ONE;
pub const GL_SRC_COLOR = enums.GL_SRC_COLOR;
pub const GL_ONE_MINUS_SRC_COLOR = enums.GL_ONE_MINUS_SRC_COLOR;
pub const GL_SRC_ALPHA = enums.GL_SRC_ALPHA;
pub const GL_ONE_MINUS_SRC_ALPHA = enums.GL_ONE_MINUS_SRC_ALPHA;
pub const GL_DST_ALPHA = enums.GL_DST_ALPHA;
pub const GL_ONE_MINUS_DST_ALPHA = enums.GL_ONE_MINUS_DST_ALPHA;
pub const GL_DST_COLOR = enums.GL_DST_COLOR;
pub const GL_ONE_MINUS_DST_COLOR = enums.GL_ONE_MINUS_DST_COLOR;
pub const GL_SRC_ALPHA_SATURATE = enums.GL_SRC_ALPHA_SATURATE;
pub const GL_CLIP_PLANE0 = enums.GL_CLIP_PLANE0;
pub const GL_CLIP_PLANE1 = enums.GL_CLIP_PLANE1;
pub const GL_CLIP_PLANE2 = enums.GL_CLIP_PLANE2;
pub const GL_CLIP_PLANE3 = enums.GL_CLIP_PLANE3;
pub const GL_CLIP_PLANE4 = enums.GL_CLIP_PLANE4;
pub const GL_CLIP_PLANE5 = enums.GL_CLIP_PLANE5;
pub const GL_FRONT = enums.GL_FRONT;
pub const GL_BACK = enums.GL_BACK;
pub const GL_FRONT_AND_BACK = enums.GL_FRONT_AND_BACK;
pub const GL_FOG = enums.GL_FOG;
pub const GL_LIGHTING = enums.GL_LIGHTING;
pub const GL_TEXTURE_2D = enums.GL_TEXTURE_2D;
pub const GL_CULL_FACE = enums.GL_CULL_FACE;
pub const GL_ALPHA_TEST = enums.GL_ALPHA_TEST;
pub const GL_BLEND = enums.GL_BLEND;
pub const GL_COLOR_LOGIC_OP = enums.GL_COLOR_LOGIC_OP;
pub const GL_DITHER = enums.GL_DITHER;
pub const GL_STENCIL_TEST = enums.GL_STENCIL_TEST;
pub const GL_DEPTH_TEST = enums.GL_DEPTH_TEST;
pub const GL_POINT_SMOOTH = enums.GL_POINT_SMOOTH;
pub const GL_LINE_SMOOTH = enums.GL_LINE_SMOOTH;
pub const GL_SCISSOR_TEST = enums.GL_SCISSOR_TEST;
pub const GL_COLOR_MATERIAL = enums.GL_COLOR_MATERIAL;
pub const GL_NORMALIZE = enums.GL_NORMALIZE;
pub const GL_RESCALE_NORMAL = enums.GL_RESCALE_NORMAL;
pub const GL_VERTEX_ARRAY = enums.GL_VERTEX_ARRAY;
pub const GL_NORMAL_ARRAY = enums.GL_NORMAL_ARRAY;
pub const GL_COLOR_ARRAY = enums.GL_COLOR_ARRAY;
pub const GL_TEXTURE_COORD_ARRAY = enums.GL_TEXTURE_COORD_ARRAY;
pub const GL_MULTISAMPLE = enums.GL_MULTISAMPLE;
pub const GL_SAMPLE_ALPHA_TO_COVERAGE = enums.GL_SAMPLE_ALPHA_TO_COVERAGE;
pub const GL_SAMPLE_ALPHA_TO_ONE = enums.GL_SAMPLE_ALPHA_TO_ONE;
pub const GL_SAMPLE_COVERAGE = enums.GL_SAMPLE_COVERAGE;
pub const GL_NO_ERROR = enums.GL_NO_ERROR;
pub const GL_INVALID_ENUM = enums.GL_INVALID_ENUM;
pub const GL_INVALID_VALUE = enums.GL_INVALID_VALUE;
pub const GL_INVALID_OPERATION = enums.GL_INVALID_OPERATION;
pub const GL_STACK_OVERFLOW = enums.GL_STACK_OVERFLOW;
pub const GL_STACK_UNDERFLOW = enums.GL_STACK_UNDERFLOW;
pub const GL_OUT_OF_MEMORY = enums.GL_OUT_OF_MEMORY;
pub const GL_EXP = enums.GL_EXP;
pub const GL_EXP2 = enums.GL_EXP2;
pub const GL_FOG_DENSITY = enums.GL_FOG_DENSITY;
pub const GL_FOG_START = enums.GL_FOG_START;
pub const GL_FOG_END = enums.GL_FOG_END;
pub const GL_FOG_MODE = enums.GL_FOG_MODE;
pub const GL_FOG_COLOR = enums.GL_FOG_COLOR;
pub const GL_CW = enums.GL_CW;
pub const GL_CCW = enums.GL_CCW;
pub const GL_CURRENT_COLOR = enums.GL_CURRENT_COLOR;
pub const GL_CURRENT_NORMAL = enums.GL_CURRENT_NORMAL;
pub const GL_CURRENT_TEXTURE_COORDS = enums.GL_CURRENT_TEXTURE_COORDS;
pub const GL_POINT_SIZE = enums.GL_POINT_SIZE;
pub const GL_POINT_SIZE_MIN = enums.GL_POINT_SIZE_MIN;
pub const GL_POINT_SIZE_MAX = enums.GL_POINT_SIZE_MAX;
pub const GL_POINT_FADE_THRESHOLD_SIZE = enums.GL_POINT_FADE_THRESHOLD_SIZE;
pub const GL_POINT_DISTANCE_ATTENUATION = enums.GL_POINT_DISTANCE_ATTENUATION;
pub const GL_SMOOTH_POINT_SIZE_RANGE = enums.GL_SMOOTH_POINT_SIZE_RANGE;
pub const GL_LINE_WIDTH = enums.GL_LINE_WIDTH;
pub const GL_SMOOTH_LINE_WIDTH_RANGE = enums.GL_SMOOTH_LINE_WIDTH_RANGE;
pub const GL_ALIASED_POINT_SIZE_RANGE = enums.GL_ALIASED_POINT_SIZE_RANGE;
pub const GL_ALIASED_LINE_WIDTH_RANGE = enums.GL_ALIASED_LINE_WIDTH_RANGE;
pub const GL_CULL_FACE_MODE = enums.GL_CULL_FACE_MODE;
pub const GL_FRONT_FACE = enums.GL_FRONT_FACE;
pub const GL_SHADE_MODEL = enums.GL_SHADE_MODEL;
pub const GL_DEPTH_RANGE = enums.GL_DEPTH_RANGE;
pub const GL_DEPTH_WRITEMASK = enums.GL_DEPTH_WRITEMASK;
pub const GL_DEPTH_CLEAR_VALUE = enums.GL_DEPTH_CLEAR_VALUE;
pub const GL_DEPTH_FUNC = enums.GL_DEPTH_FUNC;
pub const GL_STENCIL_CLEAR_VALUE = enums.GL_STENCIL_CLEAR_VALUE;
pub const GL_STENCIL_FUNC = enums.GL_STENCIL_FUNC;
pub const GL_STENCIL_VALUE_MASK = enums.GL_STENCIL_VALUE_MASK;
pub const GL_STENCIL_FAIL = enums.GL_STENCIL_FAIL;
pub const GL_STENCIL_PASS_DEPTH_FAIL = enums.GL_STENCIL_PASS_DEPTH_FAIL;
pub const GL_STENCIL_PASS_DEPTH_PASS = enums.GL_STENCIL_PASS_DEPTH_PASS;
pub const GL_STENCIL_REF = enums.GL_STENCIL_REF;
pub const GL_STENCIL_WRITEMASK = enums.GL_STENCIL_WRITEMASK;
pub const GL_MATRIX_MODE = enums.GL_MATRIX_MODE;
pub const GL_VIEWPORT = enums.GL_VIEWPORT;
pub const GL_MODELVIEW_STACK_DEPTH = enums.GL_MODELVIEW_STACK_DEPTH;
pub const GL_PROJECTION_STACK_DEPTH = enums.GL_PROJECTION_STACK_DEPTH;
pub const GL_TEXTURE_STACK_DEPTH = enums.GL_TEXTURE_STACK_DEPTH;
pub const GL_MODELVIEW_MATRIX = enums.GL_MODELVIEW_MATRIX;
pub const GL_PROJECTION_MATRIX = enums.GL_PROJECTION_MATRIX;
pub const GL_TEXTURE_MATRIX = enums.GL_TEXTURE_MATRIX;
pub const GL_ALPHA_TEST_FUNC = enums.GL_ALPHA_TEST_FUNC;
pub const GL_ALPHA_TEST_REF = enums.GL_ALPHA_TEST_REF;
pub const GL_BLEND_DST = enums.GL_BLEND_DST;
pub const GL_BLEND_SRC = enums.GL_BLEND_SRC;
pub const GL_LOGIC_OP_MODE = enums.GL_LOGIC_OP_MODE;
pub const GL_SCISSOR_BOX = enums.GL_SCISSOR_BOX;
pub const GL_COLOR_CLEAR_VALUE = enums.GL_COLOR_CLEAR_VALUE;
pub const GL_COLOR_WRITEMASK = enums.GL_COLOR_WRITEMASK;
pub const GL_MAX_LIGHTS = enums.GL_MAX_LIGHTS;
pub const GL_MAX_CLIP_PLANES = enums.GL_MAX_CLIP_PLANES;
pub const GL_MAX_TEXTURE_SIZE = enums.GL_MAX_TEXTURE_SIZE;
pub const GL_MAX_MODELVIEW_STACK_DEPTH = enums.GL_MAX_MODELVIEW_STACK_DEPTH;
pub const GL_MAX_PROJECTION_STACK_DEPTH = enums.GL_MAX_PROJECTION_STACK_DEPTH;
pub const GL_MAX_TEXTURE_STACK_DEPTH = enums.GL_MAX_TEXTURE_STACK_DEPTH;
pub const GL_MAX_VIEWPORT_DIMS = enums.GL_MAX_VIEWPORT_DIMS;
pub const GL_MAX_TEXTURE_UNITS = enums.GL_MAX_TEXTURE_UNITS;
pub const GL_SUBPIXEL_BITS = enums.GL_SUBPIXEL_BITS;
pub const GL_RED_BITS = enums.GL_RED_BITS;
pub const GL_GREEN_BITS = enums.GL_GREEN_BITS;
pub const GL_BLUE_BITS = enums.GL_BLUE_BITS;
pub const GL_ALPHA_BITS = enums.GL_ALPHA_BITS;
pub const GL_DEPTH_BITS = enums.GL_DEPTH_BITS;
pub const GL_STENCIL_BITS = enums.GL_STENCIL_BITS;
pub const GL_POLYGON_OFFSET_UNITS = enums.GL_POLYGON_OFFSET_UNITS;
pub const GL_POLYGON_OFFSET_FILL = enums.GL_POLYGON_OFFSET_FILL;
pub const GL_POLYGON_OFFSET_FACTOR = enums.GL_POLYGON_OFFSET_FACTOR;
pub const GL_TEXTURE_BINDING_2D = enums.GL_TEXTURE_BINDING_2D;
pub const GL_VERTEX_ARRAY_SIZE = enums.GL_VERTEX_ARRAY_SIZE;
pub const GL_VERTEX_ARRAY_TYPE = enums.GL_VERTEX_ARRAY_TYPE;
pub const GL_VERTEX_ARRAY_STRIDE = enums.GL_VERTEX_ARRAY_STRIDE;
pub const GL_NORMAL_ARRAY_TYPE = enums.GL_NORMAL_ARRAY_TYPE;
pub const GL_NORMAL_ARRAY_STRIDE = enums.GL_NORMAL_ARRAY_STRIDE;
pub const GL_COLOR_ARRAY_SIZE = enums.GL_COLOR_ARRAY_SIZE;
pub const GL_COLOR_ARRAY_TYPE = enums.GL_COLOR_ARRAY_TYPE;
pub const GL_COLOR_ARRAY_STRIDE = enums.GL_COLOR_ARRAY_STRIDE;
pub const GL_TEXTURE_COORD_ARRAY_SIZE = enums.GL_TEXTURE_COORD_ARRAY_SIZE;
pub const GL_TEXTURE_COORD_ARRAY_TYPE = enums.GL_TEXTURE_COORD_ARRAY_TYPE;
pub const GL_TEXTURE_COORD_ARRAY_STRIDE = enums.GL_TEXTURE_COORD_ARRAY_STRIDE;
pub const GL_VERTEX_ARRAY_POINTER = enums.GL_VERTEX_ARRAY_POINTER;
pub const GL_NORMAL_ARRAY_POINTER = enums.GL_NORMAL_ARRAY_POINTER;
pub const GL_COLOR_ARRAY_POINTER = enums.GL_COLOR_ARRAY_POINTER;
pub const GL_TEXTURE_COORD_ARRAY_POINTER = enums.GL_TEXTURE_COORD_ARRAY_POINTER;
pub const GL_SAMPLE_BUFFERS = enums.GL_SAMPLE_BUFFERS;
pub const GL_SAMPLES = enums.GL_SAMPLES;
pub const GL_SAMPLE_COVERAGE_VALUE = enums.GL_SAMPLE_COVERAGE_VALUE;
pub const GL_SAMPLE_COVERAGE_INVERT = enums.GL_SAMPLE_COVERAGE_INVERT;
pub const GL_NUM_COMPRESSED_TEXTURE_FORMATS = enums.GL_NUM_COMPRESSED_TEXTURE_FORMATS;
pub const GL_COMPRESSED_TEXTURE_FORMATS = enums.GL_COMPRESSED_TEXTURE_FORMATS;
pub const GL_DONT_CARE = enums.GL_DONT_CARE;
pub const GL_FASTEST = enums.GL_FASTEST;
pub const GL_NICEST = enums.GL_NICEST;
pub const GL_PERSPECTIVE_CORRECTION_HINT = enums.GL_PERSPECTIVE_CORRECTION_HINT;
pub const GL_POINT_SMOOTH_HINT = enums.GL_POINT_SMOOTH_HINT;
pub const GL_LINE_SMOOTH_HINT = enums.GL_LINE_SMOOTH_HINT;
pub const GL_FOG_HINT = enums.GL_FOG_HINT;
pub const GL_GENERATE_MIPMAP_HINT = enums.GL_GENERATE_MIPMAP_HINT;
pub const GL_LIGHT_MODEL_AMBIENT = enums.GL_LIGHT_MODEL_AMBIENT;
pub const GL_LIGHT_MODEL_TWO_SIDE = enums.GL_LIGHT_MODEL_TWO_SIDE;
pub const GL_AMBIENT = enums.GL_AMBIENT;
pub const GL_DIFFUSE = enums.GL_DIFFUSE;
pub const GL_SPECULAR = enums.GL_SPECULAR;
pub const GL_POSITION = enums.GL_POSITION;
pub const GL_SPOT_DIRECTION = enums.GL_SPOT_DIRECTION;
pub const GL_SPOT_EXPONENT = enums.GL_SPOT_EXPONENT;
pub const GL_SPOT_CUTOFF = enums.GL_SPOT_CUTOFF;
pub const GL_CONSTANT_ATTENUATION = enums.GL_CONSTANT_ATTENUATION;
pub const GL_LINEAR_ATTENUATION = enums.GL_LINEAR_ATTENUATION;
pub const GL_QUADRATIC_ATTENUATION = enums.GL_QUADRATIC_ATTENUATION;
pub const GL_BYTE = enums.GL_BYTE;
pub const GL_UNSIGNED_BYTE = enums.GL_UNSIGNED_BYTE;
pub const GL_SHORT = enums.GL_SHORT;
pub const GL_UNSIGNED_SHORT = enums.GL_UNSIGNED_SHORT;
pub const GL_UNSIGNED_INT = enums.GL_UNSIGNED_INT;
pub const GL_FLOAT = enums.GL_FLOAT;
pub const GL_FIXED = enums.GL_FIXED;
pub const GL_CLEAR = enums.GL_CLEAR;
pub const GL_AND = enums.GL_AND;
pub const GL_AND_REVERSE = enums.GL_AND_REVERSE;
pub const GL_COPY = enums.GL_COPY;
pub const GL_AND_INVERTED = enums.GL_AND_INVERTED;
pub const GL_NOOP = enums.GL_NOOP;
pub const GL_XOR = enums.GL_XOR;
pub const GL_OR = enums.GL_OR;
pub const GL_NOR = enums.GL_NOR;
pub const GL_EQUIV = enums.GL_EQUIV;
pub const GL_INVERT = enums.GL_INVERT;
pub const GL_OR_REVERSE = enums.GL_OR_REVERSE;
pub const GL_COPY_INVERTED = enums.GL_COPY_INVERTED;
pub const GL_OR_INVERTED = enums.GL_OR_INVERTED;
pub const GL_NAND = enums.GL_NAND;
pub const GL_SET = enums.GL_SET;
pub const GL_EMISSION = enums.GL_EMISSION;
pub const GL_SHININESS = enums.GL_SHININESS;
pub const GL_AMBIENT_AND_DIFFUSE = enums.GL_AMBIENT_AND_DIFFUSE;
pub const GL_MODELVIEW = enums.GL_MODELVIEW;
pub const GL_PROJECTION = enums.GL_PROJECTION;
pub const GL_TEXTURE = enums.GL_TEXTURE;
pub const GL_ALPHA = enums.GL_ALPHA;
pub const GL_RGB = enums.GL_RGB;
pub const GL_RGBA = enums.GL_RGBA;
pub const GL_LUMINANCE = enums.GL_LUMINANCE;
pub const GL_LUMINANCE_ALPHA = enums.GL_LUMINANCE_ALPHA;
pub const GL_UNPACK_ALIGNMENT = enums.GL_UNPACK_ALIGNMENT;
pub const GL_PACK_ALIGNMENT = enums.GL_PACK_ALIGNMENT;
pub const GL_UNSIGNED_SHORT_4_4_4_4 = enums.GL_UNSIGNED_SHORT_4_4_4_4;
pub const GL_UNSIGNED_SHORT_5_5_5_1 = enums.GL_UNSIGNED_SHORT_5_5_5_1;
pub const GL_UNSIGNED_SHORT_5_6_5 = enums.GL_UNSIGNED_SHORT_5_6_5;
pub const GL_FLAT = enums.GL_FLAT;
pub const GL_SMOOTH = enums.GL_SMOOTH;
pub const GL_KEEP = enums.GL_KEEP;
pub const GL_REPLACE = enums.GL_REPLACE;
pub const GL_INCR = enums.GL_INCR;
pub const GL_DECR = enums.GL_DECR;
pub const GL_VENDOR = enums.GL_VENDOR;
pub const GL_RENDERER = enums.GL_RENDERER;
pub const GL_VERSION = enums.GL_VERSION;
pub const GL_EXTENSIONS = enums.GL_EXTENSIONS;
pub const GL_MODULATE = enums.GL_MODULATE;
pub const GL_DECAL = enums.GL_DECAL;
pub const GL_ADD = enums.GL_ADD;
pub const GL_TEXTURE_ENV_MODE = enums.GL_TEXTURE_ENV_MODE;
pub const GL_TEXTURE_ENV_COLOR = enums.GL_TEXTURE_ENV_COLOR;
pub const GL_TEXTURE_ENV = enums.GL_TEXTURE_ENV;
pub const GL_NEAREST = enums.GL_NEAREST;
pub const GL_LINEAR = enums.GL_LINEAR;
pub const GL_NEAREST_MIPMAP_NEAREST = enums.GL_NEAREST_MIPMAP_NEAREST;
pub const GL_LINEAR_MIPMAP_NEAREST = enums.GL_LINEAR_MIPMAP_NEAREST;
pub const GL_NEAREST_MIPMAP_LINEAR = enums.GL_NEAREST_MIPMAP_LINEAR;
pub const GL_LINEAR_MIPMAP_LINEAR = enums.GL_LINEAR_MIPMAP_LINEAR;
pub const GL_TEXTURE_MAG_FILTER = enums.GL_TEXTURE_MAG_FILTER;
pub const GL_TEXTURE_MIN_FILTER = enums.GL_TEXTURE_MIN_FILTER;
pub const GL_TEXTURE_WRAP_S = enums.GL_TEXTURE_WRAP_S;
pub const GL_TEXTURE_WRAP_T = enums.GL_TEXTURE_WRAP_T;
pub const GL_GENERATE_MIPMAP = enums.GL_GENERATE_MIPMAP;
pub const GL_TEXTURE0 = enums.GL_TEXTURE0;
pub const GL_TEXTURE1 = enums.GL_TEXTURE1;
pub const GL_TEXTURE2 = enums.GL_TEXTURE2;
pub const GL_TEXTURE3 = enums.GL_TEXTURE3;
pub const GL_TEXTURE4 = enums.GL_TEXTURE4;
pub const GL_TEXTURE5 = enums.GL_TEXTURE5;
pub const GL_TEXTURE6 = enums.GL_TEXTURE6;
pub const GL_TEXTURE7 = enums.GL_TEXTURE7;
pub const GL_TEXTURE8 = enums.GL_TEXTURE8;
pub const GL_TEXTURE9 = enums.GL_TEXTURE9;
pub const GL_TEXTURE10 = enums.GL_TEXTURE10;
pub const GL_TEXTURE11 = enums.GL_TEXTURE11;
pub const GL_TEXTURE12 = enums.GL_TEXTURE12;
pub const GL_TEXTURE13 = enums.GL_TEXTURE13;
pub const GL_TEXTURE14 = enums.GL_TEXTURE14;
pub const GL_TEXTURE15 = enums.GL_TEXTURE15;
pub const GL_TEXTURE16 = enums.GL_TEXTURE16;
pub const GL_TEXTURE17 = enums.GL_TEXTURE17;
pub const GL_TEXTURE18 = enums.GL_TEXTURE18;
pub const GL_TEXTURE19 = enums.GL_TEXTURE19;
pub const GL_TEXTURE20 = enums.GL_TEXTURE20;
pub const GL_TEXTURE21 = enums.GL_TEXTURE21;
pub const GL_TEXTURE22 = enums.GL_TEXTURE22;
pub const GL_TEXTURE23 = enums.GL_TEXTURE23;
pub const GL_TEXTURE24 = enums.GL_TEXTURE24;
pub const GL_TEXTURE25 = enums.GL_TEXTURE25;
pub const GL_TEXTURE26 = enums.GL_TEXTURE26;
pub const GL_TEXTURE27 = enums.GL_TEXTURE27;
pub const GL_TEXTURE28 = enums.GL_TEXTURE28;
pub const GL_TEXTURE29 = enums.GL_TEXTURE29;
pub const GL_TEXTURE30 = enums.GL_TEXTURE30;
pub const GL_TEXTURE31 = enums.GL_TEXTURE31;
pub const GL_ACTIVE_TEXTURE = enums.GL_ACTIVE_TEXTURE;
pub const GL_CLIENT_ACTIVE_TEXTURE = enums.GL_CLIENT_ACTIVE_TEXTURE;
pub const GL_REPEAT = enums.GL_REPEAT;
pub const GL_CLAMP_TO_EDGE = enums.GL_CLAMP_TO_EDGE;
pub const GL_LIGHT0 = enums.GL_LIGHT0;
pub const GL_LIGHT1 = enums.GL_LIGHT1;
pub const GL_LIGHT2 = enums.GL_LIGHT2;
pub const GL_LIGHT3 = enums.GL_LIGHT3;
pub const GL_LIGHT4 = enums.GL_LIGHT4;
pub const GL_LIGHT5 = enums.GL_LIGHT5;
pub const GL_LIGHT6 = enums.GL_LIGHT6;
pub const GL_LIGHT7 = enums.GL_LIGHT7;
pub const GL_ARRAY_BUFFER = enums.GL_ARRAY_BUFFER;
pub const GL_ELEMENT_ARRAY_BUFFER = enums.GL_ELEMENT_ARRAY_BUFFER;
pub const GL_ARRAY_BUFFER_BINDING = enums.GL_ARRAY_BUFFER_BINDING;
pub const GL_ELEMENT_ARRAY_BUFFER_BINDING = enums.GL_ELEMENT_ARRAY_BUFFER_BINDING;
pub const GL_VERTEX_ARRAY_BUFFER_BINDING = enums.GL_VERTEX_ARRAY_BUFFER_BINDING;
pub const GL_NORMAL_ARRAY_BUFFER_BINDING = enums.GL_NORMAL_ARRAY_BUFFER_BINDING;
pub const GL_COLOR_ARRAY_BUFFER_BINDING = enums.GL_COLOR_ARRAY_BUFFER_BINDING;
pub const GL_TEXTURE_COORD_ARRAY_BUFFER_BINDING = enums.GL_TEXTURE_COORD_ARRAY_BUFFER_BINDING;
pub const GL_STATIC_DRAW = enums.GL_STATIC_DRAW;
pub const GL_DYNAMIC_DRAW = enums.GL_DYNAMIC_DRAW;
pub const GL_BUFFER_SIZE = enums.GL_BUFFER_SIZE;
pub const GL_BUFFER_USAGE = enums.GL_BUFFER_USAGE;
pub const GL_SUBTRACT = enums.GL_SUBTRACT;
pub const GL_COMBINE = enums.GL_COMBINE;
pub const GL_COMBINE_RGB = enums.GL_COMBINE_RGB;
pub const GL_COMBINE_ALPHA = enums.GL_COMBINE_ALPHA;
pub const GL_RGB_SCALE = enums.GL_RGB_SCALE;
pub const GL_ADD_SIGNED = enums.GL_ADD_SIGNED;
pub const GL_INTERPOLATE = enums.GL_INTERPOLATE;
pub const GL_CONSTANT = enums.GL_CONSTANT;
pub const GL_PRIMARY_COLOR = enums.GL_PRIMARY_COLOR;
pub const GL_PREVIOUS = enums.GL_PREVIOUS;
pub const GL_OPERAND0_RGB = enums.GL_OPERAND0_RGB;
pub const GL_OPERAND1_RGB = enums.GL_OPERAND1_RGB;
pub const GL_OPERAND2_RGB = enums.GL_OPERAND2_RGB;
pub const GL_OPERAND0_ALPHA = enums.GL_OPERAND0_ALPHA;
pub const GL_OPERAND1_ALPHA = enums.GL_OPERAND1_ALPHA;
pub const GL_OPERAND2_ALPHA = enums.GL_OPERAND2_ALPHA;
pub const GL_ALPHA_SCALE = enums.GL_ALPHA_SCALE;
pub const GL_SRC0_RGB = enums.GL_SRC0_RGB;
pub const GL_SRC1_RGB = enums.GL_SRC1_RGB;
pub const GL_SRC2_RGB = enums.GL_SRC2_RGB;
pub const GL_SRC0_ALPHA = enums.GL_SRC0_ALPHA;
pub const GL_SRC1_ALPHA = enums.GL_SRC1_ALPHA;
pub const GL_SRC2_ALPHA = enums.GL_SRC2_ALPHA;
pub const GL_DOT3_RGB = enums.GL_DOT3_RGB;
pub const GL_DOT3_RGBA = enums.GL_DOT3_RGBA;
pub const GL_OES_compressed_paletted_texture = enums.GL_OES_compressed_paletted_texture;
pub const GL_PALETTE4_RGB8_OES = enums.GL_PALETTE4_RGB8_OES;
pub const GL_PALETTE4_RGBA8_OES = enums.GL_PALETTE4_RGBA8_OES;
pub const GL_PALETTE4_R5_G6_B5_OES = enums.GL_PALETTE4_R5_G6_B5_OES;
pub const GL_PALETTE4_RGBA4_OES = enums.GL_PALETTE4_RGBA4_OES;
pub const GL_PALETTE4_RGB5_A1_OES = enums.GL_PALETTE4_RGB5_A1_OES;
pub const GL_PALETTE8_RGB8_OES = enums.GL_PALETTE8_RGB8_OES;
pub const GL_PALETTE8_RGBA8_OES = enums.GL_PALETTE8_RGBA8_OES;
pub const GL_PALETTE8_R5_G6_B5_OES = enums.GL_PALETTE8_R5_G6_B5_OES;
pub const GL_PALETTE8_RGBA4_OES = enums.GL_PALETTE8_RGBA4_OES;
pub const GL_PALETTE8_RGB5_A1_OES = enums.GL_PALETTE8_RGB5_A1_OES;
pub const GL_OES_point_size_array = enums.GL_OES_point_size_array;
pub const GL_POINT_SIZE_ARRAY_OES = enums.GL_POINT_SIZE_ARRAY_OES;
pub const GL_POINT_SIZE_ARRAY_TYPE_OES = enums.GL_POINT_SIZE_ARRAY_TYPE_OES;
pub const GL_POINT_SIZE_ARRAY_STRIDE_OES = enums.GL_POINT_SIZE_ARRAY_STRIDE_OES;
pub const GL_POINT_SIZE_ARRAY_POINTER_OES = enums.GL_POINT_SIZE_ARRAY_POINTER_OES;
pub const GL_POINT_SIZE_ARRAY_BUFFER_BINDING_OES = enums.GL_POINT_SIZE_ARRAY_BUFFER_BINDING_OES;
pub const GL_OES_point_sprite = enums.GL_OES_point_sprite;
pub const GL_POINT_SPRITE_OES = enums.GL_POINT_SPRITE_OES;
pub const GL_COORD_REPLACE_OES = enums.GL_COORD_REPLACE_OES;
pub const GL_OES_read_format = enums.GL_OES_read_format;
pub const GL_IMPLEMENTATION_COLOR_READ_TYPE_OES = enums.GL_IMPLEMENTATION_COLOR_READ_TYPE_OES;
pub const GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES = enums.GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES;

pub const Context = state.Context;
pub const Mat4 = matrix.Mat4;

/// Where a context delivers finished frames — the window surface it draws into.
/// Re-exported so that an application needs `gles` and nothing else.
pub const Dst = idraw.Dst;

/// The largest frame the device will accept, in pixels — `beginFrame` rejects anything
/// bigger. Re-exported so an application clamps its content to a size gles will draw
/// without reaching past gles into the draw seam.
pub const MAX_W = idraw.MAX_W;
pub const MAX_H = idraw.MAX_H;

/// Take a GL context for a window, or null when there is no GPU to draw with, the
/// context pool is full, or the device cannot host a conforming implementation.
///
/// This is the ONLY way to reach the hardware, and that is deliberate. An application
/// imports `gles` and nothing else: the device seam (idraw) is ours, not theirs, so
/// there is no second path to the silicon that could bypass the state machine, skip its
/// validation, or leave its state disagreeing with what was actually drawn. The layering
/// gate enforces it — `ui/` importing `idraw` fails the build.
///
/// Re-read rather than cached: the GPU driver clears the device before tearing the
/// engine down, so a context taken while it was up must not outlive it.
pub fn createContext(alloc: std.mem.Allocator, dst: Dst) ?Context {
    const dev = idraw.device orelse return null;
    const target = dev.acquire(dst) orelse return null;
    const g = Context.init(alloc, dev, target) orelse {
        dev.release(target);
        return null;
    };
    return g;
}

/// Give the window's context back: everything it owns is released, and the frame in
/// flight, if any, is abandoned.
pub fn destroyContext(g: *Context) void {
    g.deinit();
    g.dev.release(g.target);
}

/// Whether a finished frame is written straight into the window's own surface — so the
/// window must report the drawn region as damage for the compositor to upload — or lands
/// in a private GPU mirror the compositor samples in place, needing no upload. The
/// software backend does the former, the 4090 the latter; a window asks so it can deliver
/// correctly either way without naming the backend. See idraw.IDraw.delivers_in_place.
pub fn deliversInPlace(g: *Context) bool {
    return g.dev.delivers_in_place;
}

/// Whether the published draw device is GPU-accelerated (the RTX 4090 GR backend, which
/// leaves frames in a VRAM mirror or the scanout ring) rather than the software
/// rasteriser (which delivers pixels into the target surface in place). The desktop keys
/// its DELIVERY on this — the hardware device's frames flip onto scanout, the software
/// device's land in the back surface — without either side naming the backend.
pub fn hasGpuDevice() bool {
    const d = idraw.device orelse return false;
    return !d.delivers_in_place;
}

/// Whether the published draw device is the software rasteriser — the other side
/// of `hasGpuDevice`, distinct from "no device at all". The compositor asks so it
/// can point a context at the scanout the software backend delivers into,
/// without naming the backend or the seam beneath this layer.
pub fn hasSoftwareDevice() bool {
    const d = idraw.device orelse return false;
    return d.delivers_in_place;
}

// ── token mapping ────────────────────────────────────────────────────────────
//
// A GLenum is only allowed to exist at the boundary. Each mapper below turns one into a
// real Zig enum or reports that it is not a member of the set this argument accepts —
// which is precisely GL_INVALID_ENUM. Past this point the compiler does the checking.

fn mapCompareFunc(v: GLenum) ?idraw.CompareFunc {
    return switch (v) {
        enums.GL_NEVER => .never,
        enums.GL_LESS => .less,
        enums.GL_EQUAL => .equal,
        enums.GL_LEQUAL => .lequal,
        enums.GL_GREATER => .greater,
        enums.GL_NOTEQUAL => .notequal,
        enums.GL_GEQUAL => .gequal,
        enums.GL_ALWAYS => .always,
        else => null,
    };
}

fn mapStencilOp(v: GLenum) ?idraw.StencilOp {
    return switch (v) {
        enums.GL_KEEP => .keep,
        enums.GL_ZERO => .zero,
        enums.GL_REPLACE => .replace,
        enums.GL_INCR => .incr,
        enums.GL_DECR => .decr,
        enums.GL_INVERT => .invert,
        else => null,
    };
}

/// Source blend factors. The standard's set is NOT symmetric with the destination's: a
/// source factor may not read SRC_COLOR (it would be reading itself).
fn srcBlendFactor(v: GLenum) ?idraw.BlendFactor {
    return switch (v) {
        enums.GL_ZERO => .zero,
        enums.GL_ONE => .one,
        enums.GL_DST_COLOR => .dst_color,
        enums.GL_ONE_MINUS_DST_COLOR => .one_minus_dst_color,
        enums.GL_SRC_ALPHA => .src_alpha,
        enums.GL_ONE_MINUS_SRC_ALPHA => .one_minus_src_alpha,
        enums.GL_DST_ALPHA => .dst_alpha,
        enums.GL_ONE_MINUS_DST_ALPHA => .one_minus_dst_alpha,
        enums.GL_SRC_ALPHA_SATURATE => .src_alpha_saturate,
        else => null,
    };
}

/// Destination blend factors: may not read DST_COLOR, and has no SRC_ALPHA_SATURATE.
fn dstBlendFactor(v: GLenum) ?idraw.BlendFactor {
    return switch (v) {
        enums.GL_ZERO => .zero,
        enums.GL_ONE => .one,
        enums.GL_SRC_COLOR => .src_color,
        enums.GL_ONE_MINUS_SRC_COLOR => .one_minus_src_color,
        enums.GL_SRC_ALPHA => .src_alpha,
        enums.GL_ONE_MINUS_SRC_ALPHA => .one_minus_src_alpha,
        enums.GL_DST_ALPHA => .dst_alpha,
        enums.GL_ONE_MINUS_DST_ALPHA => .one_minus_dst_alpha,
        else => null,
    };
}

fn mapLogicOp(v: GLenum) ?idraw.LogicOp {
    return switch (v) {
        enums.GL_CLEAR => .clear,
        enums.GL_SET => .set,
        enums.GL_COPY => .copy,
        enums.GL_COPY_INVERTED => .copy_inverted,
        enums.GL_NOOP => .noop,
        enums.GL_INVERT => .invert,
        enums.GL_AND => .@"and",
        enums.GL_NAND => .nand,
        enums.GL_OR => .@"or",
        enums.GL_NOR => .nor,
        enums.GL_XOR => .xor,
        enums.GL_EQUIV => .equiv,
        enums.GL_AND_REVERSE => .and_reverse,
        enums.GL_AND_INVERTED => .and_inverted,
        enums.GL_OR_REVERSE => .or_reverse,
        enums.GL_OR_INVERTED => .or_inverted,
        else => null,
    };
}

fn mapHint(v: GLenum) ?state.Context.Hint {
    return switch (v) {
        enums.GL_FASTEST => .fastest,
        enums.GL_NICEST => .nicest,
        enums.GL_DONT_CARE => .dont_care,
        else => null,
    };
}

fn clampf(v: GLfloat) GLfloat {
    return if (v < 0) 0 else if (v > 1) 1 else v;
}

/// A colour component from an unsigned byte: 0..255 maps onto 0.0..1.0 (§2.13).
fn ubyteToFloat(v: u8) GLfloat {
    return @as(GLfloat, @floatFromInt(v)) / 255.0;
}

// ── §2.7 current vertex state ────────────────────────────────────────────────

pub fn color4f(g: *Context, r: GLfloat, gr: GLfloat, b: GLfloat, a: GLfloat) void {
    g.color = .{ r, gr, b, a };
}

pub fn color4x(g: *Context, r: GLfixed, gr: GLfixed, b: GLfixed, a: GLfixed) void {
    color4f(g, fixed.toFloat(r), fixed.toFloat(gr), fixed.toFloat(b), fixed.toFloat(a));
}

pub fn color4ub(g: *Context, r: u8, gr: u8, b: u8, a: u8) void {
    color4f(g, ubyteToFloat(r), ubyteToFloat(gr), ubyteToFloat(b), ubyteToFloat(a));
}

pub fn normal3f(g: *Context, nx: GLfloat, ny: GLfloat, nz: GLfloat) void {
    g.normal = .{ nx, ny, nz };
}

pub fn normal3x(g: *Context, nx: GLfixed, ny: GLfixed, nz: GLfixed) void {
    normal3f(g, fixed.toFloat(nx), fixed.toFloat(ny), fixed.toFloat(nz));
}

pub fn multiTexCoord4f(g: *Context, target: GLenum, s: GLfloat, t: GLfloat, r: GLfloat, q: GLfloat) void {
    const u = textureUnitIndex(g, target) orelse return;
    g.texcoord[u] = .{ s, t, r, q };
}

pub fn multiTexCoord4x(g: *Context, target: GLenum, s: GLfixed, t: GLfixed, r: GLfixed, q: GLfixed) void {
    multiTexCoord4f(g, target, fixed.toFloat(s), fixed.toFloat(t), fixed.toFloat(r), fixed.toFloat(q));
}

/// GL_TEXTUREi -> a unit index, or INVALID_ENUM. The standard numbers units from the
/// token GL_TEXTURE0, and a unit past what we expose is an error rather than a clamp.
fn textureUnitIndex(g: *Context, target: GLenum) ?u32 {
    if (target < enums.GL_TEXTURE0) {
        g.recordError(.invalid_enum);
        return null;
    }
    const u = target - enums.GL_TEXTURE0;
    if (u >= limits.MAX_TEXTURE_UNITS) {
        g.recordError(.invalid_enum);
        return null;
    }
    return u;
}

pub fn activeTexture(g: *Context, texture: GLenum) void {
    const u = textureUnitIndex(g, texture) orelse return;
    g.active_texture = u;
}

pub fn clientActiveTexture(g: *Context, texture: GLenum) void {
    const u = textureUnitIndex(g, texture) orelse return;
    g.client_active_texture = u;
}

pub fn pointSize(g: *Context, size: GLfloat) void {
    if (size <= 0) return g.recordError(.invalid_value);
    g.point_size = size;
}

pub fn pointSizex(g: *Context, size: GLfixed) void {
    pointSize(g, fixed.toFloat(size));
}

// ── §2.10 coordinate transformation ──────────────────────────────────────────

pub fn matrixMode(g: *Context, mode: GLenum) void {
    g.matrix_mode = switch (mode) {
        enums.GL_MODELVIEW => .modelview,
        enums.GL_PROJECTION => .projection,
        enums.GL_TEXTURE => .texture,
        else => return g.recordError(.invalid_enum),
    };
}

/// Apply `f` to whichever stack is current. The three stacks have different depths, so
/// they are different types; this is where that is resolved, once.
fn onCurrentStack(g: *Context, comptime f: anytype, args: anytype) void {
    switch (g.matrix_mode) {
        .modelview => @call(.auto, f, .{&g.modelview} ++ args),
        .projection => @call(.auto, f, .{&g.projection} ++ args),
        .texture => @call(.auto, f, .{&g.texture_matrix[g.active_texture]} ++ args),
    }
}

fn stackSet(s: anytype, m: Mat4) void {
    s.set(m);
}
fn stackMul(s: anytype, m: Mat4) void {
    s.postMul(m);
}

pub fn loadIdentity(g: *Context) void {
    onCurrentStack(g, stackSet, .{matrix.IDENTITY});
}

pub fn loadMatrixf(g: *Context, m: [*]const GLfloat) void {
    var v: Mat4 = undefined;
    @memcpy(&v, m[0..16]);
    onCurrentStack(g, stackSet, .{v});
}

pub fn loadMatrixx(g: *Context, m: [*]const GLfixed) void {
    var v: Mat4 = undefined;
    for (&v, 0..) |*x, i| x.* = fixed.toFloat(m[i]);
    onCurrentStack(g, stackSet, .{v});
}

pub fn multMatrixf(g: *Context, m: [*]const GLfloat) void {
    var v: Mat4 = undefined;
    @memcpy(&v, m[0..16]);
    onCurrentStack(g, stackMul, .{v});
}

pub fn multMatrixx(g: *Context, m: [*]const GLfixed) void {
    var v: Mat4 = undefined;
    for (&v, 0..) |*x, i| x.* = fixed.toFloat(m[i]);
    onCurrentStack(g, stackMul, .{v});
}

pub fn translatef(g: *Context, x: GLfloat, y: GLfloat, z: GLfloat) void {
    onCurrentStack(g, stackMul, .{matrix.translation(x, y, z)});
}

pub fn translatex(g: *Context, x: GLfixed, y: GLfixed, z: GLfixed) void {
    translatef(g, fixed.toFloat(x), fixed.toFloat(y), fixed.toFloat(z));
}

pub fn scalef(g: *Context, x: GLfloat, y: GLfloat, z: GLfloat) void {
    onCurrentStack(g, stackMul, .{matrix.scaling(x, y, z)});
}

pub fn scalex(g: *Context, x: GLfixed, y: GLfixed, z: GLfixed) void {
    scalef(g, fixed.toFloat(x), fixed.toFloat(y), fixed.toFloat(z));
}

pub fn rotatef(g: *Context, angle: GLfloat, x: GLfloat, y: GLfloat, z: GLfloat) void {
    onCurrentStack(g, stackMul, .{matrix.rotation(angle, x, y, z)});
}

pub fn rotatex(g: *Context, angle: GLfixed, x: GLfixed, y: GLfixed, z: GLfixed) void {
    rotatef(g, fixed.toFloat(angle), fixed.toFloat(x), fixed.toFloat(y), fixed.toFloat(z));
}

pub fn frustumf(g: *Context, l: GLfloat, r: GLfloat, b: GLfloat, t: GLfloat, n: GLfloat, f: GLfloat) void {
    const m = matrix.frustum(l, r, b, t, n, f) orelse return g.recordError(.invalid_value);
    onCurrentStack(g, stackMul, .{m});
}

pub fn frustumx(g: *Context, l: GLfixed, r: GLfixed, b: GLfixed, t: GLfixed, n: GLfixed, f: GLfixed) void {
    frustumf(g, fixed.toFloat(l), fixed.toFloat(r), fixed.toFloat(b), fixed.toFloat(t), fixed.toFloat(n), fixed.toFloat(f));
}

pub fn orthof(g: *Context, l: GLfloat, r: GLfloat, b: GLfloat, t: GLfloat, n: GLfloat, f: GLfloat) void {
    const m = matrix.ortho(l, r, b, t, n, f) orelse return g.recordError(.invalid_value);
    onCurrentStack(g, stackMul, .{m});
}

pub fn orthox(g: *Context, l: GLfixed, r: GLfixed, b: GLfixed, t: GLfixed, n: GLfixed, f: GLfixed) void {
    orthof(g, fixed.toFloat(l), fixed.toFloat(r), fixed.toFloat(b), fixed.toFloat(t), fixed.toFloat(n), fixed.toFloat(f));
}

fn stackPush(s: anytype, g: *Context) void {
    if (s.push()) |e| g.recordError(e);
}
fn stackPop(s: anytype, g: *Context) void {
    if (s.pop()) |e| g.recordError(e);
}

pub fn pushMatrix(g: *Context) void {
    switch (g.matrix_mode) {
        .modelview => stackPush(&g.modelview, g),
        .projection => stackPush(&g.projection, g),
        .texture => stackPush(&g.texture_matrix[g.active_texture], g),
    }
}

pub fn popMatrix(g: *Context) void {
    switch (g.matrix_mode) {
        .modelview => stackPop(&g.modelview, g),
        .projection => stackPop(&g.projection, g),
        .texture => stackPop(&g.texture_matrix[g.active_texture], g),
    }
}

pub fn viewport(g: *Context, x: GLint, y: GLint, w: GLsizei, h: GLsizei) void {
    if (w < 0 or h < 0) return g.recordError(.invalid_value);
    g.viewport = .{ .x = x, .y = y, .w = @intCast(w), .h = @intCast(h) };
}

pub fn depthRangef(g: *Context, n: GLclampf, f: GLclampf) void {
    g.depth_range = .{ clampf(n), clampf(f) };
}

pub fn depthRangex(g: *Context, n: GLclampx, f: GLclampx) void {
    depthRangef(g, fixed.clampToFloat(n), fixed.clampToFloat(f));
}

fn clipPlaneIndex(g: *Context, p: GLenum) ?u32 {
    if (p < enums.GL_CLIP_PLANE0) {
        g.recordError(.invalid_enum);
        return null;
    }
    const i = p - enums.GL_CLIP_PLANE0;
    if (i >= limits.MAX_CLIP_PLANES) {
        g.recordError(.invalid_enum);
        return null;
    }
    return i;
}

pub fn clipPlanef(g: *Context, p: GLenum, eqn: [*]const GLfloat) void {
    const i = clipPlaneIndex(g, p) orelse return;
    // The standard transforms the plane by the inverse of the modelview matrix AT THIS
    // MOMENT, and stores the result — a later modelview change does not move the plane.
    g.clip_plane[i] = .{ eqn[0], eqn[1], eqn[2], eqn[3] };
}

pub fn clipPlanex(g: *Context, p: GLenum, eqn: [*]const GLfixed) void {
    const v = [4]GLfloat{ fixed.toFloat(eqn[0]), fixed.toFloat(eqn[1]), fixed.toFloat(eqn[2]), fixed.toFloat(eqn[3]) };
    clipPlanef(g, p, &v);
}

pub fn getClipPlanef(g: *Context, p: GLenum, eqn: [*]GLfloat) void {
    const i = clipPlaneIndex(g, p) orelse return;
    for (g.clip_plane[i], 0..) |v, k| eqn[k] = v;
}

pub fn getClipPlanex(g: *Context, p: GLenum, eqn: [*]GLfixed) void {
    const i = clipPlaneIndex(g, p) orelse return;
    for (g.clip_plane[i], 0..) |v, k| eqn[k] = fixed.fromFloat(v);
}

// ── §2.12 lighting ───────────────────────────────────────────────────────────

fn lightIndex(g: *Context, l: GLenum) ?u32 {
    if (l < enums.GL_LIGHT0) {
        g.recordError(.invalid_enum);
        return null;
    }
    const i = l - enums.GL_LIGHT0;
    if (i >= limits.MAX_LIGHTS) {
        g.recordError(.invalid_enum);
        return null;
    }
    return i;
}

pub fn lightf(g: *Context, light: GLenum, pname: GLenum, param: GLfloat) void {
    const v = [4]GLfloat{ param, 0, 0, 0 };
    lightfv(g, light, pname, &v);
}

pub fn lightx(g: *Context, light: GLenum, pname: GLenum, param: GLfixed) void {
    lightf(g, light, pname, fixed.toFloat(param));
}

pub fn lightfv(g: *Context, light: GLenum, pname: GLenum, params: [*]const GLfloat) void {
    const i = lightIndex(g, light) orelse return;
    const l = &g.lights[i];
    switch (pname) {
        enums.GL_AMBIENT => l.ambient = .{ params[0], params[1], params[2], params[3] },
        enums.GL_DIFFUSE => l.diffuse = .{ params[0], params[1], params[2], params[3] },
        enums.GL_SPECULAR => l.specular = .{ params[0], params[1], params[2], params[3] },
        enums.GL_POSITION => l.position = .{ params[0], params[1], params[2], params[3] },
        enums.GL_SPOT_DIRECTION => l.spot_direction = .{ params[0], params[1], params[2] },
        enums.GL_SPOT_EXPONENT => {
            if (params[0] < 0 or params[0] > 128) return g.recordError(.invalid_value);
            l.spot_exponent = params[0];
        },
        enums.GL_SPOT_CUTOFF => {
            // 180 means "not a spotlight" and is the only legal value above 90.
            if (!((params[0] >= 0 and params[0] <= 90) or params[0] == 180))
                return g.recordError(.invalid_value);
            l.spot_cutoff = params[0];
        },
        enums.GL_CONSTANT_ATTENUATION => {
            if (params[0] < 0) return g.recordError(.invalid_value);
            l.constant_attenuation = params[0];
        },
        enums.GL_LINEAR_ATTENUATION => {
            if (params[0] < 0) return g.recordError(.invalid_value);
            l.linear_attenuation = params[0];
        },
        enums.GL_QUADRATIC_ATTENUATION => {
            if (params[0] < 0) return g.recordError(.invalid_value);
            l.quadratic_attenuation = params[0];
        },
        else => g.recordError(.invalid_enum),
    }
}

pub fn lightxv(g: *Context, light: GLenum, pname: GLenum, params: [*]const GLfixed) void {
    const v = [4]GLfloat{ fixed.toFloat(params[0]), fixed.toFloat(params[1]), fixed.toFloat(params[2]), fixed.toFloat(params[3]) };
    lightfv(g, light, pname, &v);
}

pub fn getLightfv(g: *Context, light: GLenum, pname: GLenum, params: [*]GLfloat) void {
    const i = lightIndex(g, light) orelse return;
    const l = g.lights[i];
    switch (pname) {
        enums.GL_AMBIENT => copy4(params, l.ambient),
        enums.GL_DIFFUSE => copy4(params, l.diffuse),
        enums.GL_SPECULAR => copy4(params, l.specular),
        enums.GL_POSITION => copy4(params, l.position),
        enums.GL_SPOT_DIRECTION => for (l.spot_direction, 0..) |v, k| {
            params[k] = v;
        },
        enums.GL_SPOT_EXPONENT => params[0] = l.spot_exponent,
        enums.GL_SPOT_CUTOFF => params[0] = l.spot_cutoff,
        enums.GL_CONSTANT_ATTENUATION => params[0] = l.constant_attenuation,
        enums.GL_LINEAR_ATTENUATION => params[0] = l.linear_attenuation,
        enums.GL_QUADRATIC_ATTENUATION => params[0] = l.quadratic_attenuation,
        else => g.recordError(.invalid_enum),
    }
}

pub fn getLightxv(g: *Context, light: GLenum, pname: GLenum, params: [*]GLfixed) void {
    var tmp: [4]GLfloat = .{ 0, 0, 0, 0 };
    getLightfv(g, light, pname, &tmp);
    for (tmp, 0..) |v, k| params[k] = fixed.fromFloat(v);
}

fn copy4(dst: [*]GLfloat, src: [4]GLfloat) void {
    for (src, 0..) |v, k| dst[k] = v;
}

pub fn lightModelf(g: *Context, pname: GLenum, param: GLfloat) void {
    const v = [4]GLfloat{ param, 0, 0, 0 };
    lightModelfv(g, pname, &v);
}

pub fn lightModelx(g: *Context, pname: GLenum, param: GLfixed) void {
    lightModelf(g, pname, fixed.toFloat(param));
}

pub fn lightModelfv(g: *Context, pname: GLenum, params: [*]const GLfloat) void {
    switch (pname) {
        enums.GL_LIGHT_MODEL_AMBIENT => g.light_model_ambient = .{ params[0], params[1], params[2], params[3] },
        enums.GL_LIGHT_MODEL_TWO_SIDE => g.light_model_two_side = params[0] != 0,
        else => g.recordError(.invalid_enum),
    }
}

pub fn lightModelxv(g: *Context, pname: GLenum, params: [*]const GLfixed) void {
    const v = [4]GLfloat{ fixed.toFloat(params[0]), fixed.toFloat(params[1]), fixed.toFloat(params[2]), fixed.toFloat(params[3]) };
    lightModelfv(g, pname, &v);
}

/// Which material face a command addresses. ES 1.1 accepts only FRONT_AND_BACK — the
/// desktop's FRONT and BACK alone are gone — so a program cannot give the two faces
/// different materials, only different lighting via two-sided mode.
fn materialFaceOk(g: *Context, face: GLenum) bool {
    if (face != enums.GL_FRONT_AND_BACK) {
        g.recordError(.invalid_enum);
        return false;
    }
    return true;
}

pub fn materialf(g: *Context, face: GLenum, pname: GLenum, param: GLfloat) void {
    const v = [4]GLfloat{ param, 0, 0, 0 };
    materialfv(g, face, pname, &v);
}

pub fn materialx(g: *Context, face: GLenum, pname: GLenum, param: GLfixed) void {
    materialf(g, face, pname, fixed.toFloat(param));
}

pub fn materialfv(g: *Context, face: GLenum, pname: GLenum, params: [*]const GLfloat) void {
    if (!materialFaceOk(g, face)) return;
    const v4 = [4]GLfloat{ params[0], params[1], params[2], params[3] };
    switch (pname) {
        enums.GL_AMBIENT => {
            g.material_front.ambient = v4;
            g.material_back.ambient = v4;
        },
        enums.GL_DIFFUSE => {
            g.material_front.diffuse = v4;
            g.material_back.diffuse = v4;
        },
        enums.GL_AMBIENT_AND_DIFFUSE => {
            g.material_front.ambient = v4;
            g.material_front.diffuse = v4;
            g.material_back.ambient = v4;
            g.material_back.diffuse = v4;
        },
        enums.GL_SPECULAR => {
            g.material_front.specular = v4;
            g.material_back.specular = v4;
        },
        enums.GL_EMISSION => {
            g.material_front.emission = v4;
            g.material_back.emission = v4;
        },
        enums.GL_SHININESS => {
            if (params[0] < 0 or params[0] > 128) return g.recordError(.invalid_value);
            g.material_front.shininess = params[0];
            g.material_back.shininess = params[0];
        },
        else => g.recordError(.invalid_enum),
    }
}

pub fn materialxv(g: *Context, face: GLenum, pname: GLenum, params: [*]const GLfixed) void {
    const v = [4]GLfloat{ fixed.toFloat(params[0]), fixed.toFloat(params[1]), fixed.toFloat(params[2]), fixed.toFloat(params[3]) };
    materialfv(g, face, pname, &v);
}

pub fn getMaterialfv(g: *Context, face: GLenum, pname: GLenum, params: [*]GLfloat) void {
    if (!materialFaceOk(g, face)) return;
    const m = g.material_front;
    switch (pname) {
        enums.GL_AMBIENT => copy4(params, m.ambient),
        enums.GL_DIFFUSE => copy4(params, m.diffuse),
        enums.GL_SPECULAR => copy4(params, m.specular),
        enums.GL_EMISSION => copy4(params, m.emission),
        enums.GL_SHININESS => params[0] = m.shininess,
        else => g.recordError(.invalid_enum),
    }
}

pub fn getMaterialxv(g: *Context, face: GLenum, pname: GLenum, params: [*]GLfixed) void {
    var tmp: [4]GLfloat = .{ 0, 0, 0, 0 };
    getMaterialfv(g, face, pname, &tmp);
    for (tmp, 0..) |v, k| params[k] = fixed.fromFloat(v);
}

pub fn shadeModel(g: *Context, mode: GLenum) void {
    g.shade_model = switch (mode) {
        enums.GL_FLAT => .flat,
        enums.GL_SMOOTH => .smooth,
        else => return g.recordError(.invalid_enum),
    };
}

// ── §3 rasterization ─────────────────────────────────────────────────────────

pub fn lineWidth(g: *Context, width: GLfloat) void {
    if (width <= 0) return g.recordError(.invalid_value);
    g.line_width = width;
}

pub fn lineWidthx(g: *Context, width: GLfixed) void {
    lineWidth(g, fixed.toFloat(width));
}

pub fn cullFace(g: *Context, mode: GLenum) void {
    g.cull_face = switch (mode) {
        enums.GL_FRONT => .front,
        enums.GL_BACK => .back,
        enums.GL_FRONT_AND_BACK => .front_and_back,
        else => return g.recordError(.invalid_enum),
    };
}

pub fn frontFace(g: *Context, mode: GLenum) void {
    g.front_face = switch (mode) {
        enums.GL_CW => .cw,
        enums.GL_CCW => .ccw,
        else => return g.recordError(.invalid_enum),
    };
}

pub fn polygonOffset(g: *Context, factor: GLfloat, units: GLfloat) void {
    g.polygon_offset_factor = factor;
    g.polygon_offset_units = units;
}

pub fn polygonOffsetx(g: *Context, factor: GLfixed, units: GLfixed) void {
    polygonOffset(g, fixed.toFloat(factor), fixed.toFloat(units));
}

pub fn pointParameterf(g: *Context, pname: GLenum, param: GLfloat) void {
    const v = [3]GLfloat{ param, 0, 0 };
    pointParameterfv(g, pname, &v);
}

pub fn pointParameterx(g: *Context, pname: GLenum, param: GLfixed) void {
    pointParameterf(g, pname, fixed.toFloat(param));
}

pub fn pointParameterfv(g: *Context, pname: GLenum, params: [*]const GLfloat) void {
    switch (pname) {
        enums.GL_POINT_SIZE_MIN => {
            if (params[0] < 0) return g.recordError(.invalid_value);
            g.point_size_min = params[0];
        },
        enums.GL_POINT_SIZE_MAX => {
            if (params[0] < 0) return g.recordError(.invalid_value);
            g.point_size_max = params[0];
        },
        enums.GL_POINT_FADE_THRESHOLD_SIZE => {
            if (params[0] < 0) return g.recordError(.invalid_value);
            g.point_fade_threshold = params[0];
        },
        enums.GL_POINT_DISTANCE_ATTENUATION => g.point_distance_attenuation = .{ params[0], params[1], params[2] },
        else => g.recordError(.invalid_enum),
    }
}

pub fn pointParameterxv(g: *Context, pname: GLenum, params: [*]const GLfixed) void {
    const v = [3]GLfloat{ fixed.toFloat(params[0]), fixed.toFloat(params[1]), fixed.toFloat(params[2]) };
    pointParameterfv(g, pname, &v);
}

// ── §4 per-fragment operations ───────────────────────────────────────────────

pub fn scissor(g: *Context, x: GLint, y: GLint, w: GLsizei, h: GLsizei) void {
    if (w < 0 or h < 0) return g.recordError(.invalid_value);
    g.scissor_box = .{ .x = x, .y = y, .w = @intCast(w), .h = @intCast(h) };
}

pub fn alphaFunc(g: *Context, func: GLenum, ref: GLclampf) void {
    g.alpha_func = mapCompareFunc(func) orelse return g.recordError(.invalid_enum);
    g.alpha_ref = clampf(ref);
}

pub fn alphaFuncx(g: *Context, func: GLenum, ref: GLclampx) void {
    alphaFunc(g, func, fixed.clampToFloat(ref));
}

pub fn depthFunc(g: *Context, func: GLenum) void {
    g.depth_func = mapCompareFunc(func) orelse return g.recordError(.invalid_enum);
}

pub fn depthMask(g: *Context, flag: GLboolean) void {
    g.depth_writemask = flag != 0;
}

pub fn colorMask(g: *Context, r: GLboolean, gr: GLboolean, b: GLboolean, a: GLboolean) void {
    g.color_writemask = .{ r != 0, gr != 0, b != 0, a != 0 };
}

pub fn stencilFunc(g: *Context, func: GLenum, ref: GLint, mask: GLuint) void {
    g.stencil_func = mapCompareFunc(func) orelse return g.recordError(.invalid_enum);
    g.stencil_ref = ref;
    g.stencil_value_mask = mask;
}

pub fn stencilMask(g: *Context, mask: GLuint) void {
    g.stencil_writemask = mask;
}

pub fn stencilOp(g: *Context, fail: GLenum, zfail: GLenum, zpass: GLenum) void {
    const f = mapStencilOp(fail) orelse return g.recordError(.invalid_enum);
    const zf = mapStencilOp(zfail) orelse return g.recordError(.invalid_enum);
    const zp = mapStencilOp(zpass) orelse return g.recordError(.invalid_enum);
    g.stencil_fail = f;
    g.stencil_zfail = zf;
    g.stencil_zpass = zp;
}

pub fn blendFunc(g: *Context, sfactor: GLenum, dfactor: GLenum) void {
    const s = srcBlendFactor(sfactor) orelse return g.recordError(.invalid_enum);
    const d = dstBlendFactor(dfactor) orelse return g.recordError(.invalid_enum);
    g.blend_src = s;
    g.blend_dst = d;
}

pub fn logicOp(g: *Context, opcode: GLenum) void {
    g.logic_op = mapLogicOp(opcode) orelse return g.recordError(.invalid_enum);
}

pub fn sampleCoverage(g: *Context, value: GLclampf, invert: GLboolean) void {
    g.sample_coverage_value = clampf(value);
    g.sample_coverage_invert = invert != 0;
}

pub fn sampleCoveragex(g: *Context, value: GLclampx, invert: GLboolean) void {
    sampleCoverage(g, fixed.clampToFloat(value), invert);
}

// ── §4.2 whole-framebuffer operations ────────────────────────────────────────

pub fn clearColor(g: *Context, r: GLclampf, gr: GLclampf, b: GLclampf, a: GLclampf) void {
    g.clear_color = .{ clampf(r), clampf(gr), clampf(b), clampf(a) };
}

pub fn clearColorx(g: *Context, r: GLclampx, gr: GLclampx, b: GLclampx, a: GLclampx) void {
    g.clear_color = .{ fixed.clampToFloat(r), fixed.clampToFloat(gr), fixed.clampToFloat(b), fixed.clampToFloat(a) };
}

pub fn clearDepthf(g: *Context, depth: GLclampf) void {
    g.clear_depth = clampf(depth);
}

pub fn clearDepthx(g: *Context, depth: GLclampx) void {
    g.clear_depth = fixed.clampToFloat(depth);
}

pub fn clearStencil(g: *Context, s: GLint) void {
    g.clear_stencil = s;
}

pub fn clear(g: *Context, mask: GLbitfield) void {
    const known = enums.GL_COLOR_BUFFER_BIT | enums.GL_DEPTH_BUFFER_BIT | enums.GL_STENCIL_BUFFER_BIT;
    if (mask & ~known != 0) return g.recordError(.invalid_value);
    const m = idraw.ClearMask{
        .color = mask & enums.GL_COLOR_BUFFER_BIT != 0,
        .depth = mask & enums.GL_DEPTH_BUFFER_BIT != 0,
        .stencil = mask & enums.GL_STENCIL_BUFFER_BIT != 0,
    };
    // The scissor box arrives in GL's convention and the device wants the
    // framebuffer's, exactly as it does for a draw — so it flips through the same
    // function a draw uses. It used not to, and a scissored clear landed in the wrong
    // half of the window while every draw around it was right.
    const sc: ?idraw.Rect = if (g.caps.scissor_test)
        @import("pipeline.zig").flipRect(g.scissor_box, g.frame_h)
    else
        null;
    g.target.clear(m, g.clear_color, g.clear_depth, @bitCast(g.clear_stencil), sc) catch {
        g.recordError(.out_of_memory);
    };
}

// ── §5 special functions ─────────────────────────────────────────────────────

pub fn hint(g: *Context, target: GLenum, mode: GLenum) void {
    const h = mapHint(mode) orelse return g.recordError(.invalid_enum);
    switch (target) {
        enums.GL_PERSPECTIVE_CORRECTION_HINT => g.perspective_correction_hint = h,
        enums.GL_POINT_SMOOTH_HINT => g.point_smooth_hint = h,
        enums.GL_LINE_SMOOTH_HINT => g.line_smooth_hint = h,
        enums.GL_FOG_HINT => g.fog_hint = h,
        enums.GL_GENERATE_MIPMAP_HINT => g.generate_mipmap_hint = h,
        else => g.recordError(.invalid_enum),
    }
}

/// glFlush: ensure issued commands will complete in finite time. Our commands are
/// already recorded into a push buffer that the GPU is consuming, so there is nothing
/// to force.
pub fn flush(g: *Context) void {
    _ = g;
}

/// Bound on the glFinish poll loop. gles is pure over the idraw seam (no clock
/// import), so the budget is a spin count, not wall time: at ≥ ~1 ns per
/// frameReady vtable poll this is well past any legitimate frame (seconds),
/// and only a wedged device ever reaches it.
const FINISH_POLL_CAP: u64 = 1_000_000_000;

/// glFinish: block until issued commands are done. The one place the specification
/// demands a wait. On a wedged device the wait gives up at FINISH_POLL_CAP and
/// records GL_OUT_OF_MEMORY (the one ES 1.1 error after which GL results are
/// allowed to be undefined) rather than spinning the core forever.
pub fn finish(g: *Context) void {
    var polls: u64 = 0;
    while (!g.target.frameReady()) {
        polls += 1;
        if (polls >= FINISH_POLL_CAP) {
            g.err.record(.out_of_memory);
            return;
        }
    }
}

pub fn getError(g: *Context) GLenum {
    return g.err.get();
}

pub fn getString(g: *Context, name: GLenum) ?[*:0]const GLubyte {
    return switch (name) {
        enums.GL_VENDOR => "kudos",
        enums.GL_RENDERER => "kudos GL (NVIDIA Ada, GR engine)",
        enums.GL_VERSION => "OpenGL ES-CM 1.1",
        // The mandatory profile extensions. Core additions do not appear:
        // they have no suffix and are indistinguishable from the base API.
        enums.GL_EXTENSIONS => "GL_OES_read_format GL_OES_compressed_paletted_texture GL_OES_point_size_array GL_OES_point_sprite GL_OES_element_index_uint GL_KUDOS_material_maps GL_EXT_texture_format_BGRA8888",
        else => blk: {
            g.recordError(.invalid_enum);
            break :blk null;
        },
    };
}

pub fn fogf(g: *Context, pname: GLenum, param: GLfloat) void {
    const v = [4]GLfloat{ param, 0, 0, 0 };
    fogfv(g, pname, &v);
}

pub fn fogx(g: *Context, pname: GLenum, param: GLfixed) void {
    fogf(g, pname, fixed.toFloat(param));
}

pub fn fogfv(g: *Context, pname: GLenum, params: [*]const GLfloat) void {
    switch (pname) {
        enums.GL_FOG_MODE => g.fog.mode = switch (@as(GLenum, @intFromFloat(params[0]))) {
            enums.GL_LINEAR => .linear,
            enums.GL_EXP => .exp,
            enums.GL_EXP2 => .exp2,
            else => return g.recordError(.invalid_enum),
        },
        enums.GL_FOG_DENSITY => {
            if (params[0] < 0) return g.recordError(.invalid_value);
            g.fog.density = params[0];
        },
        enums.GL_FOG_START => g.fog.start = params[0],
        enums.GL_FOG_END => g.fog.end = params[0],
        enums.GL_FOG_COLOR => g.fog.color = .{ params[0], params[1], params[2], params[3] },
        else => g.recordError(.invalid_enum),
    }
}

pub fn fogxv(g: *Context, pname: GLenum, params: [*]const GLfixed) void {
    // FOG_MODE's "value" is a token, and a token converts to fixed-point WITHOUT
    // scaling (§2.3) — so it must not go through toFloat like the others.
    if (pname == enums.GL_FOG_MODE) {
        const v = [4]GLfloat{ @floatFromInt(params[0]), 0, 0, 0 };
        return fogfv(g, pname, &v);
    }
    const v = [4]GLfloat{ fixed.toFloat(params[0]), fixed.toFloat(params[1]), fixed.toFloat(params[2]), fixed.toFloat(params[3]) };
    fogfv(g, pname, &v);
}

// ── the rest of the surface ──────────────────────────────────────────────────
//
// Everything below is declared, checked by the comptime test, and split into its own
// module as it is implemented. These are the entry points whose behaviour depends on
// the object tables (es/buffer.zig, es/texobj.zig), the texture environment
// (es/texenv.zig), the state query tables (es/get.zig), or the draw lowering
// (es/pipeline.zig, es/draw.zig) — none of which are wired yet.

pub const enable = @import("enable.zig").enable;
pub const disable = @import("enable.zig").disable;
pub const isEnabled = @import("enable.zig").isEnabled;
pub const enableClientState = @import("enable.zig").enableClientState;
pub const disableClientState = @import("enable.zig").disableClientState;

pub const getBooleanv = @import("get.zig").getBooleanv;
pub const getIntegerv = @import("get.zig").getIntegerv;
pub const getFloatv = @import("get.zig").getFloatv;
pub const getFixedv = @import("get.zig").getFixedv;
pub const getPointerv = @import("get.zig").getPointerv;

pub const genBuffers = @import("buffer.zig").genBuffers;
pub const deleteBuffers = @import("buffer.zig").deleteBuffers;
pub const bindBuffer = @import("buffer.zig").bindBuffer;
pub const bufferData = @import("buffer.zig").bufferData;
pub const bufferSubData = @import("buffer.zig").bufferSubData;
pub const isBuffer = @import("buffer.zig").isBuffer;
pub const getBufferParameteriv = @import("buffer.zig").getBufferParameteriv;

pub const genTextures = @import("texobj.zig").genTextures;
pub const deleteTextures = @import("texobj.zig").deleteTextures;
pub const bindTexture = @import("texobj.zig").bindTexture;
pub const isTexture = @import("texobj.zig").isTexture;
pub const texImage2D = @import("texobj.zig").texImage2D;
pub const texSubImage2D = @import("texobj.zig").texSubImage2D;
pub const compressedTexImage2D = @import("texobj.zig").compressedTexImage2D;
pub const compressedTexSubImage2D = @import("texobj.zig").compressedTexSubImage2D;
pub const copyTexImage2D = @import("texobj.zig").copyTexImage2D;
pub const copyTexSubImage2D = @import("texobj.zig").copyTexSubImage2D;
pub const texParameterf = @import("texparam.zig").texParameterf;
pub const texParameterfv = @import("texparam.zig").texParameterfv;
pub const texParameteri = @import("texparam.zig").texParameteri;
pub const texParameteriv = @import("texparam.zig").texParameteriv;
pub const texParameterx = @import("texparam.zig").texParameterx;
pub const texParameterxv = @import("texparam.zig").texParameterxv;
pub const getTexParameterfv = @import("texparam.zig").getTexParameterfv;
pub const getTexParameteriv = @import("texparam.zig").getTexParameteriv;
pub const getTexParameterxv = @import("texparam.zig").getTexParameterxv;

// GL_KUDOS_material_maps (spec RND-005): the vendor extension and its tokens live
// in es/matmaps.zig — the generated Khronos tables must not carry them.
pub const materialMap = @import("matmaps.zig").materialMap;
pub const MatMap = @import("matmaps.zig").MatMap;

// EXT_texture_format_BGRA8888 (spec RND-008): the token lives with the
// format owner (es/unpack.zig) — the generated Khronos tables must not carry it.
pub const GL_BGRA_EXT = @import("unpack.zig").GL_BGRA_EXT;
pub const GL_KUDOS_material_maps = @import("matmaps.zig").GL_KUDOS_material_maps;
pub const GL_METAL_ROUGH_MAP_KUDOS = @import("matmaps.zig").GL_METAL_ROUGH_MAP_KUDOS;
pub const GL_NORMAL_MAP_KUDOS = @import("matmaps.zig").GL_NORMAL_MAP_KUDOS;
pub const GL_OCCLUSION_MAP_KUDOS = @import("matmaps.zig").GL_OCCLUSION_MAP_KUDOS;
pub const GL_EMISSIVE_MAP_KUDOS = @import("matmaps.zig").GL_EMISSIVE_MAP_KUDOS;

pub const texEnvf = @import("texenv.zig").texEnvf;
pub const texEnvfv = @import("texenv.zig").texEnvfv;
pub const texEnvi = @import("texenv.zig").texEnvi;
pub const texEnviv = @import("texenv.zig").texEnviv;
pub const texEnvx = @import("texenv.zig").texEnvx;
pub const texEnvxv = @import("texenv.zig").texEnvxv;
pub const getTexEnvfv = @import("texenv.zig").getTexEnvfv;
pub const getTexEnviv = @import("texenv.zig").getTexEnviv;
pub const getTexEnvxv = @import("texenv.zig").getTexEnvxv;

pub const vertexPointer = @import("vertex.zig").vertexPointer;
pub const normalPointer = @import("vertex.zig").normalPointer;
pub const colorPointer = @import("vertex.zig").colorPointer;
pub const texCoordPointer = @import("vertex.zig").texCoordPointer;
pub const pointSizePointerOES = @import("vertex.zig").pointSizePointerOES;

pub const drawArrays = @import("draw.zig").drawArrays;
pub const drawElements = @import("draw.zig").drawElements;
pub const readPixels = @import("frame.zig").readPixels;
pub const pixelStorei = @import("frame.zig").pixelStorei;

/// End the frame and hand it to the compositor.
///
/// The one entry point the specification does not name: ES 1.1 defines no window
/// system, no context creation and no buffer swap — EGL does, and EGL assumes an
/// operating system underneath it that kudos *is*. So kudos's EGL is this function.
pub fn swapBuffers(g: *Context) void {
    g.target.endFrame() catch {
        g.recordError(.out_of_memory);
    };
}

/// Has the last swapped frame reached the window yet?
///
/// Not in the standard either, and it is the reason kudos can draw N model windows at
/// the screen rate: GL's own answer would be glFinish, which BLOCKS, and blocking here
/// would stall the compositor that called us. An app polls this instead and skips a
/// frame it is not ready for.
pub fn frameReady(g: *Context) bool {
    return g.target.frameReady();
}

/// Abandon the frame being recorded — the window closed, or the frame is unwanted.
pub fn discardFrame(g: *Context) void {
    g.target.discard();
}

/// Begin a frame at the window's content size. Also not in the standard, for the same
/// reason as swapBuffers.
pub fn beginFrame(g: *Context, w: u32, h: u32) void {
    g.target.beginFrame(w, h) catch |e| switch (e) {
        idraw.Error.DrawBusy => return, // the previous frame is still in flight; skip
        else => return g.recordError(.out_of_memory),
    };
    // The device accepted a new frame, so the previous one has fully landed: its
    // staged vertex/index bytes are consumed, the staging cursor rewinds, and any
    // buffer the frame outgrew can finally be destroyed.
    g.resetStagingFrame();
    g.frame_w = w;
    g.frame_h = h;
    // The standard says the viewport and scissor box start as the whole window, and
    // there is no window until now — so this is the moment they get their initial
    // values, not context creation.
    if (g.viewport.w == 0 and g.viewport.h == 0) g.viewport = .{ .x = 0, .y = 0, .w = w, .h = h };
    if (g.scissor_box.w == 0 and g.scissor_box.h == 0) g.scissor_box = .{ .x = 0, .y = 0, .w = w, .h = h };
}

// ── the completeness gate ────────────────────────────────────────────────────
