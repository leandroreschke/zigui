const std = @import("std");

const LanguageEntry = struct {
    code: [3]u8,
    tag: [4]u8,
};

const AliasEntry = struct {
    code: [2]u8,
    tag: [4]u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.InvalidArguments;

    const html = try std.Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(4 * 1024 * 1024));
    const csv = try std.Io.Dir.cwd().readFileAlloc(io, args[2], allocator, .limited(4 * 1024 * 1024));

    var languages: std.ArrayList(LanguageEntry) = .empty;
    try parseOpenTypeRegistry(allocator, html, &languages);
    std.mem.sort(LanguageEntry, languages.items, {}, lessLanguage);

    var aliases: std.ArrayList(AliasEntry) = .empty;
    try parseIsoAliases(allocator, csv, languages.items, &aliases);
    try appendAlias(&aliases, allocator, "no".*, findLanguage(languages.items, "nob".*) orelse "NOR ".*);
    try appendAlias(&aliases, allocator, "iw".*, findLanguage(languages.items, "heb".*) orelse "IWR ".*);
    try appendAlias(&aliases, allocator, "in".*, findLanguage(languages.items, "ind".*) orelse "IND ".*);
    try appendAlias(&aliases, allocator, "ji".*, findLanguage(languages.items, "yid".*) orelse "JII ".*);
    try appendAlias(&aliases, allocator, "mo".*, "MOL ".*);
    try appendAlias(&aliases, allocator, "sh".*, "SRB ".*);
    std.mem.sort(AliasEntry, aliases.items, {}, lessAlias);

    var output: std.Io.Writer.Allocating = .init(allocator);
    try emit(&output.writer, languages.items, aliases.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = output.written() });
}

fn parseOpenTypeRegistry(
    allocator: std.mem.Allocator,
    html: []const u8,
    output: *std.ArrayList(LanguageEntry),
) !void {
    var cursor = std.mem.indexOf(u8, html, "<th>Language system tag</th>") orelse return error.InvalidRegistry;
    while (std.mem.indexOfPos(u8, html, cursor, "<tr>")) |row_start| {
        const row_end = std.mem.indexOfPos(u8, html, row_start, "</tr>") orelse return error.InvalidRegistry;
        cursor = row_end + 5;
        const row = html[row_start..cursor];
        var cell_cursor: usize = 0;
        _ = nextCell(row, &cell_cursor) orelse continue;
        const tag_cell = nextCell(row, &cell_cursor) orelse continue;
        const ids_cell = nextCell(row, &cell_cursor) orelse continue;
        const tag = parseTag(tag_cell) orelse continue;

        var index: usize = 0;
        while (index + 3 <= ids_cell.len) : (index += 1) {
            if (!isLower(ids_cell[index]) or !isLower(ids_cell[index + 1]) or !isLower(ids_cell[index + 2])) continue;
            if (index != 0 and isLower(ids_cell[index - 1])) continue;
            if (index + 3 < ids_cell.len and isLower(ids_cell[index + 3])) continue;
            const code: [3]u8 = ids_cell[index..][0..3].*;
            if (findLanguage(output.items, code) == null)
                try output.append(allocator, .{ .code = code, .tag = tag });
            index += 2;
        }
    }
    if (output.items.len < 300) return error.InvalidRegistry;
}

fn nextCell(row: []const u8, cursor: *usize) ?[]const u8 {
    const start_tag = std.mem.indexOfPos(u8, row, cursor.*, "<td>") orelse return null;
    const start = start_tag + 4;
    const end = std.mem.indexOfPos(u8, row, start, "</td>") orelse return null;
    cursor.* = end + 5;
    return row[start..end];
}

