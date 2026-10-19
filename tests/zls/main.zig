const std = @import("std");
const greet = @import("greet");
pub fn main() void {
    std.debug.print("hi\n", .{});
    greet.hello();
}
