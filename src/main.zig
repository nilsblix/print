const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("stb_image.h");
});
const clap = @import("clap");

fn lumaBrightness(r: anytype, g: anytype, b: anytype) f32 {
    const rf = @as(f32, @floatFromInt(r));
    const gf = @as(f32, @floatFromInt(g));
    const bf = @as(f32, @floatFromInt(b));
    return 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
}

fn lumaBrightnessFloat(r: anytype, g: anytype, b: anytype) f32 {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub fn add(self: Color, other: Color) Color {
        return .{
            .r = self.r +% other.r,
            .g = self.g +% other.g,
            .b = self.b +% other.b,
            .a = self.a +% other.a,
        };
    }

    pub fn scale(self: Color, value: usize) Color {
        const v: u32 = @intCast(value);
        return .{
            .r = @intCast(@as(u32, self.r) * v),
            .g = @intCast(@as(u32, self.g) * v),
            .b = @intCast(@as(u32, self.b) * v),
            .a = @intCast(@as(u32, self.a) * v),
        };

    }

    pub fn div(self: Color, value: usize) Color {
        const v: u32 = @intCast(value);
        return .{
            .r = @intCast(@divTrunc(@as(u32, self.r), v)),
            .g = @intCast(@divTrunc(@as(u32, self.g), v)),
            .b = @intCast(@divTrunc(@as(u32, self.b), v)),
            .a = @intCast(@divTrunc(@as(u32, self.a), v)),
        };
    }

    pub fn brightness(self: Color) f32 {
        return lumaBrightness(self.r, self.g, self.b);
    }


    pub fn toSgr(self: Color, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "38;2;{d};{d};{d}", .{self.r, self.g, self.b});
    }
};

