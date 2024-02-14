const Parser = @This();
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const std = @import("std");
const assert = std.debug.assert;

gpa: std.mem.Allocator,
code: [:0]const u8,
opts: ParseOptions,
tokenizer: Tokenizer = .{},
parents: std.ArrayListUnmanaged(Container) = .{},
container: Container = .start,
state: State = .start,

pub const ParseOptions = struct {
    diagnostics: ?*Diagnostics = null,
    copy_strings: CopyStrings = .always,

    pub const CopyStrings = enum {
        to_unescape,
        always,
    };
};

pub const Diagnostics = struct {
    /// The data being parsed.
    code: []const u8,
    /// A path to the file, used to display diagnostics.
    /// If not present, error positions will be printed as "line: XX col: XX".
    path: ?[]const u8,

    tok: Token = .{
        .tag = .eof,
        .loc = .{ .start = 0, .end = 0 },
    },
    err: union(enum) {
        none,
        out_of_memory,
        eof: struct {
            expected: []const Token.Tag,
        },
        unexpected_token: struct {
            expected: []const Token.Tag,
        },
        syntax_error,
        duplicate_field: struct {
            name: []const u8,
            first_loc: Token.Loc,
        },
        missing_field: struct {
            name: []const u8,
        },
        unknown_field: struct {
            name: []const u8,
        },
    } = .none,

    pub fn debug(self: Diagnostics) void {
        std.debug.print("{}", .{self});
    }

    pub fn format(
        self: Diagnostics,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        const start = self.tok.loc.getSelection(self.code).start;
        if (self.path) |p| {
            try out_stream.print("{s}:{}:{}\n", .{
                p,
                start.line,
                start.col,
            });
        } else {
            try out_stream.print("line: {} col: {}\n", .{
                start.line,
                start.col,
            });
        }

        switch (self.err) {
            .none => {},
            .syntax_error => @panic("TODO"),
            .out_of_memory => {
                try out_stream.print("OutOfMemory\n", .{});
            },
            .eof => |eof| {
                try out_stream.print("unexpected EOF, expected: ", .{});

                for (eof.expected, 0..) |tag, idx| {
                    try out_stream.print("'{s}'", .{tag.lexeme()});
                    if (idx != eof.expected.len - 1) {
                        try out_stream.print(" or ", .{});
                    }
                }

                try out_stream.print("\n", .{});
            },
            .unexpected_token => |u| {
                if (self.tok.tag == .eof) {
                    try out_stream.print("unexpected EOF, expected: ", .{});
                } else {
                    try out_stream.print("unexpected token: '{s}', expected: ", .{
                        self.tok.loc.src(self.code),
                    });
                }

                for (u.expected, 0..) |tag, idx| {
                    try out_stream.print("'{s}'", .{tag.lexeme()});
                    if (idx != u.expected.len - 1) {
                        try out_stream.print(" or ", .{});
                    }
                }

                try out_stream.print("\n", .{});
            },
            .duplicate_field => |dup| {
                const first_sel = dup.first_loc.getSelection(self.code);
                try out_stream.print("found duplicate field '{s}', first definition here:", .{
                    dup.name,
                });
                if (self.path) |p| {
                    try out_stream.print("\n{s}:{}:{}\n", .{
                        p,
                        first_sel.start.line,
                        first_sel.start.col,
                    });
                } else {
                    try out_stream.print(" line: {} col: {}\n", .{
                        first_sel.start.line,
                        first_sel.start.col,
                    });
                }
            },
            .missing_field => |miss| {
                const struct_end = self.tok.loc.getSelection(self.code);
                try out_stream.print(
                    "missing field '{s}', struct ends here:",
                    .{miss.name},
                );
                if (self.path) |p| {
                    try out_stream.print("\n{s}:{}:{}\n", .{
                        p,
                        struct_end.start.line,
                        struct_end.start.col,
                    });
                } else {
                    try out_stream.print(" line: {} col: {}\n", .{
                        struct_end.start.line,
                        struct_end.start.col,
                    });
                }
            },
            .unknown_field => |un| {
                const selection = self.tok.loc.getSelection(self.code);
                try out_stream.print(
                    "unknown field '{s}' found here:",
                    .{un.name},
                );
                if (self.path) |p| {
                    try out_stream.print("\n{s}:{}:{}\n", .{
                        p,
                        selection.start.line,
                        selection.start.col,
                    });
                } else {
                    try out_stream.print(" line: {} col: {}\n", .{
                        selection.start.line,
                        selection.start.col,
                    });
                }
            },
        }
    }
};

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    MissingField,
    DuplicateField,
    UnknownField,
    Syntax,
};

