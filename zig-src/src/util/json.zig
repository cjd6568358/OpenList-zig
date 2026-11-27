//! Small, dependency-free JSON value / parser / serializer.
//!
//! Why not `std.json`? Two reasons:
//!   1. Churn. `std.json.stringify` became `std.json.Stringify.value`/`fmt`
//!      around 0.15, and `parseFromSliceLeaky` moved. Hand-rolling keeps the
//!      tree buildable on 0.14 .. 0.17 untouched.
//!   2. Key order. OpenList's frontend and the itvsh backend both care about
//!      field order in a few places, and an insertion-ordered object makes
//!      that explicit rather than incidental.
//!
//! All memory comes from the allocator passed in; typical use is a per-request
//! arena, so nothing here frees individual nodes.

const std = @import("std");
const Buf = @import("buf.zig").Buf;
const List = @import("buf.zig").List;

pub const ParseError = error{
    OutOfMemory,
    UnexpectedEnd,
    InvalidSyntax,
    InvalidNumber,
    InvalidEscape,
    DepthLimitExceeded,
};

pub const Object = struct {
    keys: [][]const u8 = &.{},
    vals: []Value = &.{},

    pub fn get(self: *const Object, key: []const u8) ?*const Value {
        for (self.keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return &self.vals[i];
        }
        return null;
    }

    pub fn len(self: *const Object) usize {
        return self.keys.len;
    }
};

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: []Value,
    object: Object,

    // ---------- accessors (lenient: they return null instead of erroring) ----------

    pub fn asStr(self: *const Value) ?[]const u8 {
        return switch (self.*) {
            .string => |s| s,
            else => null,
        };
    }

    /// Accepts `"123"` as well as `123`: several Chinese cloud APIs (itvsh
    /// included) flip between the two across endpoints.
    pub fn asInt(self: *const Value) ?i64 {
        return switch (self.*) {
            .int => |i| i,
            .float => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            .bool => |b| if (b) 1 else 0,
            else => null,
        };
    }

    pub fn asFloat(self: *const Value) ?f64 {
        return switch (self.*) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    pub fn asBool(self: *const Value) ?bool {
        return switch (self.*) {
            .bool => |b| b,
            .int => |i| i != 0,
            .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
            else => null,
        };
    }

    pub fn asArray(self: *const Value) ?[]Value {
        return switch (self.*) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asObject(self: *const Value) ?*const Object {
        return switch (self.*) {
            .object => |*o| o,
            else => null,
        };
    }

    /// Dotted lookup: `getPath(root, "data.errorCode")`.
    ///
    /// A segment that is all digits indexes into an array, so
    /// `"data.list.2.x"` reaches element 2 of `data.list` and then its `x`
    /// key. Object keys that happen to be numeric still work, because an
    /// object is tried first and an array only when the value really is one.
    pub fn getPath(self: *const Value, path: []const u8) ?*const Value {
        var cur: *const Value = self;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            switch (cur.*) {
                .object => |*o| cur = o.get(seg) orelse return null,
                .array => |arr| {
                    if (seg.len == 0) return null;
                    for (seg) |c| if (!std.ascii.isDigit(c)) return null;
                    const idx = std.fmt.parseInt(usize, seg, 10) catch return null;
                    if (idx >= arr.len) return null;
                    cur = &arr[idx];
                },
                else => return null,
            }
        }
        return cur;
    }

    pub fn strAt(self: *const Value, path: []const u8) ?[]const u8 {
        const v = self.getPath(path) orelse return null;
        return v.asStr();
    }

    pub fn intAt(self: *const Value, path: []const u8) ?i64 {
        const v = self.getPath(path) orelse return null;
        return v.asInt();
    }
};

// ---------------------------------------------------------------------------
// Builder — used both by the parser and by callers constructing request bodies
// ---------------------------------------------------------------------------

