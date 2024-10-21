const std = @import ("std");
const toolbox = @import ("toolbox");

fn update (builder: *std.Build, jq_path: [] const u8,
  dependencies: *const toolbox.Dependencies) !void
{
  const tmp_path =
    try builder.build_root.join (builder.allocator, &.{ "tmp", });
  const src_path =
    try std.fs.path.join (builder.allocator, &.{ tmp_path, "src", });
  const jq_src_path =
    try std.fs.path.join (builder.allocator, &.{ jq_path, "src", });

  std.fs.deleteTreeAbsolute (jq_path) catch |err|
  {
    switch (err)
    {
      error.FileNotFound => {},
      else => return err,
    }
  };

  try dependencies.clone (builder, "jq", tmp_path);
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "git", "submodule", "update", "--init", }, .cwd = tmp_path, });
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "autoreconf", "-i", }, .cwd = tmp_path, });
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "./configure", "--with-oniguruma=builtin", }, .cwd = tmp_path, });
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "make", "-j8", }, .cwd = tmp_path, });

  var src_dir = try std.fs.openDirAbsolute (src_path,
    .{ .iterate = true, });
  defer src_dir.close ();

  var walker = try src_dir.walk (builder.allocator);
  defer walker.deinit ();

  try toolbox.make (jq_path);
  try toolbox.make (jq_src_path);

  while (try walker.next ()) |*entry|
  {
    const dest = try std.fs.path.join (builder.allocator,
      &.{ jq_src_path, entry.path, });
    switch (entry.kind)
    {
      .file => try toolbox.copy (try std.fs.path.join (builder.allocator,
        &.{ src_path, entry.path, }), dest),
      .directory => try toolbox.make (dest),
      else => return error.UnexpectedEntryKind,
    }
  }

  try std.fs.deleteTreeAbsolute (tmp_path);

  try toolbox.clean (builder, &.{ "jq", }, &.{ ".inc", });
}

pub fn build (builder: *std.Build) !void
{
  const target = builder.standardTargetOptions (.{});
  const optimize = builder.standardOptimizeOption (.{});

  const jq_path =
    try builder.build_root.join (builder.allocator, &.{ "jq", });

  const dependencies = try toolbox.Dependencies.init (builder, "libjq.zig",
  &.{ "jq", },
  .{
     .toolbox = .{
       .name = "tiawl/toolbox",
       .host = toolbox.Repository.Host.github,
       .ref = toolbox.Repository.Reference.tag,
     },
   }, .{
     .jq = .{
       .name = "jqlang/jq",
       .host = toolbox.Repository.Host.github,
       .ref = toolbox.Repository.Reference.commit,
     },
   });

  if (builder.option (bool, "update", "Update binding") orelse false)
    try update (builder, jq_path, &dependencies);

  const lib = builder.addStaticLibrary (.{
    .name = "libjq",
    .root_source_file = builder.addWriteFiles ().add ("empty.c", ""),
    .target = target,
    .optimize = optimize,
  });

  var flags = try std.BoundedArray ([] const u8, 16).init (0);

  var jq_dir =
    try std.fs.openDirAbsolute (jq_path, .{ .iterate = true, });
  defer jq_dir.close ();

  var it = jq_dir.iterate ();
  while (try it.next ()) |*entry|
  {
    if (entry.kind == .directory)
    {
      toolbox.addHeader (lib, try std.fs.path.join (builder.allocator,
        &.{ jq_path, entry.name, }), entry.name, &.{ ".h", ".inc", });
    }
  }

  lib.linkLibC ();

  it = jq_dir.iterate ();
  while (try it.next ()) |*entry|
  {
    if (toolbox.isCSource (entry.name) and entry.kind == .file)
      try toolbox.addSource (lib, "jq", entry.name,
        flags.slice ());
  }

  builder.installArtifact (lib);
}
