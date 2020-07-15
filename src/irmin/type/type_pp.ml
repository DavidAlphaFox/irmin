(*
 * Copyright (c) 2016-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Type_core

let t t =
  let rec aux : type a. a t -> a pp =
   fun t ppf x ->
    match t with
    | Self s -> aux s.self_fix ppf x
    | Custom c -> c.pp ppf x
    | Map m -> map m ppf x
    | Prim p -> prim p ppf x
    | Var v -> raise (Unbound_type_variable v)
    | List l -> Fmt.Dump.list (aux l.v) ppf x
    | Array a -> Fmt.Dump.array (aux a.v) ppf x
    | Option o -> Fmt.Dump.option (aux o) ppf x
    | Tuple t -> tuple t ppf x
    | Record r -> record r ppf x
    | Variant v -> variant v ppf x
  and map : type a b. (a, b) map -> b pp = fun l ppf x -> aux l.x ppf (l.g x)
  and prim : type a. a prim -> a pp =
   fun t ppf x ->
    match t with
    | Unit -> Fmt.string ppf "()"
    | Bool -> Fmt.bool ppf x
    | Char -> Fmt.(pf ppf "'%c'" x)
    | Int -> Fmt.int ppf x
    | Int32 -> Fmt.int32 ppf x
    | Int64 -> Fmt.int64 ppf x
    | Float ->
        Fmt.string ppf
          ( match classify_float x with
          | FP_infinite when x < 0. -> "neg_infinity"
          | FP_infinite -> "infinity"
          | _ -> string_of_float x (* Usually more precise than Fmt.float. *) )
    | String _ -> Fmt.Dump.string ppf x
    | Bytes _ -> Fmt.Dump.string ppf (Bytes.unsafe_to_string x)
  and tuple : type a. a tuple -> a pp =
   fun t ->
    match t with
    | Pair (ta, tb) -> Fmt.Dump.pair (aux ta) (aux tb)
    | Triple (ta, tb, tc) ->
        (* There is no built-in formatter for triples in [Fmt.Dump]. *)
        Fmt.(
          parens
            ( using (fun (a, _, _) -> a) (box (aux ta))
            ++ comma
            ++ using (fun (_, b, _) -> b) (box (aux tb))
            ++ comma
            ++ using (fun (_, _, c) -> c) (box (aux tc)) ))
  and record : type a. a record -> a pp =
   fun t ->
    fields t
    |> List.map (fun (Field f) -> Fmt.Dump.field f.fname f.fget (aux f.ftype))
    |> Fmt.Dump.record
  and variant : type a. a variant -> a pp =
   fun t ppf x ->
    match t.vget x with
    | CV0 c -> Fmt.string ppf (String.capitalize_ascii c.cname0)
    | CV1 (c, v) ->
        Fmt.string ppf (String.capitalize_ascii c.cname1);
        Fmt.string ppf " ";
        Fmt.parens (aux c.ctype1) ppf v
  in
  aux t

(* Fresh type variables in sequence: ['a; 'b; ...; 'z; 'aa; 'ab; ...] *)
let tvar_generator () =
  let count = ref 0 in
  let ident_of_count =
    let rec inner acc i =
      match i with
      | -1 -> acc
      | _ ->
          let c = String.make 1 (Char.chr ((i mod 26) + 97)) in
          inner (c ^ acc) ((i / 26) - 1)
    in
    inner ""
  in
  fun () ->
    let ident = ident_of_count !count in
    incr count;
    "'" ^ ident

let ty : type a. a t Fmt.t =
 fun ppf typ ->
  let get_tvar = tvar_generator () in

  let rec ty : type a. a t Fmt.t =
   fun ppf -> function
    | Self { self_unroll; _ } -> (
        match self_unroll (Var "") with
        (* If it's a recursive variant or record, don't print the [as 'a]
           alias since the type is already named. *)
        | Variant { vname; _ } -> ty ppf (self_unroll (Var vname))
        | Record { rname; _ } -> ty ppf (self_unroll (Var rname))
        | _ ->
            let var = Var (get_tvar ()) in
            Fmt.pf ppf "@[(%a as %a)@]" ty (self_unroll var) ty var)
    | Boxed b -> Fmt.pf ppf "@[Boxed (%a)@]" ty b
    | Custom c -> Fmt.pf ppf "@[Custom (%a)@]" custom c
    | Map m -> Fmt.pf ppf "@[Map (%a)@]" ty m.x
    | Prim p -> Fmt.pf ppf "@[%a@]" prim p
    | List l -> Fmt.pf ppf "@[%a list%a@]" ty l.v len l.len
    | Array a -> Fmt.pf ppf "@[%a array%a@]" ty a.v len a.len
    | Tuple (Pair (a, b)) -> Fmt.pf ppf "@[(%a * %a)@]" ty a ty b
    | Tuple (Triple (a, b, c)) -> Fmt.pf ppf "@[(%a * %a * %a)@]" ty a ty b ty c
    | Option t -> Fmt.pf ppf "@[%a option@]" ty t
    | Record { rname; rfields = Fields (fields, _); _ } ->
        Fmt.pf ppf "(@[<hv>%a>@] as %s)" pp_fields fields rname
    | Variant { vname; vcases; _ } -> (
        match Array.length vcases with
        | 0 -> Fmt.pf ppf "({} as %s)" vname (* empty type *)
        | _ -> Fmt.pf ppf "(@[%a]@] as %s)" pp_cases vcases vname)
    | Var v -> Fmt.string ppf v
  and pp_fields : type r b. (r, b) fields Fmt.t =
   fun ppf fields ->
    let rec inner : type b. first:bool -> (r, b) fields -> unit =
     fun ~first -> function
      | F0 -> ()
      | F1 ({ fname; ftype; _ }, fs) ->
          let trailing_space = match fs with F0 -> 1 | F1 _ -> 0 in
          Format.pp_print_char ppf (if first then '<' else ';');
          Format.fprintf ppf " %s : %a" fname ty ftype;
          Format.pp_print_break ppf trailing_space 0;
          (inner [@tailrec]) ~first:false fs
    in
    inner ~first:true fields
  and pp_case : type v. last:bool -> v a_case Fmt.t =
   fun ~last ppf case ->
    let pp_cname ppf name =
      Format.pp_print_string ppf (String.capitalize_ascii name)
    in
    let () =
      match case with
      | C0 { cname0; _ } -> Format.fprintf ppf " %a" pp_cname cname0
      | C1 { cname1; ctype1; _ } ->
          Format.fprintf ppf " %a of %a" pp_cname cname1 ty ctype1
    in
    Format.pp_print_break ppf 1 0;
    if not last then Format.pp_print_char ppf '|'
  and pp_cases : type v. v a_case array Fmt.t =
   fun ppf cases ->
    let last_i = Array.length cases - 1 in
    Format.pp_open_hvbox ppf 0;
    Format.pp_print_string ppf "[";
    cases |> Array.iteri (fun i -> pp_case ~last:(i = last_i) ppf);
    Format.pp_close_box ppf ()
  and custom : type a. a custom Fmt.t =
   fun ppf c ->
    match c.cwit with `Type t -> ty ppf t | `Witness _ -> Fmt.string ppf "-"
  and prim : type a. a prim Fmt.t =
   fun ppf -> function
    | Unit -> Fmt.string ppf "unit"
    | Bool -> Fmt.string ppf "bool"
    | Char -> Fmt.string ppf "char"
    | Int -> Fmt.string ppf "int"
    | Int32 -> Fmt.string ppf "int32"
    | Int64 -> Fmt.string ppf "int64"
    | Float -> Fmt.string ppf "float"
    | String n -> Fmt.pf ppf "string%a" len n
    | Bytes n -> Fmt.pf ppf "bytes%a" len n
  and len : len Fmt.t =
   fun ppf -> function
    | `Int8 -> Fmt.string ppf ":8"
    | `Int64 -> Fmt.string ppf ":64"
    | `Int16 -> Fmt.string ppf ":16"
    | `Fixed n -> Fmt.pf ppf ":<%d>" n
    | `Int -> ()
    | `Int32 -> Fmt.pf ppf ":32"
  in
  ty ppf typ

let to_string ty = Fmt.to_to_string (t ty)

let of_string t =
  let map_result f = function Ok x -> Ok (f x) | Error _ as e -> e in
  let v f x = try Ok (f x) with Invalid_argument e -> Error (`Msg e) in
  let rec aux : type a a. a t -> a of_string =
   fun t x ->
    match t with
    | Self s -> aux s.self_fix x
    | Custom c -> c.of_string x
    | Map m -> aux m.x x |> map_result m.f
    | Prim p -> prim p x
    | _ -> Type_json.of_string t x
  and prim : type a. a prim -> a of_string =
   fun t x ->
    match t with
    | Unit -> Ok ()
    | Bool -> v bool_of_string x
    | Char -> v (fun x -> x.[1]) x
    | Int -> v int_of_string x
    | Int32 -> v Int32.of_string x
    | Int64 -> v Int64.of_string x
    | Float -> v float_of_string x
    | String _ -> Ok x
    | Bytes _ -> Ok (Bytes.unsafe_of_string x)
  in
  aux t