pub const Builder = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Builder {
        return .{ .alloc = alloc };
    }

    pub fn obj(self: Builder, entries: anytype) !Value {
        // entries: tuple of .{ "key", value } pairs
        var keys = List([]const u8).init(self.alloc);
        var vals = List(Value).init(self.alloc);
        inline for (entries) |e| {
            try keys.append(e[0]);
            try vals.append(e[1]);
        }
        return .{ .object = .{
            .keys = try keys.toOwned(),
            .vals = try vals.toOwned(),
        } };
    }

    pub fn arr(self: Builder, items: []const Value) !Value {
        return .{ .array = try self.alloc.dupe(Value, items) };
    }

    pub fn str(self: Builder, s: []const u8) !Value {
        return .{ .string = try self.alloc.dupe(u8, s) };
    }
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

pub fn parse(alloc: std.mem.Allocator, src: []const u8) ParseError!Value {
    var p = Parser{ .src = src, .alloc = alloc };
    p.skipWs();
    const v = try p.parseValue(0);
    p.skipWs();
    // Trailing garbage is a hard error: it usually means we got an HTML error
    // page from a WAF instead of JSON, and silently succeeding hides that.
    if (p.pos != src.len) return error.InvalidSyntax;
    return v;
}

/// Same, but tolerates trailing bytes. Use when a gateway appends a newline
/// or a debug trailer after the document.
pub fn parsePrefix(alloc: std.mem.Allocator, src: []const u8) ParseError!Value {
    var p = Parser{ .src = src, .alloc = alloc };
    p.skipWs();
    return p.parseValue(0);
}

pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,
    max_depth: usize = 64,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (self.peek() != c) return error.InvalidSyntax;
        self.pos += 1;
    }

    fn parseValue(self: *Parser, depth: usize) ParseError!Value {
        if (depth > self.max_depth) return error.DepthLimitExceeded;
        const c = self.peek() orelse return error.UnexpectedEnd;
        switch (c) {
            '{' => return self.parseObject(depth),
            '[' => return self.parseArray(depth),
            '"' => return .{ .string = try self.parseString() },
            't' => return self.parseLiteral("true", .{ .bool = true }),
            'f' => return self.parseLiteral("false", .{ .bool = false }),
            'n' => return self.parseLiteral("null", .null),
            '-', '0'...'9' => return self.parseNumber(),
            else => return error.InvalidSyntax,
        }
    }

    fn parseLiteral(self: *Parser, word: []const u8, v: Value) ParseError!Value {
        if (self.src.len - self.pos < word.len) return error.UnexpectedEnd;
        if (!std.mem.eql(u8, self.src[self.pos..][0..word.len], word)) return error.InvalidSyntax;
        self.pos += word.len;
        return v;
    }

    fn parseObject(self: *Parser, depth: usize) ParseError!Value {
        try self.expect('{');
        var keys = List([]const u8).init(self.alloc);
        var vals = List(Value).init(self.alloc);
        self.skipWs();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .object = .{ .keys = &.{}, .vals = &.{} } };
        }
        while (true) {
            self.skipWs();
            const k = try self.parseString();
            self.skipWs();
            try self.expect(':');
            self.skipWs();
            const v = try self.parseValue(depth + 1);
            try keys.append(k);
            try vals.append(v);
            self.skipWs();
            switch (self.peek() orelse return error.UnexpectedEnd) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => return error.InvalidSyntax,
            }
        }
        return .{ .object = .{
            .keys = try keys.toOwned(),
            .vals = try vals.toOwned(),
        } };
    }

    fn parseArray(self: *Parser, depth: usize) ParseError!Value {
        try self.expect('[');
        var items = List(Value).init(self.alloc);
        self.skipWs();
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .array = &.{} };
        }
        while (true) {
            self.skipWs();
            const v = try self.parseValue(depth + 1);
            try items.append(v);
            self.skipWs();
            switch (self.peek() orelse return error.UnexpectedEnd) {
                ',' => self.pos += 1,
                ']' => {
                    self.pos += 1;
                    break;
                },
                else => return error.InvalidSyntax,
            }
        }
        return .{ .array = try items.toOwned() };
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        try self.expect('"');
        var out = Buf.init(self.alloc);
        while (true) {
            const c = self.peek() orelse return error.UnexpectedEnd;
            self.pos += 1;
            switch (c) {
                '"' => break,
                '\\' => {
                    const e = self.peek() orelse return error.UnexpectedEnd;
                    self.pos += 1;
                    switch (e) {
                        '"' => try out.appendByte('"'),
                        '\\' => try out.appendByte('\\'),
                        '/' => try out.appendByte('/'),
                        'b' => try out.appendByte(0x08),
                        'f' => try out.appendByte(0x0c),
                        'n' => try out.appendByte('\n'),
                        'r' => try out.appendByte('\r'),
                        't' => try out.appendByte('\t'),
                        'u' => {
                            var cp = try self.parseHex4();
                            // AUDIT-2026-11-27 #9：孤立代理项一律映射为 U+FFFD
                            // （Go `encoding/json` 的语义）。旧代码把仍处于
                            // 代理项区间的码点直接 appendUtf8，产出 CESU-8 风格
                            // 的 3 字节序列——**不是合法 UTF-8**。上游 API 常用
                            // 截断的 emoji 转义（`\ud83d` 无后半），这样的字符串
                            // 一旦经驱动 persist → config.save 落盘，下次启动
                            // `config.load` 的 utf8Validate 就会把整个配置拒掉
                            // （历史「配置中毒拒启」故障链，见 config.zig 头注释）。
                            if (cp >= 0xD800 and cp <= 0xDBFF) {
                                // 后半必须「预消费前先验证」：只对真正的
                                // \uDC00-\uDFFF 才前进 6 字节，否则不吞任何输入
                                // （旧写法先 pos+=2 再 parseHex4，
                                // 「高代理后跟另一个高代理」时把第二个转义整个
                                // 吞掉且仍然输出非法序列）。
                                if (self.lookaheadLowSurrogate()) |lo| {
                                    self.pos += 6;
                                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                } else {
                                    cp = 0xFFFD;
                                }
                            } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                                // 孤立的低代理（前面没有高代理）。
                                cp = 0xFFFD;
                            }
                            try appendUtf8(&out, cp);
                        },
                        else => return error.InvalidEscape,
                    }
                },
                0x00...0x1f => return error.InvalidSyntax,
                else => try out.appendByte(c),
            }
        }
        return out.toOwned();
    }

    /// 预览当前位置是否是一个合法的低代理转义 `\uDC00-\uDFFF`。
    /// **不消费输入**（与 parseHex4 的差别）——只有确认是合法后半时调用方才
    /// 前进 6 字节（AUDIT #9，见 parseString 注释）。
    fn lookaheadLowSurrogate(self: *Parser) ?u16 {
        if (self.pos + 6 > self.src.len) return null;
        if (self.src[self.pos] != '\\' or self.src[self.pos + 1] != 'u') return null;
        const hex = self.src[self.pos + 2 ..][0..4];
        var v: u16 = 0;
        for (hex) |c| {
            const d: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            v = v * 16 + d;
        }
        if (v < 0xDC00 or v > 0xDFFF) return null;
        return v;
    }

    fn parseHex4(self: *Parser) ParseError!u21 {
        if (self.pos + 4 > self.src.len) return error.UnexpectedEnd;
        const s = self.src[self.pos..][0..4];
        self.pos += 4;
        var v: u21 = 0;
        for (s) |c| {
            const d: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidEscape,
            };
            v = v * 16 + d;
        }
        return v;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => self.pos += 1,
                else => break,
            }
        }
        const tok = self.src[start..self.pos];
        if (tok.len == 0) return error.InvalidNumber;
        if (std.mem.indexOfAny(u8, tok, ".eE") == null) {
            if (std.fmt.parseInt(i64, tok, 10)) |i| {
                return .{ .int = i };
            } else |_| {
                // Out of i64 range: fall back to float so huge ids still parse.
                return .{ .float = std.fmt.parseFloat(f64, tok) catch return error.InvalidNumber };
            }
        }
        return .{ .float = std.fmt.parseFloat(f64, tok) catch return error.InvalidNumber };
    }
};

