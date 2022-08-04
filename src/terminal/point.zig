/// Point is a point within the terminal grid. A point is ALWAYS
/// zero-indexed. If you see the "Point" type, you know that a
/// zero-indexed value is expected.
pub const Point = struct {
    x: usize = 0,
    y: usize = 0,
};
