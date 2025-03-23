const std = @import("std");
const toolbox = @import("toolbox");

const Paths = struct {
    __tmp: []const u8,
    __tmp_src: []const u8,
    __jq: []const u8,
    __jq_src: []const u8,

    fn getTmp(self: @This()) []const u8 {
        return self.__tmp;
    }

    fn getTmpSrc(self: @This()) []const u8 {
        return self.__tmp_src;
    }

    fn getJq(self: @This()) []const u8 {
        return self.__jq;
    }

    fn getJqSrc(self: @This()) []const u8 {
        return self.__jq_src;
    }

    fn init() !@This() {
        const jq_path = try toolbox.instance().buildRootJoin(&.{
            "jq",
        });
        const tmp_path = try toolbox.instance().buildRootJoin(&.{
            "tmp",
        });

        return .{
            .__jq = jq_path,
            .__tmp = tmp_path,
            .__jq_src = toolbox.instance().pathJoin(&.{
                jq_path, "src",
            }),
            .__tmp_src = toolbox.instance().pathJoin(&.{
                tmp_path, "src",
            }),
        };
    }
};

fn update(path: *const Paths) !void {
    std.fs.deleteTreeAbsolute(path.getJq()) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    };

    try toolbox.instance().clone(.jq, path.getTmp());
    try toolbox.instance().run(.{
        .argv = &[_][]const u8{
            "git", "submodule", "update", "--init",
        },
        .cwd = path.getTmp(),
    });
    try toolbox.instance().run(.{
        .argv = &[_][]const u8{
            "autoreconf", "-i",
        },
        .cwd = path.getTmp(),
    });
    try toolbox.instance().run(.{
        .argv = &[_][]const u8{
            "./configure", "--disable-docs", "--disable-valgrind", "--with-oniguruma=builtin",
        },
        .cwd = path.getTmp(),
    });
    try toolbox.instance().run(.{
        .argv = &[_][]const u8{
            "make", "-j8",
        },
        .cwd = path.getTmp(),
    });

    try toolbox.instance().make(path.getJq());
    try toolbox.instance().make(path.getJqSrc());

    var src_dir = try std.fs.openDirAbsolute(path.getTmpSrc(), .{
        .iterate = true,
    });
    defer src_dir.close();

    var walker = try src_dir.walk(toolbox.instance().getBuilder().allocator);
    defer walker.deinit();

    while (try walker.next()) |*entry| {
        const dest = toolbox.instance().pathJoin(&.{
            path.getJqSrc(), entry.path,
        });
        switch (entry.kind) {
            .file => try toolbox.instance().copy(toolbox.instance().pathJoin(&.{
                path.getTmpSrc(), entry.path,
            }), dest),
            .directory => try toolbox.instance().make(dest),
            else => return error.UnexpectedEntryKind,
        }
    }

    try std.fs.deleteTreeAbsolute(path.getTmp());
    try std.fs.deleteTreeAbsolute(toolbox.instance().pathJoin(&.{
        path.getJqSrc(), "inject_errors.c",
    }));
    try std.fs.deleteTreeAbsolute(toolbox.instance().pathJoin(&.{
        path.getJqSrc(), "main.c",
    }));

    try toolbox.instance().clean(&.{
        "jq",
    }, &.{
        ".inc",
    });
}

const FromZon = toolbox.Repositories(.{
    .toolbox, .oniguruma_zig,
});

const DuringExec = toolbox.Repositories(.{
    .jq,
});

pub fn build(builder: *std.Build) !void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    try toolbox.init(FromZon, DuringExec, builder, optimize, .libjq_zig, "0x4fefb366172605fb", &.{
        "jq",
    }, .{
        .toolbox = .{
            .name = "tiawl/toolbox",
            .host = .github,
            .ref = .tag,
        },
        .oniguruma_zig = .{
            .name = "tiawl/oniguruma.zig",
            .host = .github,
            .ref = .tag,
        },
    }, .{
        .jq = .{
            .name = "jqlang/jq",
            .host = .github,
            .ref = .commit,
        },
    });
    defer toolbox.deinit();

    const path = try Paths.init();

    if (toolbox.instance().getUpdate()) try update(&path);

    const lib = builder.addStaticLibrary(.{
        .name = "jq",
        .root_source_file = builder.addWriteFiles().add("empty.c", ""),
        .target = target,
        .optimize = optimize,
    });

    toolbox.instance().addInclude(lib, "jq");

    if (lib.rootModuleTarget().isMinGW()) {
        lib.linkSystemLibrary("shlwapi");
    }

    const oniguruma_dep = builder.dependency("oniguruma_zig", .{
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibrary(oniguruma_dep.artifact("oniguruma"));
    lib.installLibraryHeaders(oniguruma_dep.artifact("oniguruma"));

    lib.linkLibC();

    toolbox.instance().addHeader(lib, path.getJqSrc(), ".", &.{
        ".h", ".inc",
    });

    var jq_src_dir = try std.fs.openDirAbsolute(path.getJqSrc(), .{
        .iterate = true,
    });
    defer jq_src_dir.close();

    const flags = [_][]const u8{
        "-DIEEE_8087=1", "-D_GNU_SOURCE=1", "-DHAVE_LIBONIG=1",
    };
    var it = jq_src_dir.iterate();
    while (try it.next()) |*entry| {
        if (toolbox.isCSource(entry.name) and entry.kind == .file) {
            try toolbox.instance().addSource(lib, path.getJqSrc(), entry.name, &flags);
        }
    }

    builder.installArtifact(lib);
}