/// Hand-rolled rather than `std.unicode.utf8Encode`: that function's signature
/// changed from `out: []u8` to `out: *[4]u8` in 0.15.
fn appendUtf8(out: *Buf, cp: u21) ParseError!void {
    var b: [4]u8 = undefined;
    var n: usize = 0;
    if (cp < 0x80) {
        b[0] = @intCast(cp);
        n = 1;
    } else if (cp < 0x800) {
        b[0] = @intCast(0xC0 | (cp >> 6));
        b[1] = @intCast(0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp < 0x10000) {
        b[0] = @intCast(0xE0 | (cp >> 12));
        b[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        b[2] = @intCast(0x80 | (cp & 0x3F));
        n = 3;
    } else {
        b[0] = @intCast(0xF0 | (cp >> 18));
        b[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        b[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        b[3] = @intCast(0x80 | (cp & 0x3F));
        n = 4;
    }
    try out.append(b[0..n]);
}

// ---------------------------------------------------------------------------
// Serializer
// ---------------------------------------------------------------------------

pub fn stringify(alloc: std.mem.Allocator, v: *const Value) ![]u8 {
    var b = Buf.init(alloc);
    try write(&b, v);
    return b.toOwned();
}

pub fn write(b: *Buf, v: *const Value) !void {
    switch (v.*) {
        .null => try b.append("null"),
        .bool => |x| try b.append(if (x) "true" else "false"),
        .int => |x| try b.print("{d}", .{x}),
        .float => |x| try writeFloat(b, x),
        .string => |s| try writeString(b, s),
        .array => |a| {
            try b.appendByte('[');
            for (a, 0..) |*it, i| {
                if (i != 0) try b.appendByte(',');
                try write(b, it);
            }
            try b.appendByte(']');
        },
        .object => |*o| {
            try b.appendByte('{');
            for (o.keys, o.vals, 0..) |k, *val, i| {
                if (i != 0) try b.appendByte(',');
                try writeString(b, k);
                try b.appendByte(':');
                try write(b, val);
            }
            try b.appendByte('}');
        },
    }
}

/// JSON has no integer/float distinction on the wire, but `{d}` on a float
/// prints `3` for 3.0 which is fine, and `1e10` for large values which is not
/// what most consumers expect. Emit integral floats without an exponent.
fn writeFloat(b: *Buf, x: f64) !void {
    if (std.math.isNan(x) or std.math.isInf(x)) return b.append("null");
    if (x == @trunc(x) and @abs(x) < 1e15) {
        return b.print("{d}", .{@as(i64, @intFromFloat(x))});
    }
    try b.print("{d}", .{x});
}

pub fn writeString(b: *Buf, s: []const u8) !void {
    try b.appendByte('"');
    // AUDIT-2026-11-27 #9：无效 UTF-8 字节序列写出为 U+FFFD（对齐 Go
    // `encoding/json.Marshal` 的字符串编码行为）。旧实现原样透传，非法字节
    // （如上游返回的断头 emoji / GBK 混入）会直接落进 JSON 响应与 config 落盘
    // ——前者让前端 JSON.parse 失败，后者把 config.json 变成 utf8Validate
    // 拒收的形状（拒启）。
    //
    // 处理粒度与 Go 一致：每个非法字节一枚 FFFD、前进一步；合法多字节序列
    // 原样通过。ASCII 快路径不受影响。
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => {
                try b.append("\\\"");
                i += 1;
            },
            '\\' => {
                try b.append("\\\\");
                i += 1;
            },
            '\n' => {
                try b.append("\\n");
                i += 1;
            },
            '\r' => {
                try b.append("\\r");
                i += 1;
            },
            '\t' => {
                try b.append("\\t");
                i += 1;
            },
            0x08 => {
                try b.append("\\b");
                i += 1;
            },
            0x0c => {
                try b.append("\\f");
                i += 1;
            },
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try b.print("\\u{x:0>4}", .{c});
                i += 1;
            },
            // ASCII 快路径（避开上面已处理的 " 与 \）。
            0x20...0x21, 0x23...0x5b, 0x5d...0x7f => {
                try b.appendByte(c);
                i += 1;
            },
            else => {
                const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
                    try b.append("\xEF\xBF\xBD");
                    i += 1;
                    continue;
                };
                // 截断的尾序列或内容非法（过度编码 / 非法代理 / 坏的续字节）
                // → 一枚 FFFD、前进一字节。
                if (i + seq_len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + seq_len])) {
                    try b.append("\xEF\xBF\xBD");
                    i += 1;
                    continue;
                }
                try b.append(s[i .. i + seq_len]);
                i += seq_len;
            },
        }
    }
    try b.appendByte('"');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse nested object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\{"code":200,"data":{"errorCode":"0","list":[1,2,{"x":"y"}]},"ok":true,"n":null}
    ;
    const v = try parse(arena.allocator(), src);
    try testing.expectEqual(@as(i64, 200), v.intAt("code").?);
    try testing.expectEqualStrings("0", v.strAt("data.errorCode").?);
    try testing.expectEqual(@as(i64, 2), v.getPath("data.list").?.asArray().?[1].asInt().?);
    try testing.expectEqualStrings("y", v.strAt("data.list.2.x").?);
    try testing.expect(v.getPath("ok").?.asBool().?);
    try testing.expect(v.getPath("n").?.* == .null);
}

