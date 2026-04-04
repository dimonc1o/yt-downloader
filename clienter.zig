nst Contenter = @import("contenter.zig").Contenter;

pub const Clienter = struct {
    contenter: *Contenter,

    pub fn handleConnection(self: *Clienter, conn: std.net.Server.Connection) void {
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

        self.routeRequest(&request);
    }

    fn routeRequest(self: *Clienter, request: *std.http.Server.Request) void {
        const target = request.head.target;
        std.log.info("{s} {s}", .{ @tagName(request.head.method), target });

        if (std.mem.indexOf(u8, target, "/dl?url=")) |idx| {
            self.handleDl(request, target[idx + 8 ..]);
        } else if (self.isStaticAsset(target, "/style.css")) {
            self.serveStatic(request, self.contenter.css_content, "text/css; charset=utf-8");
        } else if (self.isStaticAsset(target, "/script.js")) {
            self.serveStatic(request, self.contenter.js_content, "application/javascript; charset=utf-8");
        } else {
            self.serveStatic(request, self.contenter.html_content, "text/html; charset=utf-8");
        }
    }

    fn isStaticAsset(_: *Clienter, target: []const u8, path: []const u8) bool {
        return std.mem.eql(u8, target, path);
    }

    fn serveStatic(_: *Clienter, request: *std.http.Server.Request, content: []u8, mime_type: []const u8) void {
        request.respond(content, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = mime_type },
            },
        }) catch |err| {
            std.log.err("respond: {s}", .{@errorName(err)});
        };
    }

    fn handleDl(self: *Clienter, request: *std.http.Server.Request, encoded_url: []const u8) void {
        if (encoded_url.len == 0) {
            self.sendResponse(request, .{ .status = .bad_request, .body = "Missing URL" });
            return;
        }

        const alloc = self.contenter.allocator;
        const url_buf = alloc.dupe(u8, encoded_url) catch |err| {
            std.log.err("alloc url_buf: {s}", .{@errorName(err)});
            self.sendResponse(request, .{ .status = .internal_server_error, .body = "Out of memory" });
            return;
        };
        defer alloc.free(url_buf);

        const decoded_url = std.Uri.percentDecodeInPlace(url_buf);
        const is_youtube = std.mem.indexOf(u8, decoded_url, "youtube.com") != null or std.mem.indexOf(u8, decoded_url, "youtu.be") != null;
        const is_tiktok = std.mem.indexOf(u8, decoded_url, "tiktok.com") != null;

        if (!is_youtube and !is_tiktok) {
            self.sendResponse(request, .{ .status = .bad_request, .body = "Unsupported URL" });
            return;
        }

        const term = runYtDlp(decoded_url, alloc) catch |err| {
            std.log.err("spawn yt-dlp failed: {s}", .{@errorName(err)});
            self.sendResponse(request, .{ .status = .internal_server_error, .body = "Failed to start. Is yt-dlp installed?" });
            return;
        };

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    self.sendResponse(request, .{ .status = .ok, .body = "OK" });
                } else {
                    self.sendResponse(request, .{ .status = .internal_server_error, .body = "Process error" });
                }
            },
            else => {
                std.log.err("process terminated unexpectedly: {}", .{term});
                self.sendResponse(request, .{ .status = .internal_server_error, .body = "Process unexpected exit" });
            },
        }
    }

    fn sendResponse(_: *Clienter, request: *std.http.Server.Request, resp: Response) void {
        request.respond(resp.body, .{ .status = resp.status }) catch |err| {
            std.log.err("respond failed: {s}", .{@errorName(err)});
        };
    }
};

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

fn runYtDlp(decoded_url: []const u8, alloc: std.mem.Allocator) !std.process.Child.Term {
    const argv = &[_][]const u8{
        "yt-dlp",
        "--cookies",
        "cookies.txt",
        "-f",
        "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[vcodec^=avc1]/best",
        "--merge-output-format",
        "mp4",
        "--ffmpeg-location",
        ".",
        "--postprocessor-args",
        "ffmpeg:-vcodec libx264 -pix_fmt yuv420p -profile:v high -level 4.1",
        decoded_url,
    };
    return runCommand(argv, alloc);
}
