
// zig build-exe cable2.zig -lc -lportaudio && ./cable2

const c = @cImport({
    @cInclude("portaudio.h");
});

const std = @import("std");
const assert = std.debug.assert;
const stdout = std.io.getStdOut().writer();
const print = stdout.print;
const stdin = std.io.getStdIn().reader();

const CHANNELS = 1;
const SAMPLE_FORMAT = c.paFloat32; // 32 bit floating point output
const SAMPLE_RATE = 48_000; // common values are 16k, 48k, 192k
const FRAME_TIME = 0.1; // in seconds
const FRAMES_PER_BUFFER = SAMPLE_RATE * FRAME_TIME; // `* CHANNELS` ?

const Context = struct{
    alloc:std.mem.Allocator,

    args:*std.mem.SplitIterator(u8) = undefined,

    record_stopping:bool = undefined,
    record_stopped:bool = undefined,

    record_buf:*[FRAMES_PER_BUFFER]f32 = undefined,
    record_buf_ready:bool = undefined,
    record_thr:std.Thread = undefined,

    dbg_audio_transfer:[20][FRAMES_PER_BUFFER]f32 = undefined,
    dbg_audio_transfer_record_idx:usize = 0,
    dbg_audio_transfer_play_idx:usize = 0,

    // settings

    global_volume:f32 = 1.0, // can go higher than 1
};

pub fn main() !u8 {

    // allocator
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!allocator.deinit());
    const alloc = allocator.allocator();

    // command-line args
    {
        const argv = std.os.argv;
        if(argv.len > 1){
            try print("This utility does not accept command-line arguments\n", .{});
            return 1;
        }
    }

    // cmd hashmap
    // TODO do this at compile time ?
    var commands_hashmap = std.StringHashMap(@TypeOf(cmd_test)).init(alloc);
    defer commands_hashmap.deinit();

    try commands_hashmap.put("test", cmd_test);
    try commands_hashmap.put("start-recording", cmd_start_recording);
    try commands_hashmap.put("stop-recording", cmd_stop_recording);
    try commands_hashmap.put("start-playing", cmd_start_playing);

    // context
    var ctx = Context{
        .alloc=alloc,
    };

    // audio stuff
    {
        const ret = c.Pa_Initialize();
        if(ret != c.paNoError) return error.cant_init_pa;
    }
    defer {
        const ret = c.Pa_Terminate();
        if(ret != c.paNoError){
            print("ERROR: cannot terminate pa: {s}\n", .{c.Pa_GetErrorText(ret)}) catch {};
        }
    }

    // might as well do it here
    try cmd_start_recording(&ctx);
    defer cmd_stop_recording(&ctx) catch {
        print("ERROR: cannot stop recording\n", .{}) catch {};
    };

    try cmd_start_playing(&ctx);
    // TODO cmd_stop_playing

    // the "main menu"
    var stdin_buf:[200]u8 = undefined;
    while(true){
        try print("> ", .{});
        const cmd_raw = (try stdin.readUntilDelimiterOrEof(stdin_buf[0..], '\n')) orelse { // any changes to the retur value will be reflected in the 1st argument since it's being used as a buffer
            try print("EOF reached, exiting...\n", .{});
            break;
        };

        var args = std.mem.split(u8, cmd_raw, " ");

        const cmd = args.next() orelse {
            continue;
        };

        const callback = commands_hashmap.get(cmd) orelse {
            try print("unknown command: `{s}`\n", .{cmd});
            try print("available commands:\n", .{});
            var iter = commands_hashmap.iterator();
            while(iter.next())|item|{
                try print("    `{s}`\n", .{item.key_ptr.*});
            }
            continue;
        };

        ctx.args = &args;
        try callback(&ctx);
    }

    //assert(!allocator.detectLeaks());

    return 0;
}

fn cmd_test(ctx:*Context) !void {
    var args = ctx.args;
    try print("test succ\n", .{});
    try print("arguments received:\n", .{});
    while(args.next())|arg|{
        try print("    {s}\n", .{arg});
    }
}

fn recording_thr(ctx:*Context) !void { // TODO error handling

    var in_stream: ?*c.PaStream = undefined;

    // init in buffer
    {
        const ret = c.Pa_OpenDefaultStream(
            &in_stream,
            CHANNELS, // number of channels input
            0, // number of channels output
            SAMPLE_FORMAT,
            SAMPLE_RATE, // sample rate
            FRAMES_PER_BUFFER, // frames per buffer, i.e. the number
                            //       of sample frames that PortAudio will
                            //       request from the callback. Many apps
                            //       may want to use
                            //       paFramesPerBufferUnspecified, which
                            //       tells PortAudio to pick the best,
                            //       possibly changing, buffer size.
            null, // callback function
            null, // pointer that will be passed to the callback function
        );

        if(ret != c.paNoError) return error.cant_open_default_stream;
    }
    defer{
        const ret = c.Pa_CloseStream(in_stream);
        if(ret != c.paNoError){
            print("ERROR: cannot close stream: {s}\n", .{c.Pa_GetErrorText(ret)}) catch {};
        }
    }

    {
        const ret = c.Pa_StartStream(in_stream);
        if(ret != c.paNoError){
            print("ERROR: cannot start stream: {s}\n", .{c.Pa_GetErrorText(ret)}) catch {};
        }
    }
    defer{
        const ret = c.Pa_StopStream(in_stream);
        if(ret != c.paNoError){
            print("ERROR: cannot stop stream: {s}\n", .{c.Pa_GetErrorText(ret)}) catch {};
        }
    }

    var in_buf:[FRAMES_PER_BUFFER]f32 = undefined;

    // do the actual recording
    while(!ctx.record_stopping){
        {
            const ret = c.Pa_ReadStream(in_stream, &in_buf, FRAMES_PER_BUFFER);
            if(ret != c.paNoError){
                try print("ERROR: cannot read stream: {s}\n", .{c.Pa_GetErrorText(ret)});
                continue;
            }
        }
        {
            var idx = ctx.dbg_audio_transfer_record_idx + 1;
            if(idx >= ctx.dbg_audio_transfer.len){
                idx = 0;
            }
            std.mem.copy(f32, ctx.dbg_audio_transfer[idx][0..], in_buf[0..]);
            ctx.dbg_audio_transfer_record_idx = idx;
        }

    }

    ctx.record_stopped = true;
}