fn parseTag(cell: []const u8) ?[4]u8 {
    if (std.mem.indexOfScalar(u8, cell, '\'')) |quote| {
        if (quote + 5 < cell.len and cell[quote + 5] == '\'') return cell[quote + 1 ..][0..4].*;
    }
    var index: usize = 0;
    while (index + 4 <= cell.len) : (index += 1) {
        var valid = true;
        for (cell[index..][0..4]) |byte| valid = valid and ((byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9'));
        if (valid) return cell[index..][0..4].*;
    }
    return null;
}

fn parseIsoAliases(
    allocator: std.mem.Allocator,
    csv: []const u8,
    languages: []const LanguageEntry,
    output: *std.ArrayList(AliasEntry),
) !void {
    var lines = std.mem.splitScalar(u8, csv, '\n');
    _ = lines.next();
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n");
        if (line.len == 0) continue;
        var fields: [3][]const u8 = .{ "", "", "" };
        var field_count: usize = 0;
        var cursor: usize = 0;
        while (field_count < fields.len) : (field_count += 1) {
            if (cursor >= line.len or line[cursor] != '\"') break;
            cursor += 1;
            const end = std.mem.indexOfScalarPos(u8, line, cursor, '\"') orelse return error.InvalidRegistry;
            fields[field_count] = line[cursor..end];
            cursor = end + 1;
            if (cursor < line.len and line[cursor] == ',') cursor += 1;
        }
        if (field_count != fields.len or fields[2].len != 2) continue;
        const primary = if (fields[1].len == 3) fields[1] else fields[0];
        if (primary.len != 3) continue;
        const tag = findLanguage(languages, primary[0..3].*) orelse
            findLanguage(languages, fields[0][0..3].*) orelse continue;
        try appendAlias(output, allocator, fields[2][0..2].*, tag);
    }
}

fn appendAlias(output: *std.ArrayList(AliasEntry), allocator: std.mem.Allocator, code: [2]u8, tag: [4]u8) !void {
    for (output.items) |entry| if (std.mem.eql(u8, &entry.code, &code)) return;
    try output.append(allocator, .{ .code = code, .tag = tag });
}

fn findLanguage(entries: []const LanguageEntry, code: [3]u8) ?[4]u8 {
    for (entries) |entry| if (std.mem.eql(u8, &entry.code, &code)) return entry.tag;
    return null;
}

fn isLower(byte: u8) bool {
    return byte >= 'a' and byte <= 'z';
}

fn lessLanguage(_: void, left: LanguageEntry, right: LanguageEntry) bool {
    return std.mem.order(u8, &left.code, &right.code) == .lt;
}

fn lessAlias(_: void, left: AliasEntry, right: AliasEntry) bool {
    return std.mem.order(u8, &left.code, &right.code) == .lt;
}

fn emit(writer: *std.Io.Writer, languages: []const LanguageEntry, aliases: []const AliasEntry) !void {
    try writer.writeAll(
        \\//! Generated from the OpenType 1.9.1 language-system registry and
        \\//! ISO 639 aliases. Regenerate with tools/generate_opentype_languages.zig.
        \\const std = @import("std");
        \\
        \\const LanguageEntry = struct { code: [3]u8, tag: [4]u8 };
        \\const AliasEntry = struct { code: [2]u8, tag: [4]u8 };
        \\
    );
    try writer.writeAll("const languages = [_]LanguageEntry{\n");
    for (languages) |entry| try writer.print("    .{{ .code = \"{s}\".*, .tag = \"{s}\".* }},\n", .{ &entry.code, &entry.tag });
    try writer.writeAll("};\n\nconst aliases = [_]AliasEntry{\n");
    for (aliases) |entry| try writer.print("    .{{ .code = \"{s}\".*, .tag = \"{s}\".* }},\n", .{ &entry.code, &entry.tag });
    try writer.writeAll(
        \\};
        \\
        \\pub fn tag(locale: []const u8) [4]u8 {
        \\    const primary = primarySubtag(locale);
        \\    if (primary.len == 0) return "dflt".*;
        \\    if (hasSubtag(locale, "fonipa")) return "IPPH".*;
        \\    if (hasSubtag(locale, "fonnapa")) return "APPH".*;
        \\    if (equal(primary, "zh") or equal(primary, "zho")) return chineseTag(locale);
        \\    if (primary.len == 2) {
        \\        const key: [2]u8 = .{ std.ascii.toLower(primary[0]), std.ascii.toLower(primary[1]) };
        \\        if (binaryAlias(key)) |value| return value;
        \\    } else if (primary.len == 3) {
        \\        const key: [3]u8 = .{ std.ascii.toLower(primary[0]), std.ascii.toLower(primary[1]), std.ascii.toLower(primary[2]) };
        \\        if (binaryLanguage(key)) |value| return value;
        \\    }
        \\    return "dflt".*;
        \\}
        \\
        \\fn chineseTag(locale: []const u8) [4]u8 {
        \\    if (hasSubtag(locale, "pinyin")) return "ZHP ".*;
        \\    if (hasSubtag(locale, "HK")) return "ZHH ".*;
        \\    if (hasSubtag(locale, "MO")) return "ZHTM".*;
        \\    if (hasSubtag(locale, "Hant") or hasSubtag(locale, "TW")) return "ZHT ".*;
        \\    return "ZHS ".*;
        \\}
        \\
        \\fn primarySubtag(locale: []const u8) []const u8 {
        \\    var end: usize = 0;
        \\    while (end < locale.len and locale[end] != '-' and locale[end] != '_' and locale[end] != '.' and locale[end] != '@') : (end += 1) {}
        \\    return locale[0..end];
        \\}
        \\
        \\fn hasSubtag(locale: []const u8, expected: []const u8) bool {
        \\    var start: usize = 0;
        \\    while (start < locale.len) {
        \\        while (start < locale.len and (locale[start] == '-' or locale[start] == '_' or locale[start] == '.' or locale[start] == '@')) : (start += 1) {}
        \\        var end = start;
        \\        while (end < locale.len and locale[end] != '-' and locale[end] != '_' and locale[end] != '.' and locale[end] != '@') : (end += 1) {}
        \\        if (equal(locale[start..end], expected)) return true;
        \\        start = end;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn equal(left: []const u8, right: []const u8) bool {
        \\    return std.ascii.eqlIgnoreCase(left, right);
        \\}
        \\
        \\fn binaryAlias(code: [2]u8) ?[4]u8 {
        \\    var low: usize = 0;
        \\    var high: usize = aliases.len;
        \\    while (low < high) {
        \\        const middle = low + (high - low) / 2;
        \\        switch (std.mem.order(u8, &aliases[middle].code, &code)) {
        \\            .lt => low = middle + 1,
        \\            .gt => high = middle,
        \\            .eq => return aliases[middle].tag,
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
        \\fn binaryLanguage(code: [3]u8) ?[4]u8 {
        \\    var low: usize = 0;
        \\    var high: usize = languages.len;
        \\    while (low < high) {
        \\        const middle = low + (high - low) / 2;
        \\        switch (std.mem.order(u8, &languages[middle].code, &code)) {
        \\            .lt => low = middle + 1,
        \\            .gt => high = middle,
        \\            .eq => return languages[middle].tag,
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
    );
}
