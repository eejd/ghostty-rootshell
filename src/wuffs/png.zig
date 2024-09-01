const std = @import("std");

const c = @import("c.zig").c;
const Error = @import("error.zig").Error;

const log = std.log.scoped(.wuffs_png);

pub fn decode(alloc: std.mem.Allocator, data: []const u8) Error!struct {
    width: u32,
    height: u32,
    data: []const u8,
} {
    log.info("data is {d} bytes", .{data.len});

    // Work around some wierdness in WUFFS/Zig, there are some structs that
    // are defined as "extern" by the Zig compiler which means that Zig won't
    // allocate them on the stack at compile time. WUFFS has functions for
    // dynamically allocating these structs but they use the C malloc/free. This
    // gets around that by using the Zig allocator to allocate enough memory for
    // the struct and then casts it to the appropropriate pointer.

    const decoder_buf = try alloc.alloc(u8, c.sizeof__wuffs_png__decoder());
    defer alloc.free(decoder_buf);

    const decoder: ?*c.wuffs_png__decoder = @constCast(@ptrCast(decoder_buf));
    {
        const status = c.wuffs_png__decoder__initialize(
            decoder,
            c.sizeof__wuffs_png__decoder(),
            c.WUFFS_VERSION,
            0,
        );
        if (!c.wuffs_base__status__is_ok(&status)) {
            const e = c.wuffs_base__status__message(&status);
            log.err("{s}", .{e});
            return error.WuffsError;
        }
    }

    var source_buffer = std.mem.zeroes(c.wuffs_base__io_buffer);
    source_buffer.data.ptr = @constCast(@ptrCast(data.ptr));
    source_buffer.data.len = data.len;
    source_buffer.meta.wi = data.len;
    source_buffer.meta.ri = 0;
    source_buffer.meta.pos = 0;
    source_buffer.meta.closed = true;

    var image_config = std.mem.zeroes(c.wuffs_base__image_config);
    {
        const status = c.wuffs_png__decoder__decode_image_config(
            decoder,
            &image_config,
            &source_buffer,
        );
        if (!c.wuffs_base__status__is_ok(&status)) {
            const e = c.wuffs_base__status__message(&status);
            log.err("{s}", .{e});
            return error.WuffsError;
        }
    }

    const width = c.wuffs_base__pixel_config__width(&image_config.pixcfg);
    const height = c.wuffs_base__pixel_config__height(&image_config.pixcfg);

    c.wuffs_base__pixel_config__set(
        &image_config.pixcfg,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL,
        c.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
        width,
        height,
    );

    const color = c.wuffs_base__color_u32_argb_premul;

    const destination = try alloc.alloc(u8, width * height * @sizeOf(color));
    errdefer alloc.free(destination);

    // temporary buffer for intermediate processing of image
    const work_buffer = try alloc.alloc(
        u8,
        c.wuffs_png__decoder__workbuf_len(decoder).max_incl,
    );
    defer alloc.free(work_buffer);

    const work_slice = c.wuffs_base__make_slice_u8(
        work_buffer.ptr,
        work_buffer.len,
    );

    var pixel_buffer = std.mem.zeroes(c.wuffs_base__pixel_buffer);
    {
        const status = c.wuffs_base__pixel_buffer__set_from_slice(
            &pixel_buffer,
            &image_config.pixcfg,
            c.wuffs_base__make_slice_u8(destination.ptr, destination.len),
        );
        if (!c.wuffs_base__status__is_ok(&status)) {
            const e = c.wuffs_base__status__message(&status);
            log.err("{s}", .{e});
            return error.WuffsError;
        }
    }

    var frame_config = std.mem.zeroes(c.wuffs_base__frame_config);
    {
        const status = c.wuffs_png__decoder__decode_frame_config(
            decoder,
            &frame_config,
            &source_buffer,
        );
        if (!c.wuffs_base__status__is_ok(&status)) {
            const e = c.wuffs_base__status__message(&status);
            log.err("{s}", .{e});
            return error.WuffsError;
        }
    }

    {
        const status = c.wuffs_png__decoder__decode_frame(
            decoder,
            &pixel_buffer,
            &source_buffer,
            c.WUFFS_BASE__PIXEL_BLEND__SRC_OVER,
            work_slice,
            null,
        );
        if (!c.wuffs_base__status__is_ok(&status)) {
            const e = c.wuffs_base__status__message(&status);
            log.err("{s}", .{e});
            return error.WuffsError;
        }
    }

    return .{
        .width = width,
        .height = height,
        .data = destination,
    };
}
