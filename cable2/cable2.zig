
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

    // threads

    audio_sending_threads:std.ArrayListAligned(std.Thread,null) = undefined,
    audio_receiving_threads:std.ArrayListAligned(std.Thread,null) = undefined,

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
    // TODO put in seperate file?
    var commands_hashmap = std.StringHashMap(@TypeOf(cmd_test)).init(alloc);
    defer commands_hashmap.deinit();

    try commands_hashmap.put("test", cmd_test);
    try commands_hashmap.put("start-recording", cmd_start_recording);
    try commands_hashmap.put("stop-recording", cmd_stop_recording);
    try commands_hashmap.put("start-playing", cmd_start_playing);
    try commands_hashmap.put("wait-for-connection", cmd_wait_for_connection);
    try commands_hashmap.put("connect", cmd_connect);

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

    // might as well start recording
    try cmd_start_recording(&ctx);
    defer cmd_stop_recording(&ctx) catch {
        print("ERROR: cannot stop recording\n", .{}) catch {};
    };

    // debug
    //try cmd_start_playing(&ctx);
    // TODO cmd_stop_playing

    ctx.audio_sending_threads = std.ArrayList(std.Thread).init(alloc);
    defer ctx.audio_sending_threads.deinit();
    ctx.audio_receiving_threads = std.ArrayList(std.Thread).init(alloc);
    defer ctx.audio_receiving_threads.deinit();

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

    //std.Thread
    const sex:std.ArrayListAligned(std.Thread,null) = std.ArrayList(std.Thread).init(ctx.alloc);
    _ = sex;
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

fn cmd_wait_for_connection(ctx:*Context) !void {
    // TODO make it so that the receiver of the connection gets his voice recorded ? or not ?

    var host = std.net.StreamServer.init(.{.reuse_address=true});
    defer host.deinit();

    const addr_str = "0.0.0.0"; // TODO make into a setting?
    const port = 6969; // TODO make into a setting?
    const addr = try std.net.Address.resolveIp(addr_str, port); // can also use parseIp4 parseIp6

    try print("waiting for connection...\n", .{});
    try host.listen(addr);

    const con = try host.accept();
    try print("connection from `{}`\n", .{con}); // TODO con.addr

    const stream = con.stream;

    var idx_play:usize = ctx.dbg_audio_transfer_record_idx;
    // TODO can make this into a new thread
    while(true){
        // TODO very shit, needs to be fixed

        const idx_record = ctx.dbg_audio_transfer_record_idx;

        if(idx_record == idx_play){
            continue;
        }
        
        const data = ctx.dbg_audio_transfer[idx_play];

        // TODO do some audio processing before sending? maybe it's best if we do that in the recording thread, or maybe we should enable doing it on a per-connection basis

        // TODO encryption

        {
            // const len = comptime sex: {
            //     break :sex (@floatToInt(comptime_int, FRAMES_PER_BUFFER) * 4);
            // };
            const data_as_u8 = @ptrCast(*const[]u8, @alignCast(8, data[0..]));
            _ = try stream.write(data_as_u8.*); // TODO can check reutrn just ot be sure
        }

        idx_play += 1;
        idx_play %= ctx.dbg_audio_transfer.len;

    }

}

fn thr_send_audio(ctx:*Context, stream:u1) !void { // TODO rename the other SOMETHING_thr to thr_SOMETHING

    defer stream.close();

    var idx_play:usize = ctx.dbg_audio_transfer_record_idx;
    while(!ctx.record_stopped){
        const idx_record = ctx.dbg_audio_transfer_record_idx;
        if(idx_record == idx_play){
            continue;
        }
        
        const data = ctx.dbg_audio_transfer[idx_play];

        // TODO do some audio processing before sending? maybe it's best if we do that in the recording thread, or maybe we should enable doing it on a per-connection basis

        // TODO encryption

        _ = try stream.write(data); // TODO can check reutrn just ot be sure

        idx_play += 1;
        idx_play %= ctx.dbg_audio_transfer.len;
    }
}

fn cmd_connect(ctx:*Context) !void {
    var args = ctx.args;

    const addr_str = args.next() orelse {
        try print("you need to specify address\n", .{});
        return;
    };
    const port_str = args.next() orelse {
        try print("you need to specify port\n", .{});
        return;
    };
    if(args.next() != null){
        try print("too much arguments provided\n", .{});
        return;
    }

    const port = std.fmt.parseInt(u16, port_str, 10) catch|err| {
        try print("invalid port: `{}`: {}\n", .{port_str, err});
        return;
    };

    const addr = std.net.Address.resolveIp(addr_str, port) catch|err| {
        try print("could not resolve address `{}` on port `{}`: {}\n", .{addr_str, port, err});
        return;
    };

    var stream = std.net.tcpConnectToAddress(addr) catch|err| {
        try print("could not connect to address `{}` on port `{}`: {}\n", .{addr, port, err});
        return;
    };

    try std.Thread.spawn(thr_send_audio, &stream);
}
