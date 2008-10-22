open Source
open Dtools
open Theora

let create_encoder ~quality =
  let os = Ogg.Stream.create () in
  let frame_x = Fmt.video_width () in
  let frame_y = Fmt.video_height () in
  (* Theora has a divisible-by-sixteen restriction for the encoded video size. *)
  (* Scale the frame size up to the nearest /16 and calculate offsets. *)
  let video_x = ((frame_x + 15) lsr 4) lsl 4 in
  let video_y = ((frame_y + 15) lsr 4) lsl 4 in
  let frame_x_offset = ((video_x - frame_x) / 2) land (lnot 1) in
  let frame_y_offset = ((video_y - frame_y) / 2) land (lnot 1) in
  let video_r = 100000 in
  let info =
    {
      width = video_x;
      height = video_y;
      frame_width = frame_x;
      frame_height = frame_y;
      offset_x = frame_x_offset;
      offset_y = frame_y_offset;
      fps_numerator = Fmt.video_frames_of_seconds 1.;
      fps_denominator = 1;
      aspect_numerator = 1;
      aspect_denominator = 1;
      colorspace = CS_unspecified;
      target_bitrate = video_r;
      quality = quality;
      quick_p = true;
      version_major = 0;
      version_minor = 0;
      version_subminor = 0;
      dropframes_p = false;
      keyframe_auto_p = true;
      keyframe_frequency = 64;
      keyframe_frequency_force = 64;
      keyframe_data_target_bitrate = (video_r * 3 / 2);
      keyframe_auto_threshold = 80;
      keyframe_mindistance = 8;
      noise_sensitivity = 1;
      sharpness = 1; (* ??? *)
      pixelformat = PF_420
    }
  in
  let enc = Encoder.create info in
    os, enc

(** Output in a ogg theora file *)

class to_file ~filename ~quality source =
  let ((y,y_stride), (u, v, uv_stride) as yuv) = 
    RGB.create_yuv (Fmt.video_width ()) (Fmt.video_height ()) 
  in
  let theora_yuv = 
  {
    Theora.y_width = Fmt.video_width ();
    Theora.y_height = Fmt.video_height ();
    Theora.y_stride = y_stride;
    Theora.uv_width = Fmt.video_width () / 2;
    Theora.uv_height = Fmt.video_height () / 2;
    Theora.uv_stride = uv_stride;
    Theora.y = y;
    Theora.u = u;
    Theora.v = v;
  }
  in
  let convert = 
    Video_converter.find_converter 
      (Video_converter.RGB Video_converter.Rgba_32)
      (Video_converter.YUV Video_converter.Yuvj_420)
  in
object (self)
  inherit Output.output
         ~name:filename ~kind:"output.file.theora" source true

  (* method reset_encoder encoder m = "" *)

  val mutable encoder = None
  val mutable os = None
  val mutable fd = None

  method output_start =
    assert (fd = None) ;
    let oggs, enc = create_encoder ~quality in
      fd <- Some (open_out filename) ;
      os <- Some oggs;
      encoder <- Some enc;
      Encoder.encode_header enc oggs;
      self#send (Ogg.Stream.pageout oggs);
      Encoder.encode_comments oggs [];
      Encoder.encode_tables enc oggs;
      self#send (Ogg.Stream.flush oggs)

  method output_stop =
    match fd with
      | None -> assert false
      | Some v -> close_out v ; fd <- None

  method send b =
    match fd with
      | None -> assert false
      | Some fd -> output_string fd b

  method output_send frame =
    let encoder = Utils.get_some encoder in
    let os = Utils.get_some os in
    let vid = VFrame.get_rgb frame in
    let vid = vid.(0) in (* TODO: handle multiple chans *)
      for i = 0 to VFrame.position frame - 1 do
        convert ~proportional:true 
         (Video_converter.frame_of_internal_rgb vid.(i)) 
         (Video_converter.frame_of_internal_yuv 
           (Fmt.video_width ()) 
           (Fmt.video_height ())
           yuv); (* TODO: custom video size.. *)
        Encoder.encode_buffer encoder os theora_yuv
      done;
      self#send (Ogg.Stream.pagesout os)

  method output_reset = ()
end

let () =
  Lang.add_operator "output.file.theora"
    [
      "quality",
      Lang.int_t,
      Some (Lang.int 100),
      None ;

      "",
      Lang.string_t,
      None,
      Some "Filename where to output the Theora stream." ;

      "", Lang.source_t, None, None
    ]
    ~category:Lang.Output
    ~descr:"Output the source's stream as a Theora file."
    (fun p ->
       let e f v = f (List.assoc v p) in
       let quality = e Lang.to_int "quality" in
       let filename = Lang.to_string (Lang.assoc "" 1 p) in
       let source = Lang.assoc "" 2 p in
         ((new to_file ~filename
             ~quality source):>source))

