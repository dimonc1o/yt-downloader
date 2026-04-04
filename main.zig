const std = @import("std");
const Contenter = @import("contenter.zig").Contenter;
const Clienter = @import("clienter.zig").Clienter;

const allocator = std.heap.smp_allocator;

fn handleConnectionWrapper(conn: std.net.Server.Connection, clienter: *Clienter) void {
    clienter.handleConnection(conn);
}

pub fn main() !void {
    var contenter = try Contenter.init(allocator);
    defer contenter.deinit();

    var clienter = Clienter{ .contenter = &contenter };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    std.log.info("Listening on http://127.0.0.1:8080", .{});

    while (true) {
        const conn = net_server.accept() catch |err| {
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };
        pool.spawn(handleConnectionWrapper, .{ conn, &clienter }) catch |err| {
            std.log.err("spawn task: {s}", .{@errorName(err)});
            conn.stream.close();
        };
    }
}
