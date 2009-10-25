(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2009 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

(** Output a stream to an icecast server using an external encoder *)

type external_encoder = in_channel*out_channel

let priority = Tutils.Non_blocking

exception External_failure

let proto = 
  [  "process",
      Lang.fun_t
       [false,"",
        Lang.list_t (Lang.product_t Lang.string_t Lang.string_t)] 
      Lang.string_t, None, Some "External encoding process. \
                                 Takes initial metadata and return \
                                 the command to start.";
     "samplerate",
     Lang.int_t,
     Some (Lang.int 44100),
     Some "Output sample rate.";
     "header",
      Lang.bool_t, Some (Lang.bool true), Some "Write wav header at \
                 beginning of encoded input.";
     "restart_on_crash",
     Lang.bool_t, Some (Lang.bool false),
     Some "Restart external process when it crashed. If false, \
           liquidsoap exits.";
     "restart_on_new_track", Lang.bool_t, Some (Lang.bool false), 
      Some "Restart encoder on new track.";
     "restart_encoder_delay", Lang.int_t, Some (Lang.int (-1)),
     Some "Restart the encoder after this delay, in seconds."]

let initial_meta =
  ["title","Liquidsoap stream";"artist","The Savonet Team"]
let m = 
  let m = Hashtbl.create 10 in
  List.iter
    (fun (x,y) ->
      Hashtbl.add m x y)
  initial_meta;
  m
let initial_meta = m

class virtual base ~restart_on_new_track ~restart_on_crash 
                   ~header ~restart_encoder_delay 
                   ~samplerate process =
  let cond_m = Mutex.create () in
  let cond = Condition.create () in
  let ratio = 
    (float samplerate) /. (float (Fmt.samples_per_second ()))
  in
object (self)

  method virtual log : Dtools.Log.t

  val mutable encoder : external_encoder option = None

  val mutable is_task = false

  val converter = Audio_converter.Samplerate.create (Fmt.channels ())

  val read_m = Mutex.create ()
  val read = Buffer.create 10
  (** This mutex is crucial in order to
    * manipulate the encoding process well.
    * It should be locked on every creation operations.
    * Also, since the creation can be concurrent, it 
    * is crutial to also lock it _before_ stopping
    * the processus when restarting/resetting.
    * A normal restart looks like:
    *   lock create_m; stop; start; unlock create_m 
    * That way, we make sure we destroy and create atomically. 
    *
    * Hence, this lock is _not_ used in the stop/start 
    * functions. *)
  val create_m = Mutex.create ()

  method encode frame start len =
      let b = AFrame.get_float_pcm frame in
      let start = Fmt.samples_of_ticks start in
      let len = Fmt.samples_of_ticks len in
      (* Resample if needed. *)
      let b,start,len = 
        if ratio = 1. then
          b,start,len
        else
          let b = 
            Audio_converter.Samplerate.resample 
                   converter ratio b start len
          in
          b,0,Array.length b.(0)
      in
      let slen = 2 * len * Array.length b in
      let sbuf = String.create slen in
      ignore(Float_pcm.to_s16le b start len sbuf 0);
      (** Wait for any possible creation.. *)
      Mutex.lock create_m; 
      begin
       match encoder with
         | Some (_,x) ->
             begin
              try
                output_string x sbuf;
                Mutex.unlock create_m
              with
                | _ ->
                  Mutex.unlock create_m; 
                  self#external_reset_on_crash
             end
         | None ->
              Mutex.unlock create_m;
              raise External_failure
      end; 
      Mutex.lock read_m; 
      let ret = Buffer.contents read in
      Buffer.reset read;
      Mutex.unlock read_m;
      ret

  method private external_reset_encoder meta =
    Mutex.lock create_m;
    try
      self#external_stop;
      self#external_start meta;
      Mutex.unlock create_m
    with
      | e ->
           Mutex.unlock create_m;
           raise e

  method external_reset_on_crash =
    if restart_on_crash then
      self#external_reset_encoder initial_meta
    else
      raise External_failure

  method reset_encoder meta = 
    if restart_on_new_track then
      self#external_reset_encoder meta;
    Mutex.lock read_m;
    let ret = Buffer.contents read in
    Buffer.reset read;
    Mutex.unlock read_m;
    ret

  (* Any call of this function should be protected 
   * by a mutex. After locking the mutex, it should be
   * checked that the encoder was not create by another
   * call. *)
  method private external_start meta =
    assert(not is_task);
    self#log#f 2 "Creating external encoder..";
    let process = 
      Lang.to_string (Lang.apply process ["",Lang.metadata meta]) 
    in
    (* output_start must be called with encode = None. *)
    assert(encoder = None);
    let (in_e,out_e as enc) = Unix.open_process process in
    encoder <- Some enc;
    if header then
      begin
        let header =
          Wav.header ~channels:(Fmt.channels ())
                     ~sample_rate:samplerate
                     ~sample_size:16
                     ~big_endian:false ~signed:true ()
        in
        (* Write WAV header *)
        output_string out_e header
      end;
    let sock = Unix.descr_of_in_channel in_e in
    let buf = String.create 10000 in
    let events = [`Read sock]
    in
    let rec pull _ =
      let read () =
        let ret = input in_e buf 0 10000 in
        if ret > 0 then
          begin
            Mutex.lock read_m; 
            Buffer.add_string read (String.sub buf 0 ret);
            Mutex.unlock read_m
          end;
        ret
      in
      let stop () =
        (* Signal the end of the task *)
        Mutex.lock cond_m;
        Condition.signal cond;
        is_task <- false;
        Mutex.unlock cond_m
      in
      try
        let ret = read () in
        if ret > 0 then
          [{ Duppy.Task.
               priority = priority ;
               events   = events ;
               handler  = pull }]
        else
         begin
           self#log#f 4 "Reading task reached end of data";
           stop (); []
         end
      with _ -> 
        stop (); 
        self#external_reset_on_crash; 
        []
    in
    Duppy.Task.add Tutils.scheduler
      { Duppy.Task.
          priority = priority ;
          events   = events ;
          handler  = pull };
    is_task <- true;
    (** Creating restart task. *)
    if restart_encoder_delay > 0 then
      let rec f _ =
        self#log#f 3 "Restarting encoder after delay (%is)" restart_encoder_delay;
        self#external_reset_encoder initial_meta;
        []
      in
      Duppy.Task.add Tutils.scheduler
        { Duppy.Task.
            priority = priority ;
            events   = [`Delay (float restart_encoder_delay)] ;
            handler  = f }

  (* Don't fail if the task has already exited, like in 
   * case of failure for instance.. *)
  method private external_stop =
    match encoder with
      | Some (_,out_e as enc) ->
         begin
           Mutex.lock cond_m;
           try 
             begin
              try
               flush out_e;
               Unix.close (Unix.descr_of_out_channel out_e)
              with
                | _ -> ()
             end;
             if is_task then
               Condition.wait cond cond_m;
             Mutex.unlock cond_m;
             begin
              try 
                ignore(Unix.close_process enc)
              with
                | _ -> ()
             end;
             encoder <- None
           with 
             | e -> 
                 self#log#f 2 "couldn't stop the reading task.";
                 raise e
         end
      | None -> ()