const Container = enum {
    start,
    @"struct",
    dyn,
    array,
};

const State = enum {
    start,
    struct_lb_or_comma,
    field_dot,
};

pub fn parse(
    comptime T: type,
    gpa: std.mem.Allocator,
    code: [:0]const u8,
    opts: ParseOptions,
) ParseError!T {
    var parser: Parser = .{ .gpa = gpa, .code = code, .opts = opts };
    var result: T = undefined;

    const info = @typeInfo(T);

    switch (info) {
        .Struct => {
            try parser.parseStruct(T, &result, parser.next());
        },

        else => try parser.parseValue(T, &result, parser.next()),
    }

    const extra = parser.next();
    if (extra.tag != .eof) {
        if (opts.diagnostics) |d| {
            d.tok = extra;
            d.err = .{
                .unexpected_token = .{
                    .expected = &.{.eof},
                },
            };
        }

        return error.UnexpectedToken;
    }

    return result;
}

fn parseValue(
    self: *Parser,
    comptime T: type,
    val: *T,
    first_tok: Token,
) ParseError!void {
    const info = @typeInfo(T);

    switch (info) {
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => switch (ptr.child) {
                u8 => try self.parseBytes(T, val, first_tok),
                else => try self.parseArray(T, val, first_tok),
            },
            else => @compileError("TODO"),
        },
        .Bool => try self.parseBool(val, first_tok),
        .Int => try self.parseInt(T, val, first_tok),
        .Float => try self.parseFloat(T, val, first_tok),
        .Struct => {
            try self.must(first_tok.lb);
            return self.parseStruct(T, val, first_tok);
        },
        else => @compileError("TODO"),
    }
}
fn parseStruct(
    self: *Parser,
    comptime T: type,
    val: *T,
    first_tok: Token,
) ParseError!void {
    // When a top-level struct omits curlies, the first
    // token will be a dot. Is such case we don't want
    // to expect a closing right bracket.
    const need_closing_rb = first_tok.tag == .lb;
    const info = @typeInfo(T).Struct;

    var tok = first_tok;
    if (first_tok.tag == .lb) {
        tok = self.next();
    }

    // TODO: optimization: turn this into an array of bools when
    //       diagnocstics are disabled
    var fields_seen = [_]?Token.Loc{null} ** info.fields.len;
    while (true) {
        if (need_closing_rb) {
            try self.mustAny(tok, &.{ .dot, .rb });
        } else {
            try self.mustAny(tok, &.{ .dot, .rb, .eof });
        }

        if (tok.tag != .dot) {
            return self.finalizeStruct(
                T,
                info,
                val,
                &fields_seen,
                tok,
            );
        }

        // we found the start of a field
        assert(tok.tag == .dot);

        const ident = try self.nextMust(.ident);
        _ = try self.nextMust(.eql);
        const field_name = ident.loc.src(self.code);
        inline for (info.fields, 0..) |f, idx| {
            if (std.mem.eql(u8, f.name, field_name)) {
                if (fields_seen[idx]) |first_loc| {
                    if (self.opts.diagnostics) |d| {
                        d.tok = ident;
                        d.err = .{
                            .duplicate_field = .{
                                .name = f.name,
                                .first_loc = first_loc,
                            },
                        };
                    }
                    return error.DuplicateField;
                }
                fields_seen[idx] = ident.loc;
                try self.parseValue(f.type, &@field(val, f.name), self.next());
                break;
            }
        } else {
            if (self.opts.diagnostics) |d| {
                d.tok = ident;
                d.err = .{
                    .unknown_field = .{
                        .name = field_name,
                    },
                };
            }
            return error.UnknownField;
        }

        tok = self.next();
        switch (tok.tag) {
            .comma => tok = self.next(),
            .dot => try self.must(tok, .comma),
            else => {},
        }
    }
}

// TODO: allocate memory to copy fields_seen and pass it all to diagnostics
fn finalizeStruct(
    self: *Parser,
    comptime T: type,
    info: std.builtin.Type.Struct,
    val: *T,
    fields_seen: []const ?Token.Loc,
    struct_end: Token,
) ParseError!void {
    inline for (info.fields, 0..) |field, idx| {
        if (fields_seen[idx] == null) {
            if (field.default_value) |ptr| {
                const dv_ptr: *field.type = @ptrCast(ptr);
                @field(val, field.name) = dv_ptr.*;
            } else {
                if (self.opts.diagnostics) |d| {
                    d.tok = struct_end;
                    d.err = .{
                        .missing_field = .{
                            .name = field.name,
                        },
                    };
                }
                return error.MissingField;
            }
        }
    }
}

