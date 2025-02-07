const std = @import("std");
const expect = std.testing.expect;

const Mode = enum {
    server,
    client,
    fn tryFrom(arg: [:0]const u8) !Mode {
        if (std.mem.eql(u8, arg, "server")) return Mode.server;
        if (std.mem.eql(u8, arg, "client")) return Mode.client;
        return error.InvalidMode;
    }
};

fn usage() noreturn {
    const usage_str =
        \\Usage: zsrv KIND [ARGS...]
        \\
        \\KIND:
        \\ server  Opens a server listening for incoming connections
        \\ client  Connects to a server as client
        \\
        \\ARGS server:
        \\ PORT    Port to bind the server to
        \\
        \\ARGS client:
        \\ IP      IP address of the server
        \\ PORT    Port of the server
        \\
    ;
    std.debug.print(usage_str, .{});
    std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("Memory leaked\n", .{});
            std.process.exit(1);
        }
    }

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // NOTE: The first arguments should always? be the binary being executed
    _ = args.skip();

    const kind: Mode = Mode.tryFrom(args.next() orelse usage()) catch usage();

    try switch (kind) {
        .server => handleServer(alloc, &args),
        .client => handleClient(alloc, &args),
    };
}

fn handleServer(alloc: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    std.debug.print("Handling server\n", .{});

    const port = std.fmt.parseInt(u16, args.next() orelse usage(), 0) catch usage();

    std.debug.print("Opening server on port '{d}'\n", .{port});

    const addr = std.net.Address{ .in = std.net.Ip4Address.parse("0.0.0.0", port) catch usage() };

    var server = try addr.listen(.{ .reuse_port = true });
    defer server.deinit();

    std.debug.print("Opened server on {}\n", .{addr});

    while (true) {
        const conn = try server.accept();
        _ = try std.Thread.spawn(.{ .allocator = alloc }, handleConnection, .{ alloc, conn });
    }
}

fn handleConnection(alloc: std.mem.Allocator, conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    std.debug.print("[{}] Incoming connection\n", .{conn.address});

    while (true) {
        const message = try conn.stream.reader().readUntilDelimiterOrEofAlloc(alloc, '\n', 512);

        if (message) |msg| {
            defer alloc.free(msg);
            std.debug.print("[{}] < {s}\n", .{ conn.address, msg });
        } else {
            std.debug.print("[{}] Connection closed\n", .{conn.address});
            return;
        }
    }
}

fn handleClient(alloc: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    std.debug.print("Handling client\n", .{});

    var addr = std.net.Ip4Address.parse(args.next() orelse usage(), 0) catch usage();
    const port = std.fmt.parseInt(u16, args.next() orelse usage(), 0) catch usage();

    addr.setPort(port);

    std.debug.print("Connecting to server on port '{d}'\n", .{port});

    var conn = try std.net.tcpConnectToAddress(.{ .in = addr });
    defer conn.close();

    std.debug.print("Connected to server\n", .{});

    while (true) {
        std.debug.print("> ", .{});

        const message = try std.io.getStdIn().reader().readUntilDelimiterOrEofAlloc(alloc, '\n', 512);

        if (message) |msg| {
            defer alloc.free(msg);
            if (std.mem.eql(u8, msg, "q")) {
                std.debug.print("Exit requested - Disconnecting\n", .{});
                return;
            }

            std.debug.print("Sending message: {s}\n", .{msg});
            try conn.writeAll(msg);
            try conn.writeAll(&[_]u8{'\n'});
        } else {
            return;
        }
    }
}