fn cmd_start_recording(ctx:*Context) !void {
    _ = ctx;

    ctx.record_stopping = false;
    ctx.record_stopped = false;
    ctx.record_buf_ready = false;

    const thr = try std.Thread.spawn(.{}, recording_thr, .{ctx});
    ctx.record_thr = thr;
}

fn cmd_stop_recording(ctx:*Context) !void {
    ctx.record_stopping = true;
    while(!ctx.record_stopped){}

    ctx.record_thr.join();
}

fn cmd_start_playing(ctx:*Context) !void {

    // init out buffer
    var out_stream: ?*c.PaStream = undefined;
    {
        const ret = c.Pa_OpenDefaultStream(
            &out_stream,
            0, // number of channels input
            CHANNELS, // number of channels output
            SAMPLE_FORMAT,
            SAMPLE_RATE, // sample rate
            FRAMES_PER_BUFFER, // frames per buffer, i.e. the number
                            //       of sample frames that PortAudio will
                            //       request from the callback. Many apps
                            //       may want to use
                            //       paFramesPerBufferUnspecified, which
                            //       tells PortAudio to pick the best,
                            //       possibly changing, buffer size.
            null, // callback function
            null, // pointer that will be passed to the callback function
        );

        if(ret != c.paNoError) return error.cant_open_default_stream;
    }
    defer{
        const ret = c.Pa_CloseStream(out_stream);
        if(ret != c.paNoError){
            print("ERROR: cannot close stream: {s}\n", .{c.Pa_GetErrorText(ret)}) catch {};
        }
    }

    {
        const ret = c.Pa_StartStream(out_stream);
        if(ret != c.paNoError){
            print("ERROR: cannot start stream: {s}\n", .{c.Pa_GetErrorText(ret)}) catch {};
        }
    }
    defer{
        const ret = c.Pa_StopStream(out_stream);
        if(ret != c.paNoError){
            print("ERROR: cannot stop stream: {s}\n", .{c.Pa_GetErrorText(ret)}) catch {};
        }
    }

    var speed_up:bool = undefined;
    var skip_once_every_N_frames:u32 = 5; // 5 sounds kinda good; going high seems to fuck this up (this is a bug) (set to 29 and see 4 urself) // using odd values should make it sound a bit better

    while(true){
        speed_up = false;

        const record_idx = ctx.dbg_audio_transfer_record_idx;
        var play_idx = ctx.dbg_audio_transfer_play_idx;
        if(play_idx == record_idx){
            while(play_idx == ctx.dbg_audio_transfer_record_idx){}
        }else if((record_idx == 0) and (play_idx == ctx.dbg_audio_transfer.len - 1)){
            // we gucci
        }else{
            try print("fuck we have delay, let me try to fix that\n", .{});
            speed_up = true;
        }

        var data_to_play = ctx.dbg_audio_transfer[play_idx];

        // volume
        for(data_to_play)|_,idx|{
            data_to_play[idx] *= ctx.global_volume;
        }

        // speed up if needed

        var frames:u32 = FRAMES_PER_BUFFER;

        if(speed_up){

            frames = (frames * (skip_once_every_N_frames-1)) / skip_once_every_N_frames;

            const idx_middle = skip_once_every_N_frames / 2;
            var value_middle:f32 = undefined;

            var idx_read:usize = 0;
            var idx_write:usize = 0;
            const loop_to = data_to_play.len - (data_to_play.len % skip_once_every_N_frames);
            while(idx_read < loop_to){

                if(idx_read % skip_once_every_N_frames == 0){
                    value_middle = data_to_play[idx_read + idx_middle];
                }

                // TODO seems shady; `if` or `else if` ?
                if(idx_read % skip_once_every_N_frames == idx_middle){
                    idx_read += 1;
                    continue;
                }

                var value = data_to_play[idx_read];
                value = (value + value_middle) / (1.0 + (1.0 / @intToFloat(f32, skip_once_every_N_frames - 1)));
                idx_read += 1;

                data_to_play[idx_write] = value;
                idx_write += 1;

            }
        }

        { // play
            const ret = c.Pa_WriteStream(out_stream, &data_to_play, frames);
            if(ret != c.paNoError){
                try print("ERROR: cannot write stream: {s}\n", .{c.Pa_GetErrorText(ret)});
                continue;
            }
        }

        {
            var idx = ctx.dbg_audio_transfer_play_idx + 1;
            if(idx >= ctx.dbg_audio_transfer.len){
                idx = 0;
            }
            ctx.dbg_audio_transfer_play_idx = idx;
        }
    }
}