fn parseBool(self: *Parser, val: *bool, ident: Token) !void {
    try self.must(ident, .ident);

    const src = ident.loc.src(self.code);
    if (std.mem.eql(u8, src, "true")) {
        val.* = true;
    } else if (std.mem.eql(u8, src, "false")) {
        val.* = false;
    } else {
        if (self.opts.diagnostics) |d| {
            d.tok = ident;
            d.err = .{
                .unexpected_token = .{
                    .expected = &.{ .true, .false },
                },
            };
        }

        return error.UnexpectedToken;
    }
}

fn parseInt(self: *Parser, comptime T: type, val: *T, num: Token) !void {
    assert(@typeInfo(T) == .Int);

    try self.must(num, .number);
    val.* = std.fmt.parseInt(T, num.loc.src(self.code), 10) catch {
        if (self.opts.diagnostics) |d| {
            d.tok = num;
            d.err = .syntax_error;
        }
        return error.Syntax;
    };
}

fn parseFloat(self: *Parser, comptime T: type, val: *T, num: Token) !void {
    assert(@typeInfo(T) == .Float);

    try self.must(num, .number);
    val.* = std.fmt.parseFloat(T, num.loc.src(self.code)) catch {
        if (self.opts.diagnostics) |d| {
            d.tok = num;
            d.err = .syntax_error;
        }
        return error.Syntax;
    };
}

fn parseBytes(self: *Parser, comptime T: type, val: *T, str_or_at: Token) !void {
    try self.mustAny(str_or_at, &.{ .str, .at });

    const str = switch (str_or_at.tag) {
        .str => str_or_at,
        .at => blk: {
            _ = try self.nextMust(.ident);
            _ = try self.nextMust(.lp);
            const str = try self.nextMust(.str);
            _ = try self.nextMust(.rp);
            break :blk str;
        },
        else => unreachable,
    };

    val.* = str.loc.unquote(self.code) orelse @panic("TODO");
}

fn parseArray(self: *Parser, comptime T: type, val: *T, lsb: Token) !void {
    const info = @typeInfo(T).Pointer;
    assert(info.size == .Slice);

    try self.must(lsb, .lsb);

    var tok = self.next();
    var list: std.ArrayListUnmanaged(info.child) = .{};
    errdefer list.deinit(self.gpa);
    while (true) {
        if (tok.tag == .rsb) {
            val.* = try list.toOwnedSlice(self.gpa);
            return;
        }

        const next_item = try list.addOne(self.gpa);
        try self.parseValue(info.child, next_item, tok);

        tok = try self.nextMustAny(&.{ .comma, .rsb });
        if (tok.tag == .comma) {
            tok = self.next();
        }
    }
}

pub fn next(self: *Parser) Token {
    return self.tokenizer.next(self.code);
}

pub fn nextMust(self: *Parser, comptime tag: Token.Tag) !Token {
    return self.nextMustAny(&.{tag});
}

pub fn nextMustAny(
    self: *Parser,
    comptime tags: []const Token.Tag,
) !Token {
    const next_tok = self.next();
    try self.mustAny(next_tok, tags);
    return next_tok;
}

pub fn must(
    self: *Parser,
    tok: Token,
    comptime tag: Token.Tag,
) !void {
    return self.mustAny(tok, &.{tag});
}

pub fn mustAny(
    self: *Parser,
    tok: Token,
    comptime tags: []const Token.Tag,
) !void {
    for (tags) |t| {
        if (t == tok.tag) break;
    } else {
        if (self.opts.diagnostics) |d| {
            d.tok = tok;
            d.err = .{
                .unexpected_token = .{
                    .expected = tags,
                },
            };
        }

        return error.UnexpectedToken;
    }
}

test "struct - basics" {
    const case =
        \\.foo = "bar",
        \\.bar = false,
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    const c = try parse(Case, std.testing.allocator, case, .{});
    try std.testing.expectEqualStrings("bar", c.foo);
    try std.testing.expectEqual(false, c.bar);
}

