(*
 * Copyright (c) 2015-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module Hashtbl = Caml.Hashtbl
module L = Logging
module F = Format

type node_tag =
  | Condition of bool
  | Exception of Typ.name
  | Procedure_start of Typ.Procname.t
  | Procedure_end of Typ.Procname.t

(** Element of a loc trace *)
type loc_trace_elem =
  { lt_level: int  (** nesting level of procedure calls *)
  ; lt_loc: Location.t  (** source location at the current step in the trace *)
  ; lt_description: string  (** description of the current step in the trace *)
  ; lt_node_tags: node_tag list  (** tags describing the node at the current location *) }

let pp_loc_trace_elem fmt {lt_level; lt_loc} = F.fprintf fmt "%d %a" lt_level Location.pp lt_loc

let pp_loc_trace fmt l = PrettyPrintable.pp_collection ~pp_item:pp_loc_trace_elem fmt l

let contains_exception loc_trace_elem =
  let pred nt =
    match nt with
    | Exception _ ->
        true
    | Condition _ | Procedure_start _ | Procedure_end _ ->
        false
  in
  List.exists ~f:pred loc_trace_elem.lt_node_tags


let make_trace_element lt_level lt_loc lt_description lt_node_tags =
  {lt_level; lt_loc; lt_description; lt_node_tags}


(** Trace of locations *)
type loc_trace = loc_trace_elem list

let compute_local_exception_line loc_trace =
  let open Base.Continue_or_stop in
  let compute_local_exception_line (last_known_step_at_level_zero_opt, line_opt) step =
    let last_known_step_at_level_zero_opt' =
      if Int.equal step.lt_level 0 then Some step else last_known_step_at_level_zero_opt
    in
    match last_known_step_at_level_zero_opt' with
    | Some step_zero when contains_exception step ->
        Stop (Some step_zero.lt_loc.line)
    | _ ->
        Continue (last_known_step_at_level_zero_opt', line_opt)
  in
  List.fold_until ~init:(None, None) ~f:compute_local_exception_line ~finish:snd loc_trace


type node =
  | UnknownNode
  | FrontendNode of {node_key: Procdesc.NodeKey.t}
  | BackendNode of {node: Procdesc.Node.t}

type err_key =
  { severity: Exceptions.severity
  ; in_footprint: bool
  ; err_name: IssueType.t
  ; err_desc: Localise.error_desc }
[@@deriving compare]

(** Data associated to a specific error *)
type err_data =
  { node_id: int
  ; node_key: Procdesc.NodeKey.t
  ; session: int
  ; loc: Location.t
  ; loc_in_ml_source: L.ocaml_pos option
  ; loc_trace: loc_trace
  ; err_class: Exceptions.err_class
  ; visibility: Exceptions.visibility
  ; linters_def_file: string option
  ; doc_url: string option
  ; access: string option
  ; extras: Jsonbug_t.extra option
  (* NOTE: Please consider adding new fields as part of extras *) }

let compare_err_data err_data1 err_data2 = Location.compare err_data1.loc err_data2.loc

module ErrDataSet = (* set err_data with no repeated loc *)
Caml.Set.Make (struct
  type t = err_data

  let compare = compare_err_data
end)

(** Hash table to implement error logs *)
module ErrLogHash = struct
  module Key = struct
    type t = err_key

    (* NOTE: changing the hash function can change the order in which issues are reported. *)
    let hash key =
      Hashtbl.hash
        (key.severity, key.in_footprint, key.err_name, Localise.error_desc_hash key.err_desc)


    let equal key1 key2 =
      [%compare.equal: Exceptions.severity * bool * IssueType.t]
        (key1.severity, key1.in_footprint, key1.err_name)
        (key2.severity, key2.in_footprint, key2.err_name)
      && Localise.error_desc_equal key1.err_desc key2.err_desc
  end

  include Hashtbl.Make (Key)
end

(** Type of the error log, to be reset once per function.
    Map severity, footprint / re - execution flag, error name,
    error description, severity, to set of err_data. *)
type t = ErrDataSet.t ErrLogHash.t

(** Empty error log *)
let empty () = ErrLogHash.create 13

(** type of the function to be passed to iter *)
type iter_fun = err_key -> err_data -> unit

(** Apply f to nodes and error names *)
let iter (f : iter_fun) (err_log : t) =
  ErrLogHash.iter
    (fun err_key set -> ErrDataSet.iter (fun err_data -> f err_key err_data) set)
    err_log


let fold (f : err_key -> err_data -> 'a -> 'a) t acc =
  ErrLogHash.fold
    (fun err_key set acc -> ErrDataSet.fold (fun err_data acc -> f err_key err_data acc) set acc)
    t acc


(** Return the number of elements in the error log which satisfy [filter] *)
let size filter (err_log : t) =
  let count = ref 0 in
  ErrLogHash.iter
    (fun key err_datas ->
      if filter key.severity key.in_footprint then count := !count + ErrDataSet.cardinal err_datas
      )
    err_log ;
  !count


(** Print errors from error log *)
let pp_errors fmt (errlog : t) =
  let f key _ =
    if Exceptions.equal_severity key.severity Exceptions.Error then
      F.fprintf fmt "%a@ " IssueType.pp key.err_name
  in
  ErrLogHash.iter f errlog


(** Print warnings from error log *)
let pp_warnings fmt (errlog : t) =
  let f key _ =
    if Exceptions.equal_severity key.severity Exceptions.Warning then
      F.fprintf fmt "%a %a@ " IssueType.pp key.err_name Localise.pp_error_desc key.err_desc
  in
  ErrLogHash.iter f errlog


(** Print an error log in html format *)
let pp_html source path_to_root fmt (errlog : t) =
  let pp_eds fmt err_datas =
    let pp_nodeid_session_loc fmt err_data =
      Io_infer.Html.pp_session_link source path_to_root fmt
        (err_data.node_id, err_data.session, err_data.loc.Location.line)
    in
    ErrDataSet.iter (pp_nodeid_session_loc fmt) err_datas
  in
  let pp_err_log do_fp ek key err_datas =
    if Exceptions.equal_severity key.severity ek && Bool.equal do_fp key.in_footprint then
      F.fprintf fmt "<br>%a %a %a" IssueType.pp key.err_name Localise.pp_error_desc key.err_desc
        pp_eds err_datas
  in
  let pp severity is_footprint phase =
    F.fprintf fmt "%a%s DURING %s@\n" Io_infer.Html.pp_hline ()
      (Exceptions.severity_string severity)
      phase ;
    ErrLogHash.iter (pp_err_log is_footprint severity) errlog
  in
  List.iter
    Exceptions.[Advice; Error; Info; Like; Warning]
    ~f:(fun severity -> pp severity true "FOOTPRINT" ; pp severity false "RE-EXECUTION")


(** Add an error description to the error log unless there is
    one already at the same node + session; return true if added *)
let add_issue tbl err_key (err_datas : ErrDataSet.t) : bool =
  try
    let current_eds = ErrLogHash.find tbl err_key in
    if ErrDataSet.subset err_datas current_eds then false
    else (
      ErrLogHash.replace tbl err_key (ErrDataSet.union err_datas current_eds) ;
      true )
  with Caml.Not_found ->
    ErrLogHash.add tbl err_key err_datas ;
    true


(** Update an old error log with a new one *)
let update errlog_old errlog_new =
  ErrLogHash.iter (fun err_key l -> ignore (add_issue errlog_old err_key l)) errlog_new


let log_issue procname ~clang_method_kind severity err_log ~loc ~node ~session ~ltr
    ~linters_def_file ~doc_url ~access ~extras exn =
  let error = Exceptions.recognize_exception exn in
  let severity = Option.value error.severity ~default:severity in
  let hide_java_loc_zero =
    (* hide java errors at location zero unless in -developer_mode *)
    (not Config.developer_mode) && Language.curr_language_is Java && Int.equal loc.Location.line 0
  in
  let hide_memory_error =
    match Localise.error_desc_get_bucket error.description with
    | Some bucket when String.equal bucket Mleak_buckets.ml_bucket_unknown_origin ->
        not Mleak_buckets.should_raise_leak_unknown_origin
    | _ ->
        false
  in
  let report_developer_exn exn =
    match exn with Exceptions.Dummy_exception _ -> false | _ -> true
  in
  let exn_developer =
    Exceptions.equal_visibility error.visibility Exceptions.Exn_developer
    && report_developer_exn exn
  in
  let should_report =
    Exceptions.equal_visibility error.visibility Exceptions.Exn_user
    || (Config.developer_mode && exn_developer)
  in
  ( if exn_developer then
    let issue =
      let lang = Typ.Procname.get_language procname in
      let clang_method_kind =
        match lang with
        | Language.Clang ->
            Option.map ~f:ClangMethodKind.to_string clang_method_kind
        | _ ->
            None
      in
      EventLogger.AnalysisIssue
        { bug_type= error.name.IssueType.unique_id
        ; bug_kind= Exceptions.severity_string severity
        ; clang_method_kind
        ; exception_triggered_location= error.ocaml_pos
        ; lang= Language.to_explicit_string lang
        ; procedure_name= Typ.Procname.to_string procname
        ; source_location= loc }
    in
    EventLogger.log issue ) ;
  if should_report && (not hide_java_loc_zero) && not hide_memory_error then
    let added =
      let node_id, node_key =
        match node with
        | UnknownNode ->
            (0, Procdesc.NodeKey.dummy)
        | FrontendNode {node_key} ->
            (0, node_key)
        | BackendNode {node} ->
            ((Procdesc.Node.get_id node :> int), Procdesc.Node.compute_key node)
      in
      let err_data =
        { node_id
        ; node_key
        ; session
        ; loc
        ; loc_in_ml_source= error.ocaml_pos
        ; loc_trace= ltr
        ; err_class= error.category
        ; visibility= error.visibility
        ; linters_def_file
        ; doc_url
        ; access
        ; extras }
      in
      let err_key =
        { severity
        ; in_footprint= !Config.footprint
        ; err_name= error.name
        ; err_desc= error.description }
      in
      add_issue err_log err_key (ErrDataSet.singleton err_data)
    in
    let should_print_now = match exn with Exceptions.Internal_error _ -> true | _ -> added in
    let print_now () =
      L.(debug Analysis Medium)
        "@\n%a@\n@?"
        (Exceptions.pp_err loc severity error.name error.description error.ocaml_pos)
        () ;
      if not (Exceptions.equal_severity severity Exceptions.Error) then (
        let warn_str =
          let pp fmt =
            Format.fprintf fmt "%s %a" error.name.IssueType.unique_id Localise.pp_error_desc
              error.description
          in
          F.asprintf "%t" pp
        in
        let d =
          match severity with
          | Exceptions.Error ->
              L.d_error
          | Exceptions.Warning ->
              L.d_warning
          | Exceptions.Info | Exceptions.Advice | Exceptions.Like ->
              L.d_info
        in
        d warn_str ; L.d_ln () )
    in
    if should_print_now then print_now ()