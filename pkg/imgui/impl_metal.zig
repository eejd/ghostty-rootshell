const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const ImplMetal = struct {
    pub fn init(device: ?*anyopaque) bool {
        return ImGui_ImplMetal_Init(device);
    }

    pub fn shutdown() void {
        return ImGui_ImplMetal_Shutdown();
    }

    pub fn newFrame(render_pass_desc: ?*anyopaque) void {
        return ImGui_ImplMetal_NewFrame(render_pass_desc);
    }

    pub fn renderDrawData(
        data: *imgui.DrawData,
        command_buffer: ?*anyopaque,
        command_encoder: ?*anyopaque,
    ) void {
        ImGui_ImplMetal_RenderDrawData(data, command_buffer, command_encoder);
    }

    extern "c" fn ImGui_ImplMetal_Init(?*anyopaque) bool;
    extern "c" fn ImGui_ImplMetal_Shutdown() void;
    extern "c" fn ImGui_ImplMetal_NewFrame(?*anyopaque) void;
    extern "c" fn ImGui_ImplMetal_RenderDrawData(*imgui.DrawData, ?*anyopaque, ?*anyopaque) void;
};
