const std = @import ("std");

const c = @cImport ({
  @cInclude ("jv.h");
  @cInclude ("jq.h");
});

const ExitCode = enum (i8)
{
  JQ_OK            =  0,
  JQ_OK_NULL_KIND  = -1,
  JQ_ERROR_SYSTEM  =  2,
  JQ_ERROR_COMPILE =  3,
  JQ_OK_NO_OUTPUT  = -4,
  JQ_ERROR_UNKNOWN =  5,

  fn toError (self: @This ()) !void
  {
    switch (self)
    {
      .JQ_ERROR_SYSTEM => return error.JqSystemError,
      .JQ_ERROR_COMPILE => return error.JqCompileError,
      .JQ_ERROR_UNKNOWN => return error.JqUnknownError,
      else => {},
    }
  }
};

pub fn main () !void
{
  var arena = std.heap.ArenaAllocator.init (std.heap.page_allocator);
  defer arena.deinit ();
  const allocator = arena.allocator ();

  var ret = ExitCode.JQ_OK_NO_OUTPUT;
  var jq = c.jq_init ();

  if (jq == null)
  {
    ret = ExitCode.JQ_ERROR_SYSTEM;
    try ret.toError ();
  }
  defer c.jq_teardown (&jq);

  var data = c.jv_parse (c.jv_string_value (c.jv_load_file ("./data.json", 1)));
  defer c.jv_free (data);

  if (c.jv_is_valid (data) == 0)
  {
    data = c.jv_invalid_get_msg (data);
    std.debug.print ("{s}\n", .{ c.jv_string_value (data), });
    ret = ExitCode.JQ_ERROR_SYSTEM;
    try ret.toError ();
  }

  var input_state = c.jq_util_input_init (null, null);
  defer c.jq_util_input_free (&input_state);
  c.jq_set_input_cb (jq, c.jq_util_input_next_input_cb, input_state);

  const program = ".data[].firstName";
  const compiled = c.jq_compile (jq, try allocator.dupeZ (u8, program));

  if (compiled == 0) return error.JqCompileError;

  c.jq_start (jq, data, 0);

  var result = c.jq_next (jq);
  var printable_res: [*c] const u8 = undefined;
  defer c.jv_free (result);

  while (c.jv_is_valid (result) != 0)
  {
    printable_res = c.jv_string_value (c.jv_dump_string (result, c.JV_PRINT_COLOR | c.JV_PRINT_SPACE1 | c.JV_PRINT_PRETTY | c.JV_PRINT_ISATTY));
    std.debug.print ("{s}\n", .{ printable_res, });
    result = c.jq_next (jq);
  }

  if (c.jq_halted (jq) != 0)
  {
    const exit_code = c.jq_get_exit_code (jq);
    defer c.jv_free (exit_code);
    if (c.jv_is_valid (exit_code) == 0) ret = ExitCode.JQ_OK
    else if (c.jv_get_kind (exit_code) == c.JV_KIND_NUMBER) ret = @enumFromInt (@as (i8, @intFromFloat (c.jv_number_value (exit_code))))
    else ret = ExitCode.JQ_ERROR_UNKNOWN;
    var error_message = c.jq_get_error_message (jq);
    defer c.jv_free (error_message);
    if (c.jv_get_kind (error_message) != c.JV_KIND_STRING and c.jv_get_kind (error_message) != c.JV_KIND_NULL and (c.jv_is_valid (error_message)) != 0)
    {
      error_message = c.jv_dump_string (error_message, 0);
      std.debug.print("{s}\n", .{ c.jv_string_value (error_message), });
    }
    try ret.toError ();
  } else if (c.jv_invalid_has_msg (c.jv_copy (result)) != 0) {
    var msg = c.jv_invalid_get_msg (c.jv_copy (result));
    defer c.jv_free (msg);
    const input_pos = c.jq_util_input_get_position (jq);
    defer c.jv_free (input_pos);
    if (c.jv_get_kind (msg) == c.JV_KIND_STRING) {
      std.debug.print ("jq: error (at {s}): {s}\n", .{ c.jv_string_value (input_pos), c.jv_string_value (msg), });
    } else {
      msg = c.jv_dump_string (msg, 0);
      std.debug.print ("jq: error (at {s}) (not a string): {s}\n", .{ c.jv_string_value (input_pos), c.jv_string_value (msg), });
    }
    ret = ExitCode.JQ_ERROR_UNKNOWN;
    try ret.toError ();
  }
}
