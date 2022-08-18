pub const F32x4 = @Vector(4, f32);

/// Matrix type
pub const Mat = [4]F32x4;

/// Identity matrix
pub fn identity() Mat {
    return .{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
}

pub fn ortho2d(left: f32, right: f32, bottom: f32, top: f32) Mat {
    var mat = identity();
    mat[0][0] = 2 / (right - left);
    mat[1][1] = 2 / (top - bottom);
    mat[2][2] = -1.0;
    mat[3][0] = -(right + left) / (right - left);
    mat[3][1] = -(top + bottom) / (top - bottom);
    return mat;
}