const Pixels = struct {
    items: []Color,
    width: usize,
    height: usize,

    const sobel_kernel_x = [_]i32{ -1, 0, 1, -2, 0, 2, -1, 0, 1 };
    const sobel_kernel_y = [_]i32{ -1, -2, -1, 0, 0, 0, 1, 2, 1 };
    const sobel_offsets = [_]struct { i32, i32 }{
        .{ -1, -1 },
        .{  0, -1 },
        .{  1, -1 },
        .{ -1,  0 },
        .{  0,  0 },
        .{  1,  0 },
        .{ -1,  1 },
        .{  0,  1 },
        .{  1,  1 },
    };

    const Self = @This();

    pub fn init(items: []Color, width: usize, height: usize) Self {
        return .{
            .items = items,
            .width = width,
            .height = height,
        };
    }

    pub fn sampleBlockAvg(self: Self, col: usize, row: usize, block_w: usize, block_h: usize) Color {
        const x_end = @min(self.width, col + block_w);
        const y_end = @min(self.height, row + block_h);

        var sum_r: u32 = 0;
        var sum_g: u32 = 0;
        var sum_b: u32 = 0;
        var sum_a: u32 = 0;
        var count: u32 = 0;

        var yy: usize = row;
        while (yy < y_end) : (yy += 1) {
            var xx: usize = col;
            while (xx < x_end) : (xx += 1) {
                const i = yy * self.width + xx;
                const color = self.items[i];
                sum_r += color.r;
                sum_g += color.g;
                sum_b += color.b;
                sum_a += color.a;
                count += 1;
            }
        }

        if (count == 0) return .{};

        return .{
            .r = @intCast(@divTrunc(sum_r, count)),
            .g = @intCast(@divTrunc(sum_g, count)),
            .b = @intCast(@divTrunc(sum_b, count)),
            .a = @intCast(@divTrunc(sum_a, count)),
        };
    }

    pub fn posFromIndex(self: Self, idx: usize) struct { usize, usize } {
        const rem = idx % self.width;
        const row = (idx - rem) / self.width;
        return .{ rem, row };
    }

    pub fn indexFromPos(self: Self, col: usize, row: usize) usize {
        return row * self.width + col;
    }

    pub const SobelGlyph = enum {
        pipe,
        backward_slash,
        dash,
        forward_slash,
        none,

        fn toChar(self: SobelGlyph) ?u8 {
            return switch (self) {
                .none => null,
                .forward_slash => '/',
                .backward_slash => '\\',
                .pipe => '|',
                .dash => '-',
            };
        }

        pub fn angleToGlyph(theta: f32) SobelGlyph {
            const T = struct {
                pub fn apply(x: f32) usize {
                    return @intFromFloat(@round(4 * x / std.math.pi));
                }
            };
            const idx = T.apply(@abs(theta));
            if (idx > @intFromEnum(SobelGlyph.none)) {
                return .none;
            }
            return @enumFromInt(idx);
        }
    };

    /// Populates Sobel glyphs into `buf`. This function assumes that `buf`
    /// already has the correct amount of elements.
    pub fn sobelGlyphs(self: Self, buf: *[]SobelGlyph, edge_weight: usize) void {
        for (self.items, 0..) |_, idx| {
            const pos = self.posFromIndex(idx);

            // If the pixel is at the border of the image, then no edge can be found here.
            if (pos.@"0" == 0 or pos.@"0" == self.width - 1 or pos.@"1" == 0 or pos.@"1" == self.height - 1) {
                buf.*[idx] = .none;
                continue;
            }

            const Acc = struct { f32, f32, f32 };
            var acc_x: Acc = .{ 0.0, 0.0, 0.0 };
            var acc_y: Acc = .{ 0.0, 0.0, 0.0 };
            for (0..9) |kernel_idx| {
                const offset = Pixels.sobel_offsets[kernel_idx];

                const col: i32 = @as(i32, @intCast(pos.@"0")) + offset.@"0";
                const row: i32 = @as(i32, @intCast(pos.@"1")) + offset.@"1";

                const offset_idx = self.indexFromPos(@intCast(col), @intCast(row));
                const value = self.items[offset_idx];

                const sobel_kernel_value_x = Pixels.sobel_kernel_x[kernel_idx];
                acc_x.@"0" += @as(f32, @floatFromInt(value.r)) * @as(f32, @floatFromInt(sobel_kernel_value_x));
                acc_x.@"1" += @as(f32, @floatFromInt(value.g)) * @as(f32, @floatFromInt(sobel_kernel_value_x));
                acc_x.@"2" += @as(f32, @floatFromInt(value.b)) * @as(f32, @floatFromInt(sobel_kernel_value_x));

                const sobel_kernel_value_y = Pixels.sobel_kernel_y[kernel_idx];
                acc_y.@"0" += @as(f32, @floatFromInt(value.r)) * @as(f32, @floatFromInt(sobel_kernel_value_y));
                acc_y.@"1" += @as(f32, @floatFromInt(value.g)) * @as(f32, @floatFromInt(sobel_kernel_value_y));
                acc_y.@"2" += @as(f32, @floatFromInt(value.b)) * @as(f32, @floatFromInt(sobel_kernel_value_y));
            }

            const acc_x_sq = acc_x.@"0" * acc_x.@"0" + acc_x.@"1" * acc_x.@"1" + acc_x.@"2" * acc_x.@"2";
            const acc_y_sq = acc_y.@"0" * acc_y.@"0" + acc_y.@"1" * acc_y.@"1" + acc_y.@"2" * acc_y.@"2";

            const sobel = @sqrt(acc_x_sq + acc_y_sq);
            if (sobel > @as(f32, @floatFromInt(edge_weight))) {
                const brightness_x = lumaBrightnessFloat(acc_x.@"0", acc_x.@"1", acc_x.@"2");
                const brightness_y = lumaBrightnessFloat(acc_y.@"0", acc_y.@"1", acc_y.@"2");
                const theta = std.math.atan2(brightness_y, brightness_x);
                buf.*[idx] = SobelGlyph.angleToGlyph(theta);
            } else {
                buf.*[idx] = SobelGlyph.none;
            }
        }
    }
};

