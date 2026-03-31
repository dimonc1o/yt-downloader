const std = @import("std");

const html_page =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\    <meta charset="UTF-8">
    \\    <title>YTD by dimoncio</title>
    \\    <style>
    \\        body { background-color: #000; color: #fff; display: flex; flex-direction: column; justify-content: center; align-items: center; height: 100vh; margin: 0; font-family: 'Segoe UI', sans-serif; overflow: hidden; }
    \\        h1 { letter-spacing: 5px; margin-bottom: 30px; font-weight: 200; transition: all 0.5s ease; }
    \\        .container { position: relative; display: flex; align-items: center; gap: 10px; z-index: 2; }
    \\        input { 
    \\            padding: 15px 25px; width: 400px; border: 1px solid #333; background: #111; color: #fff; 
    \\            border-radius: 12px; font-size: 16px; outline: none; transition: all 0.4s ease; 
    \\        }
    \\        input:hover, input:focus { border-color: #555; box-shadow: 0 0 20px rgba(255, 255, 255, 0.1); }
    \\        .btn-download {
    \\            width: 0; opacity: 0; overflow: hidden; background: #fff; color: #000; border: none; border-radius: 12px;
    \\            padding: 15px 0; cursor: pointer; font-size: 20px; transition: all 0.5s cubic-bezier(0.175, 0.885, 0.32, 1.275);
    \\            display: flex; align-items: center; justify-content: center;
    \\        }
    \\        input:not(:placeholder-shown) + .btn-download { width: 60px; opacity: 1; padding: 15px; }
    \\        .info-panel { 
    \\            margin-top: 20px; width: 420px; font-size: 14px; color: #888; 
    \\            display: none; opacity: 1; max-height: 200px;
    \\            transition: opacity 0.5s ease, max-height 0.5s ease, transform 0.5s ease, margin 0.5s ease;
    \\            overflow: hidden;
    \\        }
    \\        .info-panel.hidden {
    \\            display: block !important;
    \\            opacity: 0;
    \\            max-height: 0;
    \\            transform: translateY(-40px);
    \\            margin-top: 0;
    \\        }
    \\        #status-text { color: #fff; font-weight: bold; margin-bottom: 10px; display: block; }
    \\        .loader { width: 100%; height: 4px; background: #222; position: relative; overflow: hidden; margin-top: 15px; border-radius: 2px; }
    \\        .loader::after { content: ""; position: absolute; left: -150%; width: 100%; height: 100%; background: #fff; animation: loading 2s infinite; }
    \\        @keyframes loading { 100% { left: 100%; } }
    \\        .author { position: fixed; bottom: 20px; font-size: 10px; letter-spacing: 2px; color: #333; text-transform: uppercase; }
    \\    </style>
    \\</head>
    \\<body>
    \\    <h1>YTD</h1>
    \\    <div class="container">
    \\        <input type="text" id="url" placeholder="Paste YouTube link here..." autocomplete="off" />
    \\        <button class="btn-download" id="dl-btn">➔</button>
    \\    </div>
    \\    <div class="info-panel" id="info">
    \\        <span id="status-text">Processing video download...</span>
    \\        <div class="loader"></div>
    \\    </div>
    \\    <div class="author">Created by dimoncio</div>
    \\    <script>
    \\        const input = document.getElementById('url');
    \\        const btn = document.getElementById('dl-btn');
    \\        const info = document.getElementById('info');
    \\        btn.onclick = async () => {
    \\            const url = input.value.trim();
    \\            if (!url) return;
    \\            info.classList.remove('hidden');
    \\            info.style.display = 'block';
    \\            document.getElementById('status-text').innerText = "Processing video download...";
    \\            const res = await fetch('/dl?url=' + encodeURIComponent(url));
    \\            if (res.ok) {
    \\                document.getElementById('status-text').innerText = "Done! Video ready for AE.";
    \\                input.value = "";
    \\                setTimeout(() => {
    \\                    info.classList.add('hidden');
    \\                    setTimeout(() => {
    \\                        if (info.classList.contains('hidden')) info.style.display = 'none';
    \\                    }, 500);
    \\                }, 2000);
    \\            } else {
    \\                document.getElementById('status-text').innerText = "Error! Check connection.";
    \\            }
    \\        };
    \\    </script>
    \\</body>
    \\</html>
;

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
    // ThreadPool использует smp_allocator для своих нужд
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    std.log.info("Listening on http://127.0.0.1:8080", .{});

    while (true) {
        const conn = net_server.accept() catch |err| {
            // EAGAIN/EMFILE и прочие — не фатальны, продолжаем
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };

        pool.spawn(handleConnection, .{conn}) catch |err| {
            // Не смогли добавить задачу — закрываем соединение сами
            std.log.err("spawn task: {s}", .{@errorName(err)});
            conn.stream.close();
        };
    }
}
