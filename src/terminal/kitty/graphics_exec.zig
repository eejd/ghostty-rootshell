const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const point = @import("../point.zig");
const Terminal = @import("../Terminal.zig");
const command = @import("graphics_command.zig");
const image = @import("graphics_image.zig");
const Command = command.Command;
const Response = command.Response;
const ChunkedImage = image.ChunkedImage;
const Image = image.Image;

const log = std.log.scoped(.kitty_gfx);

// TODO:
// - delete
// - zlib deflate compression
// (not exhaustive, almost every op is ignoring additional config)

/// Execute a Kitty graphics command against the given terminal. This
/// will never fail, but the response may indicate an error and the
/// terminal state may not be updated to reflect the command. This will
/// never put the terminal in an unrecoverable state, however.
///
/// The allocator must be the same allocator that was used to build
/// the command.
pub fn execute(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) ?Response {
    log.debug("executing kitty graphics command: {}", .{cmd.control});

    const resp_: ?Response = switch (cmd.control) {
        .query => query(alloc, cmd),
        .transmit => transmit(alloc, terminal, cmd),
        .transmit_and_display => transmitAndDisplay(alloc, terminal, cmd),
        .display => display(alloc, terminal, cmd),

        .delete,
        .transmit_animation_frame,
        .control_animation,
        .compose_animation,
        => .{ .message = "ERROR: unimplemented action" },
    };

    // Handle the quiet settings
    if (resp_) |resp| {
        if (!resp.ok()) {
            log.warn("erroneous kitty graphics response: {s}", .{resp.message});
        }

        return switch (cmd.quiet) {
            .no => resp,
            .ok => if (resp.ok()) null else resp,
            .failures => null,
        };
    }

    return null;
}
/// Execute a "query" command.
///
/// This command is used to attempt to load an image and respond with
/// success/error but does not persist any of the command to the terminal
/// state.
fn query(alloc: Allocator, cmd: *Command) Response {
    const t = cmd.control.query;

    // Query requires image ID. We can't actually send a response without
    // an image ID either but we return an error and this will be logged
    // downstream.
    if (t.image_id == 0) {
        return .{ .message = "EINVAL: image ID required" };
    }

    // Build a partial response to start
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };

    // Attempt to load the image. If we cannot, then set an appropriate error.
    var img = Image.load(alloc, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    img.deinit(alloc);

    return result;
}

/// Transmit image data.
///
/// This loads the image, validates it, and puts it into the terminal
/// screen storage. It does not display the image.
fn transmit(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) Response {
    const t = cmd.transmission().?;
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };

    var img = loadAndAddImage(alloc, terminal, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    img.deinit(alloc);

    // After the image is added, set the ID in case it changed
    result.id = img.id;

    // If this is a transmit_and_display then the display part needs the image ID
    if (cmd.control == .transmit_and_display) {
        cmd.control.transmit_and_display.display.image_id = img.id;
    }

    return result;
}

/// Display a previously transmitted image.
fn display(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) Response {
    const d = cmd.display().?;

    // Display requires image ID or number.
    if (d.image_id == 0 and d.image_number == 0) {
        return .{ .message = "EINVAL: image ID or number required" };
    }

    // Build up our response
    var result: Response = .{
        .id = d.image_id,
        .image_number = d.image_number,
        .placement_id = d.placement_id,
    };

    // Verify the requested image exists if we have an ID
    const storage = &terminal.screen.kitty_images;
    const img_: ?Image = if (d.image_id != 0)
        storage.imageById(d.image_id)
    else
        storage.imageByNumber(d.image_number);
    const img = img_ orelse {
        result.message = "EINVAL: image not found";
        return result;
    };

    // Make sure our response has the image id in case we looked up by number
    result.id = img.id;

    // Determine the screen point for the placement.
    const placement_point = (point.Viewport{
        .x = terminal.screen.cursor.x,
        .y = terminal.screen.cursor.y,
    }).toScreen(&terminal.screen);

    // Add the placement
    storage.addPlacement(alloc, img.id, d.placement_id, .{
        .point = placement_point,
    }) catch |err| {
        encodeError(&result, err);
        return result;
    };

    return result;
}

/// A combination of transmit and display. Nothing special.
fn transmitAndDisplay(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) Response {
    const resp = transmit(alloc, terminal, cmd);
    if (!resp.ok()) return resp;

    // If the transmission is chunked, we defer the display
    const t = cmd.transmission().?;
    if (t.more_chunks) return resp;

    return display(alloc, terminal, cmd);
}

fn loadAndAddImage(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *Command,
) !Image {
    const t = cmd.transmission().?;
    const storage = &terminal.screen.kitty_images;

    // Determine our image. This also handles chunking and early exit.
    var img = if (storage.chunk) |chunk| img: {
        // Note: we do NOT want to call "cmd.toOwnedData" here because
        // we're _copying_ the data. We want the command data to be freed.
        try chunk.data.appendSlice(alloc, cmd.data);

        // If we have more then we're done
        if (t.more_chunks) return chunk.image;

        // We have no more chunks. Complete and validate the image.
        // At this point no matter what we want to clear out our chunked
        // state. If we hit a validation error or something we don't want
        // the chunked image hanging around in-memory.
        defer {
            chunk.destroy(alloc);
            storage.chunk = null;
        }

        break :img try chunk.complete(alloc);
    } else img: {
        const img = try Image.load(alloc, cmd);
        _ = cmd.toOwnedData();
        break :img img;
    };
    errdefer img.deinit(alloc);

    // If the image has no ID, we assign one
    if (img.id == 0) {
        img.id = storage.next_id;
        storage.next_id +%= 1;
    }

    // If this is chunked, this is the beginning of a new chunked transmission.
    // (We checked for an in-progress chunk above.)
    if (t.more_chunks) {
        // We allocate the chunk on the heap because its rare and we
        // don't want to always pay the memory cost to keep it around.
        const chunk_ptr = try alloc.create(ChunkedImage);
        errdefer alloc.destroy(chunk_ptr);
        chunk_ptr.* = try ChunkedImage.init(alloc, img);
        storage.chunk = chunk_ptr;
        return img;
    }

    // Dump the image data before it is decompressed
    // img.debugDump() catch unreachable;

    // Validate and store our image
    try img.complete(alloc);
    try storage.addImage(alloc, img);
    return img;
}

const EncodeableError = Image.Error || Allocator.Error;

/// Encode an error code into a message for a response.
fn encodeError(r: *Response, err: EncodeableError) void {
    switch (err) {
        error.OutOfMemory => r.message = "ENOMEM: out of memory",
        error.InvalidData => r.message = "EINVAL: invalid data",
        error.DecompressionFailed => r.message = "EINVAL: decompression failed",
        error.UnsupportedFormat => r.message = "EINVAL: unsupported format",
        error.UnsupportedMedium => r.message = "EINVAL: unsupported medium",
        error.DimensionsRequired => r.message = "EINVAL: dimensions required",
        error.DimensionsTooLarge => r.message = "EINVAL: dimensions too large",
    }
}
