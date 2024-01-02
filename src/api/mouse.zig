const std = @import("std");
const ziglua = @import("ziglua");
const input = @import("../platform/input.zig");
const Tuple = std.meta.Tuple;

// Get Mouse Position
pub fn position() Tuple(&.{f32, f32}) {
    const mouse_pos = input.getMousePosition();
    return .{ mouse_pos.x, mouse_pos.y };
}

// Get Mouse Button Pressed State
pub fn button(btn: u32) bool {
    const button_idx = @as(u5, @truncate(btn));
    const is_pressed = input.isMouseButtonPressed(button_idx);
    return is_pressed;
}