test "struct - top level curlies" {
    const case =
        \\{
        \\   .foo = "bar",
        \\   .bar = false,
        \\}
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    const c = try parse(Case, std.testing.allocator, case, .{});
    try std.testing.expectEqualStrings("bar", c.foo);
    try std.testing.expectEqual(false, c.bar);
}

test "struct - missing bottom curly" {
    const case =
        \\{
        \\   .foo = "bar",
        \\   .bar = false,
        \\
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = parse(Case, std.testing.allocator, case, opts);
    try std.testing.expectError(error.UnexpectedToken, result);
    try std.testing.expectFmt(
        \\line: 3 col: 17
        \\unexpected EOF, expected: '.' or '}'
        \\
    , "{}", .{diag});
}

test "struct - syntax error" {
    const case =
        \\.foo = "bar",
        \\.bar = .false,
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = parse(Case, std.testing.allocator, case, opts);
    try std.testing.expectError(error.UnexpectedToken, result);
    try std.testing.expectFmt(
        \\line: 2 col: 8
        \\unexpected token: '.', expected: '(identifier)'
        \\
    , "{}", .{diag});
}

test "struct - missing comma" {
    const case =
        \\.foo = "bar"
        \\.bar = false,
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = parse(Case, std.testing.allocator, case, opts);
    try std.testing.expectError(error.UnexpectedToken, result);
    try std.testing.expectFmt(
        \\line: 2 col: 1
        \\unexpected token: '.', expected: ','
        \\
    , "{}", .{diag});
}
test "struct - optional comma" {
    const case =
        \\.foo = "bar",
        \\.bar = false
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    const c = try parse(Case, std.testing.allocator, case, .{});
    try std.testing.expectEqualStrings("bar", c.foo);
    try std.testing.expectEqual(false, c.bar);
}

test "struct - missing field" {
    const case =
        \\.foo = "bar",
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = parse(Case, std.testing.allocator, case, opts);
    try std.testing.expectError(error.MissingField, result);
    try std.testing.expectFmt(
        \\line: 1 col: 13
        \\missing field 'bar', struct ends here: line: 1 col: 13
        \\
    , "{}", .{diag});
}

test "struct - duplicate field" {
    const case =
        \\.foo = "bar",
        \\.bar = false,
        \\.foo = "bar",
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = parse(Case, std.testing.allocator, case, opts);
    try std.testing.expectError(error.DuplicateField, result);
    try std.testing.expectFmt(
        \\line: 3 col: 2
        \\found duplicate field 'foo', first definition here: line: 1 col: 2
        \\
    , "{}", .{diag});
}

test "struct - unknown field" {
    const case =
        \\.foo = "bar",
        \\.bar = false,
        \\.baz = "oops",
    ;

    const Case = struct {
        foo: []const u8,
        bar: bool,
    };

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = parse(Case, std.testing.allocator, case, opts);
    try std.testing.expectError(error.UnknownField, result);
    try std.testing.expectFmt(
        \\line: 3 col: 2
        \\unknown field 'baz' found here: line: 3 col: 2
        \\
    , "{}", .{diag});
}

test "string" {
    const case =
        \\
        \\ "foo"
        \\
    ;

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = try parse([]const u8, std.testing.allocator, case, opts);
    try std.testing.expectEqualStrings("foo", result);
}

test "custom string literal" {
    const case =
        \\
        \\ @date("2020-07-06T00:00:00")
        \\
    ;

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = try parse([]const u8, std.testing.allocator, case, opts);
    try std.testing.expectEqualStrings("2020-07-06T00:00:00", result);
}

test "int basics" {
    const case =
        \\
        \\ 1042
        \\
    ;

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = try parse(usize, std.testing.allocator, case, opts);
    try std.testing.expectEqual(1042, result);
}

test "float basics" {
    const case =
        \\
        \\ 10.42
        \\
    ;

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = try parse(f64, std.testing.allocator, case, opts);
    try std.testing.expectEqual(10.42, result);
}

test "array basics" {
    const case =
        \\
        \\ [1, 2, 3] 
        \\
    ;

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = try parse([]usize, std.testing.allocator, case, opts);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, result);
}

test "array trailing comma" {
    const case =
        \\
        \\ [1, 2, 3, ] 
        \\
    ;

    var diag: Diagnostics = .{ .code = case, .path = null };
    const opts: ParseOptions = .{ .diagnostics = &diag };

    const result = try parse([]usize, std.testing.allocator, case, opts);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, result);
}