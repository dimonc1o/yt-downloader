const std = @import("std");

var html_content: []u8 = &[_]u8{};
const allocator = std.heap.smp_allocator;

const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

fn runCommand(argv: []const []const u8, alloc: std.mem.Allocator) !std.process.Child.Term {
    var child = std.process.Child.init(argv, alloc);
    
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    
    return child.spawnAndWait();
}

fn handleDl(request: *std.http.Server.Request, encoded_url: []const u8) void {
    if (encoded_url.len == 0) {
        sendResponse(request, .{ .status = .bad_request, .body = "Missing URL" });
        return;
    }

    const url_buf = allocator.dupe(u8, encoded_url) catch |err| {
        std.log.err("alloc url_buf: {s}", .{@errorName(err)});
        sendResponse(request, .{ .status = .internal_server_error, .body = "Out of memory" });
        return;
    };
    defer allocator.free(url_buf);

    const decoded_url = std.Uri.percentDecodeInPlace(url_buf);

    const is_youtube = std.mem.indexOf(u8, decoded_url, "youtube.com") != null or std.mem.indexOf(u8, decoded_url, "youtu.be") != null;
    const is_tiktok = std.mem.indexOf(u8, decoded_url, "tiktok.com") != null;

    // Если это не YouTube и не TikTok — отклоняем
    if (!is_youtube and !is_tiktok) {
        sendResponse(request, .{ .status = .bad_request, .body = "Unsupported URL" });
        return;
    }

    const term = runYtDlp(decoded_url, allocator) catch |err| {
        std.log.err("spawn yt-dlp failed: {s}", .{@errorName(err)});
        sendResponse(request, .{ .status = .internal_server_error, .body = "Failed to start. Is yt-dlp installed?" });
        return;
    };

    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                sendResponse(request, .{ .status = .ok, .body = "OK" });
            } else {
                sendResponse(request, .{ .status = .internal_server_error, .body = "Process error" });
            }
        },
        else => {
            std.log.err("process terminated unexpectedly: {}", .{term});
            sendResponse(request, .{ .status = .internal_server_error, .body = "Process unexpected exit" });
        },
    }
}

fn runYtDlp(decoded_url: []const u8, alloc: std.mem.Allocator) !std.process.Child.Term {
    const argv = &[_][]const u8{
        "yt-dlp",
        "--cookies",             "cookies.txt",
        "-f",                    "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[vcodec^=avc1]/best",
        "--merge-output-format", "mp4",
        "--ffmpeg-location",     ".",
        "--postprocessor-args",  "ffmpeg:-vcodec libx264 -pix_fmt yuv420p -profile:v high -level 4.1",
        decoded_url,
    };
    return runCommand(argv, alloc);
}

fn sendResponse(request: *std.http.Server.Request, resp: Response) void {
    request.respond(resp.body, .{ .status = resp.status }) catch |err| {
        std.log.err("respond failed: {s}", .{@errorName(err)});
    };
}

fn handleConnection(conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var stream_reader = conn.stream.reader(&read_buffer);
    var stream_writer = conn.stream.writer(&write_buffer);

    const writer = &stream_writer.interface;
    const reader = stream_reader.interface();

    var http_server = std.http.Server.init(reader, writer);

    var request = http_server.receiveHead() catch |err| {
        std.log.err("receiveHead: {s}", .{@errorName(err)});
        return;
    };

    const target = request.head.target;
    std.log.info("{s} {s}", .{ @tagName(request.head.method), target });

    if (std.mem.indexOf(u8, target, "/dl?url=")) |idx| {
        handleDl(&request, target[idx + 8 ..]);
    } else {
        request.respond(html_content, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        }) catch |err| {
            std.log.err("respond html: {s}", .{@errorName(err)});
        };
    }
}

// smp_allocator — глобальный lock-free аллокатор, безопасен для многопотока
const allocator = std.heap.smp_allocator;

const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

