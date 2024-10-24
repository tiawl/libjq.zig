const std = @import ("std");
const toolbox = @import ("toolbox");

const Paths = struct
{
  // prefixed attributes
  __tmp: [] const u8 = undefined,
  __tmp_src: [] const u8 = undefined,
  __jq: [] const u8 = undefined,
  __jq_src: [] const u8 = undefined,

  // mandatory getters
  pub fn getTmp (self: @This ()) [] const u8 { return self.__tmp; }
  pub fn getTmpSrc (self: @This ()) [] const u8 { return self.__tmp_src; }
  pub fn getJq (self: @This ()) [] const u8 { return self.__jq; }
  pub fn getJqSrc (self: @This ()) [] const u8 { return self.__jq_src; }

  // mandatory init
  pub fn init (builder: *std.Build) !@This ()
  {
    var self = @This ()
    {
      .__jq = try builder.build_root.join (builder.allocator,
        &.{ "jq", }),
      .__tmp = try builder.build_root.join (builder.allocator,
        &.{ "tmp", }),
    };

    self.__jq_src = try std.fs.path.join (builder.allocator,
      &.{ self.getJq (), "src", });
    self.__tmp_src = try std.fs.path.join (builder.allocator,
      &.{ self.getTmp (), "src", });

    return self;
  }
};

fn update (builder: *std.Build, path: *const Paths,
  dependencies: *const toolbox.Dependencies) !void
{
  std.fs.deleteTreeAbsolute (path.getJq ()) catch |err|
  {
    switch (err)
    {
      error.FileNotFound => {},
      else => return err,
    }
  };

  try dependencies.clone (builder, "jq", path.getTmp ());
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "git", "submodule", "update", "--init", }, .cwd = path.getTmp (), });
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "autoreconf", "-i", }, .cwd = path.getTmp (), });
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "./configure", "--disable-docs", "--disable-valgrind", "--with-oniguruma=builtin", }, .cwd = path.getTmp (), });
  try toolbox.run (builder,
    .{ .argv = &[_][] const u8 { "make", "-j8", }, .cwd = path.getTmp (), });

  try toolbox.make (path.getJq ());
  try toolbox.make (path.getJqSrc ());

  var src_dir = try std.fs.openDirAbsolute (path.getTmpSrc (),
    .{ .iterate = true, });
  defer src_dir.close ();

  var walker = try src_dir.walk (builder.allocator);
  defer walker.deinit ();

  while (try walker.next ()) |*entry|
  {
    const dest = try std.fs.path.join (builder.allocator,
      &.{ path.getJqSrc (), entry.path, });
    switch (entry.kind)
    {
      .file => try toolbox.copy (try std.fs.path.join (builder.allocator,
        &.{ path.getTmpSrc (), entry.path, }), dest),
      .directory => try toolbox.make (dest),
      else => return error.UnexpectedEntryKind,
    }
  }

  try std.fs.deleteTreeAbsolute (path.getTmp ());
  try std.fs.deleteTreeAbsolute (try std.fs.path.join (builder.allocator,
      &.{ path.getJqSrc (), "inject_errors.c", }));
  try std.fs.deleteTreeAbsolute (try std.fs.path.join (builder.allocator,
      &.{ path.getJqSrc (), "main.c", }));

  try toolbox.clean (builder, &.{ "jq", }, &.{ ".inc", });
}

pub fn build (builder: *std.Build) !void
{
  const target = builder.standardTargetOptions (.{});
  const optimize = builder.standardOptimizeOption (.{});

  const path = try Paths.init (builder);

  const dependencies = try toolbox.Dependencies.init (builder, "libjq.zig",
  &.{ "jq", },
  .{
     .toolbox = .{
       .name = "tiawl/toolbox",
       .host = toolbox.Repository.Host.github,
       .ref = toolbox.Repository.Reference.tag,
     },
     .winpthreads = .{
       .name = "kassane/winpthreads-zigbuild",
       .host = toolbox.Repository.Host.github,
       .ref = toolbox.Repository.Reference.commit,
     },
   }, .{
     .jq = .{
       .name = "jqlang/jq",
       .host = toolbox.Repository.Host.github,
       .ref = toolbox.Repository.Reference.commit,
     },
   });

  if (builder.option (bool, "update", "Update binding") orelse false)
    try update (builder, &path, &dependencies);

  const lib = builder.addStaticLibrary (.{
    .name = "jq",
    .root_source_file = builder.addWriteFiles ().add ("empty.c", ""),
    .target = target,
    .optimize = optimize,
  });

  toolbox.addInclude (lib, "jq");

  if (lib.rootModuleTarget ().isMinGW ())
  {
    const winpthreads_dep = builder.dependency ("winpthreads", .{
      .target = target,
      .optimize = optimize,
    });
    const pthreads = winpthreads_dep.artifact ("winpthreads");
    for (pthreads.root_module.include_dirs.items) |include|
    {
      lib.root_module.include_dirs.append (builder.allocator, include) catch {};
    }
    lib.linkLibrary (pthreads);
    lib.linkSystemLibrary ("shlwapi");
  }

  lib.linkLibC ();

  toolbox.addHeader (lib, path.getJqSrc (), ".", &.{ ".h", ".inc", });

  var jq_src_dir =
    try std.fs.openDirAbsolute (path.getJqSrc (), .{ .iterate = true, });
  defer jq_src_dir.close ();

  const flags = [_][] const u8 { "-DIEEE_8087=1", "-D_GNU_SOURCE=1", };
  var it = jq_src_dir.iterate ();
  while (try it.next ()) |*entry|
  {
    if (toolbox.isCSource (entry.name) and entry.kind == .file)
      try toolbox.addSource (lib, path.getJqSrc (), entry.name,
        &flags);
  }

  builder.installArtifact (lib);
}
