open Riot
module Bs = Bytestring

open Riot.Logger.Make (struct
  let namespace = ["dbcaml"; "dbcaml_postgres_driver"]
end)

let ( let* ) = Result.bind

let start conn username database =
  let buffer = Buffer.create 20 in

  Buffer_tools.put_length_prefixed buffer (fun b ->
      Buffer.add_string b "\000\003\000\000";
      Buffer_tools.put_str_null b "user";
      Buffer_tools.put_str_null b username;
      Buffer_tools.put_str_null b "database";
      Buffer_tools.put_str_null b database;
      Buffer.add_char b '\000');

  Logger.debug (fun f -> f "Sending startup message");
  let* _ = Pg.send conn buffer in

  let* (_, message_format, message) = Pg.receive conn in

  Ok (message_format, message)