const Config = struct {
    path: []const u8,
    width: usize        = 80,
    height: usize       = 40,
    char_aspect: f32    = 2.0,
    ramp: []const u8    = " .-=+*#&@",
    use_color: bool     = true,
    display_edges: bool = true,
    edge_weight: usize  = 500,
    use_solid: bool     = false,

    const Validation = union(enum) {
        ok,
        message: []const u8,
    };

    /// Args come from clap.
    fn validate(self: Config, args: anytype) Validation {
        if (args.path == null)
            return .{ .message = "No path was supplied." };
        if (self.use_solid and args.ramp != null) {
            return .{ .message = "Solid cannot have a specified ramp." };
        }
        if (self.use_solid and args.nocolor != 0)
            return .{ .message = "Solid cannot be colorless." };
        if (self.use_solid and args.noedges != 0)
            return .{ .message = "Solid cannot be specified with noedges." };
        if (self.use_solid and args.edgeweight != null)
            return .{ .message = "Solid has no edges, therefore edgeweight is irrelevant." };
        return .ok;
    }
};

const StbConfig = struct {
    width: usize,
    height: usize,
    channels: usize,
};

fn calculateHeight(config: Config, stb_config: StbConfig) usize {
    const aspect: f32 = @as(f32, @floatFromInt(stb_config.height)) / @as(f32, @floatFromInt(stb_config.width));
    const height_float = @as(f32, @floatFromInt(config.width)) * aspect / config.char_aspect;
    return @intFromFloat(@floor(height_float));
}

fn loadImage(config: Config) !struct { Pixels, StbConfig } {
    var x: c_int = undefined;
    var y: c_int = undefined;
    var n: c_int = undefined;
    // The 4 forces stb_image to load 4 color channels.
    const data = c.stbi_load(config.path.ptr, &x, &y, &n, 4) orelse return error.FileNotFound;
    defer c.stbi_image_free(data);

    const width: usize = @intCast(x);
    const height: usize = @intCast(y);
    const raw_pixel_count: usize = width * height * 4;
    const raw_pixels: []u8 = data[0..raw_pixel_count];

    const items = std.mem.bytesAsSlice(Color, raw_pixels);
    const pixels = Pixels.init(items, width, height);

    const stb_config = StbConfig{
        .width = @intCast(x),
        .height = @intCast(y),
        .channels = @intCast(n),
    };

    return .{ pixels, stb_config };
}

fn terminalPosToPixelPos(config: Config, stb_config: StbConfig, col: usize, row: usize) struct { usize, usize } {
    const cp = col * stb_config.width / config.width;
    const rp = row * stb_config.height / config.height;
    return .{ cp, rp };
}

/// Assumes that buf has the correct number of elements.
fn createTerminalPixels(buf: *[]Color, pixels: Pixels, config: Config, stb_config: StbConfig) !Pixels {
    const block_width = @max(@as(usize, 1), stb_config.width / config.width);
    const block_height = @max(@as(usize, 1), stb_config.height / config.height);

    for (0..config.height) |row| {
        for (0..config.width) |col| {
            const pixel_pos = terminalPosToPixelPos(config, stb_config, col, row);
            const avg = pixels.sampleBlockAvg(pixel_pos.@"0", pixel_pos.@"1", block_width, block_height);
            const idx = row * config.width + col;
            buf.*[idx]= avg;
        }
    }

    return Pixels {
        .items = buf.*,
        .width = config.width,
        .height = config.height,
    };
}

fn printPixel(alloc: Allocator, px: Color, ramp: []const u8, use_color: bool) !void {
    const brightness = px.brightness();
    const max_brightness = 255.0;
    const clamped = if (brightness < 0.0) 0.0 else if (brightness > max_brightness) max_brightness else brightness;
    const normalized = clamped / max_brightness;
    const ramp_pos = normalized * @as(f32, @floatFromInt(ramp.len - 1));
    const ch = ramp[@as(usize, @intFromFloat(@floor(ramp_pos)))];

    if (use_color) {
        const sgr = try px.toSgr(alloc);
        std.debug.print("\x1b[{s}m{c}\x1b[39m", .{sgr, ch});
    } else {
        std.debug.print("{c}", .{ch});
    }
}

