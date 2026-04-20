const std = @import("std");
const zunit = @import("zunit");

pub fn main(init: std.process.Init) !void {
    try zunit.run(init.io, .{
        .output_file = try zunit.outputFileArg(
            init.arena.allocator(),
            init.minimal.args,
        ),
    });
}
