const std = @import("std");

test "sanity: 1 + 1 == 2" {
    try std.testing.expectEqual(@as(i32, 2), 1 + 1);
}
