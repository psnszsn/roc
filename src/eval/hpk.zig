//! Narrow in-process compiler and interpreter surface for hpk.
//!
//! This deliberately does not re-export the dev, WebAssembly, or LLVM runners.

pub const Inspected = @import("inspected.zig");
pub const RuntimeHost = @import("runtime_host.zig");
pub const LirInterpreter = @import("interpreter.zig").Interpreter;
pub const boxy_runtime = @import("boxy_runtime.zig");
pub const layout = @import("layout");
pub const Value = @import("value.zig").Value;
