//! OpenGL bindings.
//!
//! These are pupose-built for usage within this program. While they closely
//! align with the OpenGL C APIs, they aren't meant to be general purpose,
//! they aren't meant to have 100% API coverage, and they aren't meant to
//! be hyper-performant.
//!
//! For performance-intensive or unsupported aspects of OpenGL, the C
//! API is exposed via the `c` constant.
//!
//! WARNING: Lots of performance improvements that we can make with Zig
//! comptime help. I'm deferring this until later but have some fun ideas.

pub const c = @import("opengl/c.zig");
pub const glad = @import("opengl/glad.zig");
pub usingnamespace @import("opengl/draw.zig");

pub const ext = @import("opengl/extensions.zig");
pub const Buffer = @import("opengl/Buffer.zig");
pub const Program = @import("opengl/Program.zig");
pub const Shader = @import("opengl/Shader.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const VertexArray = @import("opengl/VertexArray.zig");