test "string escapes and surrogate pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "\"a\\nb\\u00e9\\ud83d\\ude00\"");
    try testing.expectEqualStrings("a\nb\u{00e9}\u{1F600}", v.asStr().?);
}

test "AUDIT #9: unpaired surrogates decode to U+FFFD, never invalid UTF-8" {
    // 历史故障链：上游返回截断的 emoji 转义（\ud83d 无后半）→ 旧解析器产出
    // CESU-8 风格 3 字节非法序列 → 驱动 persist → config.save 原样落盘 →
    // 下次启动 config.load 的 utf8Validate 拒收 → 服务拒启。两处都必须堵死：
    // 解析侧（\u 转义）与写出侧（writeString 消毒）。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ① 孤立高代理（截断 emoji 的常见形态）。
    const t1 = try parse(a, "\"\\ud83d\"");
    try testing.expectEqualStrings("\u{FFFD}", t1.asStr().?);
    // ② 孤立低代理。
    const t2 = try parse(a, "\"\\ude00\"");
    try testing.expectEqualStrings("\u{FFFD}", t2.asStr().?);
    // ③ 高代理后跟另一个高代理再跟合法低代理：第一个 → FFFD，后两个配对。
    const t3 = try parse(a, "\"\\ud83d\\ud83d\\ude00\"");
    try testing.expectEqualStrings("\u{FFFD}\u{1F600}", t3.asStr().?);
    // 对拆开写也是同理（转义与裸字符混合）。
    // ④ 转义出的配对不受影响。
    const t4 = try parse(a, "\"\\ud83d\\ude00\"");
    try testing.expectEqualStrings("\u{1F600}", t4.asStr().?);

    // ⑤ 原始非法字节（不经 \u 转义直接混入）：解析层原样保留（宽松），
    // 但 writeString 必须消毒 —— 这正是「配置中毒」的另一半防线。
    // 粒度与 Go `encoding/json` 一致：每个非法字节一枚 FFFD（Go 的
    // DecodeRune 对非法序列恒返回 size=1）。
    const raw = "\xED\xA0\x80-end"; // CESU-8 风格的高代理字节
    var b = Buf.init(a);
    try writeString(&b, raw);
    try testing.expectEqualStrings("\"\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD-end\"", b.slice());
    // 截断的 3 字节序列尾部：头字节一枚 + 残余续字节一枚。
    var b2 = Buf.init(a);
    try writeString(&b2, "ab\xE4\xB8");
    try testing.expectEqualStrings("\"ab\xEF\xBF\xBD\xEF\xBF\xBD\"", b2.slice());

    // ⑥ 端到端：包含孤立代理的输入，parse → stringify 回写必须得到合法 UTF-8。
    const bad = try parse(a, "\"x\\ud83dy\\ude4Az\"");
    const out = try stringify(a, &bad);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "lenient int from string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"size\":\"1048576\"}");
    try testing.expectEqual(@as(i64, 1048576), v.intAt("size").?);
}

test "rejects trailing garbage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidSyntax, parse(arena.allocator(), "{}<html>"));
}

test "roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\"a\":[1,2.5,\"x\\ny\"],\"b\":true,\"c\":null}";
    const v = try parse(a, src);
    const out = try stringify(a, &v);
    const v2 = try parse(a, out);
    try testing.expectEqualStrings(src, try stringify(a, &v2));
}
