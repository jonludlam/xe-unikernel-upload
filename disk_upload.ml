(*
 * Copyright (C) 2011-2013 Citrix Inc
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

(* TODO: automatically resize the image based on the kernel size *)
open Lwt

let (>>|=) m f = m >>= function
| `Error (`Unknown x) -> fail (Failure x)
| `Error `Unimplemented -> fail (Failure "Unimplemented")
| `Error `Is_read_only -> fail (Failure "Is_read_only")
| `Error `Disconnected -> fail (Failure "Disconnected")
| `Ok x -> f x

module Make(B: V1_LWT.BLOCK) = struct

  let upload ~pool ~username ~password ~device =
    B.get_info device >>= fun info ->
    let virtual_size = Int64.mul info.B.size_sectors 512L in

    let sector = Cstruct.create 512 in

    (* Talk to xapi and create the target VDI *)
    let open Xen_api in
    let open Xen_api_lwt_unix in
    let rpc = make pool in
      Session.login_with_password rpc username password "1.0" >>= fun session_id ->
      Lwt.catch (fun _ ->
        Pool.get_all rpc session_id >>= fun pools ->
        let the_pool = List.hd pools in
        Pool.get_default_SR rpc session_id the_pool >>= fun sr ->
        
        VDI.create ~rpc ~session_id ~name_label:"upload_disk" ~name_description:""
          ~sR:sr ~virtual_size ~_type:`user ~sharable:false ~read_only:false
          ~other_config:[] ~xenstore_data:[] ~sm_config:[] ~tags:[] >>= fun vdi ->
        VDI.get_uuid ~rpc ~session_id ~self:vdi >>= fun vdi_uuid ->
        Lwt.catch (fun _ ->
          let authentication = Disk.UserPassword(username, password) in
          let uri = Disk.uri ~pool:(Uri.of_string pool) ~authentication ~vdi in
          Disk.start_upload ~chunked:false ~uri >>= fun oc ->

          let rec loop n =
            if n = info.B.size_sectors
            then return ()
            else begin
              B.read device n [ sector ] >>|= fun () ->
              oc.Data_channel.really_write sector >>= fun () ->
              loop (Int64.succ n)
            end in
          loop 0L >>= fun () ->
          oc.Data_channel.close ()
        ) (function
        | e ->
          Printf.fprintf stderr "Caught: %s, cleaning up\n%!" (Printexc.to_string e);
          VDI.destroy rpc session_id vdi >>= fun () ->
          fail e
        ) >>= fun () ->
        Session.logout rpc session_id >>= fun () ->
        return vdi_uuid
      ) (fun e ->
        Session.logout rpc session_id >>= fun () ->
        fail e)
end
