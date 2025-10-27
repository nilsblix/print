const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("stb_image.h");
});
const clap = @import("clap");

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
        // Luma approximation (no alpha): Rec. 709
        const rf = @as(f32, @floatFromInt(self.r));
        const gf = @as(f32, @floatFromInt(self.g));
        const bf = @as(f32, @floatFromInt(self.b));
        return 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;
    }


    pub fn toSgr(self: Color, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "38;2;{d};{d};{d}", .{self.r, self.g, self.b});
    }
};

const Pixels = struct {
    items: []Color,
    width: usize,
    height: usize,

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
};

const Config = struct {
    path: []const u8,
    width: usize        = 80,
    height: usize       = 40,
    char_aspect: f32    = 2.0,
    ramp: []const u8    = " .-=+*#&@",
    use_color: bool     = true,
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

fn print(alloc: Allocator, pixels: Pixels, config: Config, stb_config: StbConfig) !void {
    const capacity = config.width * config.height;
    var list = try std.ArrayList(Color).initCapacity(alloc, capacity);
    defer list.deinit(alloc);

    try list.resize(alloc, capacity);

    const terminal = try createTerminalPixels(&list.items, pixels, config, stb_config);

    for (terminal.items, 0..) |px, idx| {
        const brightness = px.brightness();
        const max_brightness = 255.0; // Luma brightness
        const clamped = if (brightness < 0.0) 0.0 else if (brightness > max_brightness) max_brightness else brightness;
        const normalized = clamped / max_brightness;
        const ramp_pos = normalized * @as(f32, @floatFromInt(config.ramp.len - 1));
        const ch = config.ramp[@as(usize, @intFromFloat(@floor(ramp_pos)))];

        if (config.use_color) {
            const sgr = try px.toSgr(alloc);
            std.debug.print("\x1b[{s}m{c}\x1b[39m", .{sgr, ch});
        } else {
            std.debug.print("{c}", .{ch});
        }

        if (idx % terminal.width == 0) {
            std.debug.print("\n", .{});
        }
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-w, --width <usize>        Output width in characters.
        \\-a, --aspect <f32>         Character aspect ratio (height/width). Defaults to 2.0.
        \\--ramp <str>               The character rampt to use when defining brightness.
        \\-n, --nocolor              Do not use colors.
        \\--path <str>               Path to the image that should be printed.
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

    if (res.args.path) |p| {
        config.path = p;
    } else {
        std.debug.print("ERROR: No path was supplied.\n", .{});
        return;
    }

    if (res.args.width)     |w| config.width = w;
    if (res.args.aspect)    |a| config.char_aspect = a;
    if (res.args.ramp)      |r| config.ramp = r;
    if (res.args.nocolor != 0)  config.use_color = false;

    var stb_config: StbConfig = undefined;

    const pixels, stb_config = try loadImage(config);
    config.height = calculateHeight(config, stb_config);
    try print(alloc, pixels, config, stb_config);
}
