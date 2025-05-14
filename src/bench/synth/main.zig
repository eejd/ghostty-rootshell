//! Package synth contains functions for generating synthetic data for
//! the purpose of benchmarking, primarily. This can also probably be used
//! for testing and fuzzing (probably generating a corpus rather than
//! directly fuzzing) and more.
//!
//! The synthetic data generators in this package are usually not performant
//! enough to be streamed in real time. They should instead be used to
//! generate a large amount of data in a single go and then streamed
//! from there.

pub const OSC = @import("osc.zig").Generator;

test {
    @import("std").testing.refAllDecls(@This());
}
