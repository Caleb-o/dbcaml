let ( let* ) = Result.bind

let query ~conn ~query =
  let buf = Buffer.create 0 in
  Buffer.add_string buf query;

  let* _ = Pg.send conn buf in

  Ok ()