end

class to_file
  ~append ~perm ~dir_perm ~reload_delay 
  ~reload_predicate ~reload_on_metadata
  ~filename ~autostart ~process ~restart_on_new_track
  ~header ~restart_on_crash ~restart_encoder_delay 
  ~infallible ~on_stop ~on_start
  ~samplerate source =
object (self)
  inherit Output.encoded 
            ~infallible ~on_stop ~on_start
            ~name:filename ~kind:"output.file" ~autostart source
  inherit File_output.to_file
            ~reload_delay ~reload_predicate ~reload_on_metadata
            ~append ~perm ~dir_perm filename as to_file
  inherit base ~restart_on_new_track ~header ~samplerate
               ~restart_on_crash ~restart_encoder_delay 
               process as base

  method output_start =
    Mutex.lock create_m;
    base#external_start initial_meta;
    Mutex.unlock create_m;
    to_file#file_start

  method output_stop =
    Mutex.lock create_m;
    base#external_stop;
    Mutex.unlock create_m;
    to_file#file_stop

  method output_reset = 
    Mutex.lock create_m;
    base#external_stop;
    to_file#file_stop;
    base#external_start initial_meta;
    to_file#file_start;
    Mutex.unlock create_m

end

let () =
  Lang.add_operator "output.file.external"
    (proto @ Output.proto @ File_output.proto @
     ["", Lang.source_t, None, None ])
    ~category:Lang.Output
    ~descr:"Output the source's stream as a file, \
            using an external encoding process."
    (fun p _ ->
       let e f v = f (List.assoc v p) in
       let filename = Lang.to_string (Lang.assoc "" 1 p) in
       let source = Lang.assoc "" 2 p in
       let append = Lang.to_bool (List.assoc "append" p) in
       let perm = Lang.to_int (List.assoc "perm" p) in
       let samplerate = Lang.to_int (List.assoc "samplerate" p) in
       let process = List.assoc "process" p in
       let dir_perm = Lang.to_int (List.assoc "dir_perm" p) in
       let reload_predicate = List.assoc "reopen_when" p in
       let reload_delay = Lang.to_float (List.assoc "reopen_delay" p) in
       let reload_on_metadata =
         Lang.to_bool (List.assoc "reopen_on_metadata" p)
       in
       let restart_on_new_track =
         Lang.to_bool (List.assoc "restart_on_new_track" p)
       in
       let restart_on_crash = Lang.to_bool (List.assoc "restart_on_crash" p) in
       let restart_encoder_delay =
         Lang.to_int (List.assoc "restart_encoder_delay" p)
       in
       let autostart = e Lang.to_bool "start" in
       let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
       let on_start =
         let f = List.assoc "on_start" p in
           fun () -> ignore (Lang.apply f [])
       in
       let on_stop =
         let f = List.assoc "on_stop" p in
           fun () -> ignore (Lang.apply f [])
       in
       let header = Lang.to_bool (List.assoc "header" p) in
         ((new to_file ~filename ~restart_encoder_delay
             ~infallible ~on_start ~on_stop
             ~append ~perm ~dir_perm ~reload_delay 
             ~reload_predicate ~reload_on_metadata
             ~autostart ~process ~header ~restart_on_new_track
             ~restart_on_crash ~samplerate source):>Source.source))

