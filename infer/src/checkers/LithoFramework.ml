(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format
module Domain = LithoDomain

(** return true if this function is part of the Litho framework code rather than client code *)
let is_function = function
  | Typ.Procname.Java java_procname -> (
    match Typ.Procname.Java.get_package java_procname with
    | Some "com.facebook.litho" ->
        true
    | _ ->
        false )
  | _ ->
      false


let is_component_builder procname tenv =
  match procname with
  | Typ.Procname.Java java_procname ->
      PatternMatch.is_subtype_of_str tenv
        (Typ.Procname.Java.get_class_type_name java_procname)
        "com.facebook.litho.Component$Builder"
  | _ ->
      false


let is_component procname tenv =
  match procname with
  | Typ.Procname.Java java_procname ->
      PatternMatch.is_subtype_of_str tenv
        (Typ.Procname.Java.get_class_type_name java_procname)
        "com.facebook.litho.Component"
  | _ ->
      false


let is_component_build_method procname tenv =
  match Typ.Procname.get_method procname with
  | "build" ->
      is_component_builder procname tenv
  | _ ->
      false


let is_component_create_method procname tenv =
  match Typ.Procname.get_method procname with "create" -> is_component procname tenv | _ -> false


let is_on_create_layout = function
  | Typ.Procname.Java java_pname -> (
    match Typ.Procname.Java.get_method java_pname with "onCreateLayout" -> true | _ -> false )
  | _ ->
      false


let get_component_create_typ_opt procname tenv =
  match procname with
  | Typ.Procname.Java java_pname when is_component_create_method procname tenv ->
      Some (Typ.Procname.Java.get_class_type_name java_pname)
  | _ ->
      None


module type LithoContext = sig
  type t

  type summary

  val field : (Payloads.t, summary option) Field.t

  val check_callee : callee_pname:Typ.Procname.t -> tenv:Tenv.t -> summary option -> bool

  val satisfies_heuristic :
    callee_pname:Typ.Procname.t -> callee_summary_opt:summary option -> Tenv.t -> bool

  val should_report : Procdesc.t -> Tenv.t -> bool

  val report : summary -> Tenv.t -> Summary.t -> summary

  val session_name : string
end

type get_proc_summary_and_formals =
  Typ.Procname.t -> (Domain.summary * (Pvar.t * Typ.t) list) option

type extras = {get_proc_summary_and_formals: get_proc_summary_and_formals}

module TransferFunctions
    (CFG : ProcCfg.S)
    (LithoContext : LithoContext with type summary = Domain.summary) =
struct
  module CFG = CFG
  module Domain = Domain

  module Payload = SummaryPayload.Make (struct
    type t = LithoContext.summary

    let field = LithoContext.field
  end)

  type nonrec extras = extras

  let apply_callee_summary summary_opt ~caller_pname ~callee_pname ret_id_typ formals actuals
      ((old_domain, new_domain) as astate) =
    Option.value_map summary_opt ~default:astate ~f:(fun (old_callee, new_callee) ->
        (* TODO: append paths if the footprint access path is an actual path instead of a var *)
        let f_sub {Domain.LocalAccessPath.access_path= (var, _), _} =
          match Var.get_footprint_index var with
          | Some footprint_index -> (
            match List.nth actuals footprint_index with
            | Some (HilExp.AccessExpression actual_access_expr) ->
                Some
                  (Domain.LocalAccessPath.make
                     (HilExp.AccessExpression.to_access_path actual_access_expr)
                     caller_pname)
            | _ ->
                None )
          | None ->
              if Var.is_return var then
                Some (Domain.LocalAccessPath.make (ret_id_typ, []) caller_pname)
              else None
        in
        let astate_old = Domain.substitute ~f_sub old_callee |> Domain.OldDomain.join old_domain in
        let astate_new =
          Domain.NewDomain.subst ~formals ~actuals ~ret_id_typ ~caller_pname ~callee_pname
            ~caller:new_domain ~callee:new_callee
        in
        (astate_old, astate_new) )


  let exec_instr astate ProcData.{summary; tenv; extras= {get_proc_summary_and_formals}} _
      (instr : HilInstr.t) : Domain.t =
    let caller_pname = Summary.get_proc_name summary in
    match instr with
    | Call
        ( return_base
        , Direct callee_pname
        , (HilExp.AccessExpression receiver_ae :: _ as actuals)
        , _
        , location ) ->
        let callee_summary_and_formals_opt = get_proc_summary_and_formals callee_pname in
        let callee_summary_opt = Option.map callee_summary_and_formals_opt ~f:fst in
        let receiver =
          Domain.LocalAccessPath.make_from_access_expression receiver_ae caller_pname
        in
        if
          ( LithoContext.check_callee ~callee_pname ~tenv callee_summary_opt
          || (* track callee in order to report respective errors *)
          Domain.mem receiver astate
          (* track anything called on a receiver we're already tracking *) )
          && LithoContext.satisfies_heuristic ~callee_pname ~callee_summary_opt tenv
        then
          let return_access_path = Domain.LocalAccessPath.make (return_base, []) caller_pname in
          let callee = Domain.MethodCall.make receiver callee_pname location in
          let return_calls =
            (try Domain.find return_access_path astate with Caml.Not_found -> Domain.CallSet.empty)
            |> Domain.CallSet.add callee
          in
          let astate = Domain.add return_access_path return_calls astate in
          match get_component_create_typ_opt callee_pname tenv with
          | Some create_typ ->
              Domain.call_create return_access_path create_typ location astate
          | None ->
              if is_component_build_method callee_pname tenv then
                Domain.call_build_method ~ret:return_access_path ~receiver astate
              else if is_component_builder callee_pname tenv then
                let callee_prefix = Domain.MethodCallPrefix.make receiver callee_pname location in
                Domain.call_builder ~ret:return_access_path ~receiver callee_prefix astate
              else astate
        else
          (* treat it like a normal call *)
          Option.value_map callee_summary_and_formals_opt ~default:astate ~f:(fun (_, formals) ->
              apply_callee_summary callee_summary_opt ~caller_pname ~callee_pname return_base
                formals actuals astate )
    | Call (ret_id_typ, Direct callee_pname, actuals, _, _) ->
        let callee_summary_and_formals_opt = get_proc_summary_and_formals callee_pname in
        let callee_summary_opt = Option.map callee_summary_and_formals_opt ~f:fst in
        Option.value_map callee_summary_and_formals_opt ~default:astate ~f:(fun (_, formals) ->
            apply_callee_summary callee_summary_opt ~caller_pname ~callee_pname ret_id_typ formals
              actuals astate )
    | Assign (lhs_ae, rhs, _) ->
        let astate =
          match rhs with
          | HilExp.AccessExpression rhs_ae ->
              (* creating an alias for the rhs binding; assume all reads will now occur through the
                 alias. this helps us keep track of chains in cases like tmp = getFoo(); x = tmp;
                 tmp.getBar() *)
              let lhs_access_path =
                Domain.LocalAccessPath.make
                  (HilExp.AccessExpression.to_access_path lhs_ae)
                  caller_pname
              in
              let rhs_access_path =
                Domain.LocalAccessPath.make
                  (HilExp.AccessExpression.to_access_path rhs_ae)
                  caller_pname
              in
              let astate =
                try
                  let call_set = Domain.find rhs_access_path astate in
                  Domain.remove rhs_access_path astate |> Domain.add lhs_access_path call_set
                with Caml.Not_found -> astate
              in
              Domain.assign ~lhs:lhs_access_path ~rhs:rhs_access_path astate
          | _ ->
              astate
        in
        if HilExp.AccessExpression.is_return_var lhs_ae then Domain.call_return astate else astate
    | _ ->
        astate


  let pp_session_name _node fmt = F.pp_print_string fmt LithoContext.session_name
end

module MakeAnalyzer (LithoContext : LithoContext with type summary = Domain.summary) = struct
  module TF = TransferFunctions (ProcCfg.Normal) (LithoContext)
  module A = LowerHil.MakeAbstractInterpreter (TF)

  let init_extras summary =
    let get_proc_summary_and_formals callee_pname =
      Ondemand.analyze_proc_name ~caller_summary:summary callee_pname
      |> Option.bind ~f:(fun summary ->
             TF.Payload.of_summary summary
             |> Option.map ~f:(fun payload ->
                    (payload, Summary.get_proc_desc summary |> Procdesc.get_pvar_formals) ) )
    in
    {get_proc_summary_and_formals}


  let checker {Callbacks.summary; exe_env} =
    let proc_desc = Summary.get_proc_desc summary in
    let proc_name = Summary.get_proc_name summary in
    let tenv = Exe_env.get_tenv exe_env (Summary.get_proc_name summary) in
    let proc_data = ProcData.make summary tenv (init_extras summary) in
    let initial = Domain.init tenv proc_name (Procdesc.get_pvar_formals proc_desc) in
    match A.compute_post proc_data ~initial with
    | Some post ->
        let is_void_func = Procdesc.get_ret_type proc_desc |> Typ.is_void in
        let post = Domain.get_summary ~is_void_func post in
        let post =
          if LithoContext.should_report proc_desc tenv then LithoContext.report post tenv summary
          else post
        in
        let postprocess (old_astate, new_astate) formal_map : Domain.summary =
          let f_sub access_path = Domain.LocalAccessPath.to_formal_option access_path formal_map in
          (Domain.substitute ~f_sub old_astate, new_astate)
        in
        let payload = postprocess post (FormalMap.make proc_desc) in
        TF.Payload.update_summary payload summary
    | None ->
        summary
end