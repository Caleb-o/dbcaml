open Riot

open Riot.Logger.Make (struct
  let namespace = ["dbcaml"; "dbcaml_postgres_driver"]
end)

let ( let* ) = Result.bind

let scram_hi data salt iterations =
  Pbkdf.pbkdf2
    ~prf:`SHA256
    ~salt
    ~password:(Cstruct.of_string data)
    ~count:iterations
    ~dk_len:(Int32.of_int 32)

let scram_hmac key text =
  Cstruct.of_string text
  |> Mirage_crypto.Hash.SHA256.hmac ~key
  |> Cstruct.to_string

let scram_h text = Cstruct.of_string text |> Mirage_crypto.Hash.SHA256.digest

let xor a b =
  Mirage_crypto.Uncommon.Cs.xor (Cstruct.of_string a) (Cstruct.of_string b)
  |> Cstruct.to_string
  |> Base64.encode_exn

let base64_encode input =
  Cryptokit.transform_string (Cryptokit.Base64.encode_compact ()) input

let generate_nonce () =
  let count = Random.int ~max:(64 - 28 + 28) () in

  let gen_char () =
    let rec loop () =
      let c = Random.int ~max:(0x7E - 0x21 + 1) () in
      if c = 0x2C then
        loop ()
      else
        Char.chr c
    in
    loop ()
  in

  String.init count (fun _ -> gen_char ())

let parse_payload payload_str =
  let parts = String.split_on_char ',' payload_str in
  List.fold_left
    (fun acc part ->
      match String.split_on_char '=' part with
      | k :: v :: xs -> (k, v ^ String.make (List.length xs) '=') :: acc
      | _ ->
        failwith (Printf.sprintf "split should have at least 2 parts: %s" part))
    []
    parts

let verify_server_proof server_key auth_message verifier =
  let server_signature = scram_hmac server_key auth_message in
  let decoded_verifier = Base64.decode_exn verifier in
  server_signature = decoded_verifier

let authenticate conn is_plus username password =
  let nonce = generate_nonce () |> base64_encode in
  let channel_binding = "n,," in
  let first_bare = Printf.sprintf "n=%s,r=%s" username nonce in
  let buf = Buffer.create 128 in

  Buffer.add_char buf 'p';
  let response =
    Bytes.of_string (Printf.sprintf "%s%s" channel_binding first_bare)
  in

  let mechanism =
    if is_plus then
      "SCRAM-SHA-256-PLUS"
    else
      "SCRAM-SHA-256"
  in

  Buffer_tools.put_length_prefixed buf (fun buf ->
      Buffer_tools.put_str_null buf mechanism;
      Buffer.add_int32_be buf (Int32.of_int (Bytes.length response));
      Buffer.add_bytes buf response);

  Logger.debug (fun f -> f "Sending initial SCRAM-SHA-256 message to server");
  let* _ = Pg.send conn buf in
  let* (_, _, server_first_message) = Pg.receive conn in
  let server_first_message =
    String.sub server_first_message 4 (String.length server_first_message - 4)
  in

  let parsed_payload = parse_payload server_first_message in
  let iterations = int_of_string (List.assoc "i" parsed_payload) in
  let salt = List.assoc "s" parsed_payload in
  let server_nonce = List.assoc "r" parsed_payload in
  let without_proof =
    Printf.sprintf "c=%s,r=%s" (base64_encode channel_binding) server_nonce
  in

  let salt = Base64.decode_exn salt |> Cstruct.of_string in
  let salted_password = scram_hi password salt iterations in
  let client_key = scram_hmac salted_password "Client Key" in
  let stored_key = scram_h client_key in
  let auth_message =
    String.concat "," [first_bare; server_first_message; without_proof]
  in

  let client_signature = scram_hmac stored_key auth_message in
  let client_proof = Printf.sprintf "p=%s" (xor client_key client_signature) in
  let client_final = String.concat "," [without_proof; client_proof] in

  let buf = Buffer.create 128 in
  Buffer.add_char buf 'p';
  Buffer.add_int32_be buf (Int32.of_int (String.length client_final + 4));
  Buffer.add_string buf client_final;

  Logger.debug (fun f -> f "Sending final SCRAM-SHA-256 message to server");
  let* _ = Pg.send conn buf in
  let* (_, _, message) = Pg.receive conn in

  let message =
    String.sub message 4 (String.length message - 4)
    |> String.split_on_char ','
    |> List.hd
  in

  let parsed_payload = parse_payload message in
  let verifier = List.assoc "v" parsed_payload in
  let salted_password = scram_hi password salt iterations in
  let server_key =
    scram_hmac salted_password "Server Key" |> Cstruct.of_string
  in
  let auth_message =
    String.concat "," [first_bare; server_first_message; without_proof]
  in

  match verify_server_proof server_key auth_message verifier with
  | true ->
    Logger.debug (fun f -> f "SCRAM authentication successful");
    Ok ()
  | false -> Error (`Msg "Server proof verification failed")