fn runYtDlp(decoded_url: []const u8) !std.process.Child.Term {
    const argv = &[_][]const u8{
        "yt-dlp",
        "--cookies",             "cookies.txt",
        "-f",                    "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[vcodec^=avc1]/best",
        "--merge-output-format", "mp4",
        "--ffmpeg-location",     ".",
        "--postprocessor-args",  "ffmpeg:-vcodec libx264 -pix_fmt yuv420p -profile:v high -level 4.1",
        decoded_url,
    };
    var child = std.process.Child.init(argv, allocator);
    return child.spawnAndWait();
}

fn sendResponse(request: *std.http.Server.Request, resp: Response) void {
    request.respond(resp.body, .{ .status = resp.status }) catch |err| {
        std.log.err("respond failed: {s}", .{@errorName(err)});
    };
}

fn handleDl(request: *std.http.Server.Request, encoded_url: []const u8) void {
    if (encoded_url.len == 0) {
        sendResponse(request, .{ .status = .bad_request, .body = "Missing URL" });
        return;
    }

    // Копируем URL в изменяемый буфер для percent-decode на месте
    const url_buf = allocator.dupe(u8, encoded_url) catch |err| {
        std.log.err("alloc url_buf: {s}", .{@errorName(err)});
        sendResponse(request, .{ .status = .internal_server_error, .body = "Out of memory" });
        return;
    };
    defer allocator.free(url_buf);

    const decoded_url = std.Uri.percentDecodeInPlace(url_buf);

    const term = runYtDlp(decoded_url) catch |err| {
        std.log.err("spawn yt-dlp: {s}", .{@errorName(err)});
        sendResponse(request, .{ .status = .internal_server_error, .body = "Failed to start yt-dlp" });
        return;
    };

    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                sendResponse(request, .{ .status = .ok, .body = "OK" });
            } else {
                std.log.err("yt-dlp exited with code {d}", .{code});
                sendResponse(request, .{ .status = .internal_server_error, .body = "yt-dlp error" });
            }
        },
        .Signal => |sig| {
            std.log.err("yt-dlp killed by signal {d}", .{sig});
            sendResponse(request, .{ .status = .internal_server_error, .body = "yt-dlp killed" });
        },
        .Stopped, .Unknown => {
            std.log.err("yt-dlp terminated unexpectedly: {}", .{term});
            sendResponse(request, .{ .status = .internal_server_error, .body = "yt-dlp unexpected exit" });
        },
    }
}

fn handleConnection(conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var stream_reader = conn.stream.reader(&read_buffer);
    var stream_writer = conn.stream.writer(&write_buffer);

    const writer = &stream_writer.interface;
    const reader = stream_reader.interface();

    var http_server = std.http.Server.init(reader, writer);

    var request = http_server.receiveHead() catch |err| {
        std.log.err("receiveHead: {s}", .{@errorName(err)});
        return;
    };

    const target = request.head.target;
    std.log.info("{s} {s}", .{ @tagName(request.head.method), target });

    if (std.mem.indexOf(u8, target, "/dl?url=")) |idx| {
        handleDl(&request, target[idx + 8 ..]);
    } else {
        request.respond(html_page, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        }) catch |err| {
            std.log.err("respond html: {s}", .{@errorName(err)});
        };
    }
}

pub fn main() !void {
<<<<<<< HEAD
    // ThreadPool использует smp_allocator для своих нужд
=======
    const file = std.fs.cwd().openFile("html_page.html", .{}) catch |err| {
        std.log.err("Could not open html_page.html: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();

    html_content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(html_content);

>>>>>>> d41423d (Refactor: move HTML to separate file, update title and add Wrether as co-author)
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    std.log.info("Listening on http://127.0.0.1:8080", .{});
<<<<<<< HEAD

    while (true) {
        const conn = net_server.accept() catch |err| {
            // EAGAIN/EMFILE и прочие — не фатальны, продолжаем
=======
    while (true) {
        const conn = net_server.accept() catch |err| {
>>>>>>> d41423d (Refactor: move HTML to separate file, update title and add Wrether as co-author)
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };

        pool.spawn(handleConnection, .{conn}) catch |err| {
<<<<<<< HEAD
            // Не смогли добавить задачу — закрываем соединение сами
=======
>>>>>>> d41423d (Refactor: move HTML to separate file, update title and add Wrether as co-author)
            std.log.err("spawn task: {s}", .{@errorName(err)});
            conn.stream.close();
        };
    }
}