fn printAscii(alloc: Allocator, pixels: Pixels, config: Config, stb_config: StbConfig) !void {
    const capacity = config.width * config.height;
    var list = try std.ArrayList(Color).initCapacity(alloc, capacity);
    defer list.deinit(alloc);

    try list.resize(alloc, capacity);

    const terminal = try createTerminalPixels(&list.items, pixels, config, stb_config);

    var sobel_list: std.ArrayList(Pixels.SobelGlyph) = undefined;
    if (config.display_edges) {
        // Note that we do not put any defer deinit statement here, as it would
        // get deinitialized when this scope ends, which is not wanted
        // behaviour.
        sobel_list = try std.ArrayList(Pixels.SobelGlyph).initCapacity(alloc, capacity);
        try sobel_list.resize(alloc, capacity);
        terminal.sobelGlyphs(&sobel_list.items, config.edge_weight);
    }

    for (terminal.items, 0..) |px, idx| {
        if (idx % terminal.width == 0 and idx != 0) {
            std.debug.print("\n", .{});
        }

        if (config.display_edges and sobel_list.items[idx] != .none) {
            const ch = sobel_list.items[idx].toChar() orelse unreachable;
            const sgr = if (config.use_color) try px.toSgr(alloc) else "";
            std.debug.print("\x1b[{s}m{c}\x1b[39m", .{sgr, ch});
        } else {
            try printPixel(alloc, px, config.ramp, config.use_color);
        }
    }

    // We need to deinit the list here, because if a `defer` statement was put
    // inside the block where sobel_list was initialized, then it would deinit
    // the list before it the loop.
    if (config.display_edges)
        sobel_list.deinit(alloc);

    std.debug.print("\n", .{});
}

fn printSolid(alloc: Allocator, pixels: Pixels, config: Config, stb_config: StbConfig) !void {
    const capacity = config.width * config.height;
    var list = try std.ArrayList(Color).initCapacity(alloc, capacity);
    defer list.deinit(alloc);

    try list.resize(alloc, capacity);

    const terminal = try createTerminalPixels(&list.items, pixels, config, stb_config);

    for (terminal.items, 0..) |px, idx| {
        if (idx % terminal.width == 0 and idx != 0) {
            std.debug.print("\n", .{});
        }
        const sgr = try px.toSgr(alloc);
        const ch: []const u8 = "\u{2588}";
        std.debug.print("\x1b[{s}m{s}\x1b[39m", .{sgr, ch});
    }

    std.debug.print("\n", .{});
}

fn print(alloc: Allocator, pixels: Pixels, config: Config, stb_config: StbConfig) !void {
    if (config.use_solid) {
        try printSolid(alloc, pixels, config, stb_config);
    } else {
        try printAscii(alloc, pixels, config, stb_config);
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\-w, --width <usize>       Output width in characters.
        \\-a, --aspect <f32>        Character aspect ratio (height/width). Defaults to 2.0.
        \\--ramp <str>              The character rampt to use when defining brightness.
        \\--nocolor                 Disable colors.
        \\--noedges                 Disable edge-highlighting.
        \\--edgeweight <usize>      The required weight for edge-detection. Defaults to 500.
        \\--solid                   Use solid pixels instead of ascii-characters. Uses Nerd Characters to print solid characters. This option errors when combined with edge, ramp and color options.
        \\--path <str>              Path to the image that should be printed.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});

    var config = Config{ .path = undefined };

    if (res.args.path) |p|          config.path = p;
    if (res.args.width) |w|         config.width = w;
    if (res.args.aspect) |a|        config.char_aspect = a;
    if (res.args.ramp) |r|          config.ramp = r;
    if (res.args.nocolor != 0)      config.use_color = false;
    if (res.args.noedges != 0)      config.display_edges = false;
    if (res.args.edgeweight) |r|    config.edge_weight = r;
    if (res.args.solid != 0)        config.use_solid = true;

    switch (config.validate(res.args)) {
        .message => |m| {
            std.debug.print("ERROR: Failed to validate Config: {s}\n", .{m});
            return;
        },
        else => { },
    }

    var stb_config: StbConfig = undefined;

    const pixels, stb_config = try loadImage(config);
    config.height = calculateHeight(config, stb_config);
    try print(alloc, pixels, config, stb_config);
}
