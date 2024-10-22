const std = @import ("std");

pub fn build (builder: *std.Build) !void
{
  const target = builder.standardTargetOptions (.{});
  const optimize = .Debug;

  var exe = builder.addExecutable (.{
    .name = "example",
    .root_source_file = .{ .cwd_relative = try builder.build_root.join (
      builder.allocator, &.{ "src", "main.zig", }), },
    .target = target,
    .optimize = optimize,
  });

  var jq_dep = builder.dependency ("libjq.zig", .{
    .target = target,
    .optimize = optimize,
  });

  exe.linkLibrary (jq_dep.artifact ("jq"));

  builder.installArtifact (exe);
}
