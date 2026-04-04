const std = @import("std");

pub const Contenter = struct {
    html_content: []u8,
    css_content: []u8,
    js_content: []u8,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Contenter {
        const html = try loadFile("index.html", alloc);
        const css = try loadFile("style.css", alloc);
        const js = try loadFile("script.js", alloc);

        return .{
            .html_content = html,
            .css_content = css,
            .js_content = js,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Contenter) void {
        self.allocator.free(self.html_content);
        self.allocator.free(self.css_content);
        self.allocator.free(self.js_content);
    }

    fn loadFile(path: []const u8, alloc: std.mem.Allocator) ![]u8 {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.log.err("Could not open {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        defer file.close();
        return try file.readToEndAlloc(alloc, 1024 * 1024);
    }
};