class to_pipe
  ~process ~restart_on_new_track 
  ~restart_encoder_delay ~restart_on_crash
  ~infallible ~on_stop ~on_start
  ~header ~autostart ~samplerate source =
object (self)
  inherit Output.encoded 
               ~infallible ~on_stop ~on_start
               ~name:"" ~kind:"output.pipe" ~autostart source
  inherit base ~restart_on_new_track ~restart_on_crash 
               ~restart_encoder_delay ~header 
               ~samplerate process as base

  method send _ = () 

  method output_start = 
    Mutex.lock create_m;
    base#external_start initial_meta;
    Mutex.unlock create_m

  method output_stop = 
    Mutex.lock create_m;
    base#external_stop;
    Mutex.unlock create_m

  method output_reset =
    Mutex.lock create_m;
    base#external_stop;
    base#external_start initial_meta;
    Mutex.unlock create_m
end

let () =
  Lang.add_operator "output.pipe.external"
    ([ "start",
      Lang.bool_t, Some (Lang.bool true),
      Some "Start output threads on operator initialization." ]
      @ proto @ Output.proto
      @ ["", Lang.source_t, None, None ])
    ~category:Lang.Output
    ~descr:"Output the source's stream to an external process."
    (fun p _ ->
       let e f v = f (List.assoc v p) in
       let autostart = e Lang.to_bool "start" in
       let source = Lang.assoc "" 1 p in
       let process = List.assoc "process" p in
       let samplerate = Lang.to_int (List.assoc "samplerate" p) in
       let restart_on_new_track =
         Lang.to_bool (List.assoc "restart_on_new_track" p)
       in
       let restart_on_crash = Lang.to_bool (List.assoc "restart_on_crash" p) in
       let restart_encoder_delay =
         Lang.to_int (List.assoc "restart_encoder_delay" p)
       in
       let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
       let on_start =
         let f = List.assoc "on_start" p in
           fun () -> ignore (Lang.apply f [])
       in
       let on_stop =
         let f = List.assoc "on_stop" p in
           fun () -> ignore (Lang.apply f [])
       in
       let header = Lang.to_bool (List.assoc "header" p) in
         ((new to_pipe ~autostart ~process ~header ~restart_on_new_track
                       ~restart_on_crash ~restart_encoder_delay 
                       ~infallible ~on_start ~on_stop
                       ~samplerate source)
          :>Source.source))
