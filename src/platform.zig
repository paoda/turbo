const std = @import("std");
const SDL = @import("sdl2");
const gl = @import("gl");
const zgui = @import("zgui");

const ppu = @import("core/ppu.zig");
const imgui = @import("ui/imgui.zig");
const emu = @import("core/emu.zig");

const System = @import("core/emu.zig").System;
const KeyInput = @import("core/io.zig").KeyInput;
const Scheduler = @import("core/Scheduler.zig");

const Allocator = std.mem.Allocator;

const GLuint = gl.GLuint;
const GLsizei = gl.GLsizei;
const SDL_GLContext = *anyopaque;

const nds_width = ppu.screen_width;
const nds_height = ppu.screen_height;

pub const Dimensions = struct { width: u32, height: u32 };

const window_title = "Turbo";

pub const Ui = struct {
    const Self = @This();

    window: *SDL.SDL_Window,
    ctx: SDL_GLContext,

    state: imgui.State,

    pub fn init(allocator: Allocator) !Self {
        var state = imgui.State{};

        if (SDL.SDL_Init(SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0) panic();
        if (SDL.SDL_GL_SetAttribute(SDL.SDL_GL_CONTEXT_PROFILE_MASK, SDL.SDL_GL_CONTEXT_PROFILE_CORE) < 0) panic();
        if (SDL.SDL_GL_SetAttribute(SDL.SDL_GL_CONTEXT_MAJOR_VERSION, 3) < 0) panic();
        if (SDL.SDL_GL_SetAttribute(SDL.SDL_GL_CONTEXT_MINOR_VERSION, 3) < 0) panic();

        const window = SDL.SDL_CreateWindow(
            window_title,
            SDL.SDL_WINDOWPOS_CENTERED,
            SDL.SDL_WINDOWPOS_CENTERED,
            @intCast(state.dim.width),
            @intCast(state.dim.height),
            SDL.SDL_WINDOW_OPENGL | SDL.SDL_WINDOW_SHOWN | SDL.SDL_WINDOW_RESIZABLE,
        ) orelse panic();

        const ctx = SDL.SDL_GL_CreateContext(window) orelse panic();
        if (SDL.SDL_GL_MakeCurrent(window, ctx) < 0) panic();

        gl.load(ctx, Self.glGetProcAddress) catch {};
        if (SDL.SDL_GL_SetSwapInterval(0) < 0) panic();

        zgui.init(allocator);
        zgui.plot.init();
        zgui.backend.init(window, ctx, "#version 330 core");

        // zgui.io.setIniFilename(null);

        return Self{
            .window = window,
            .ctx = ctx,
            .state = state,
        };
    }

    pub fn deinit(self: Self, allocator: Allocator) void {
        _ = allocator;
        // self.state.deinit(self.allocator);

        zgui.backend.deinit();
        zgui.plot.deinit();
        zgui.deinit();

        SDL.SDL_GL_DeleteContext(self.ctx);
        SDL.SDL_DestroyWindow(self.window);
        SDL.SDL_Quit();
    }

    fn glGetProcAddress(_: SDL.SDL_GLContext, proc: [:0]const u8) ?*anyopaque {
        return SDL.SDL_GL_GetProcAddress(proc.ptr);
    }

    pub fn run(self: *Self, scheduler: *Scheduler, system: System) !void {
        // TODO: Sort this out please

        const vao_id = opengl_impl.vao();
        defer gl.deleteVertexArrays(1, &[_]GLuint{vao_id});

        const top_tex = opengl_impl.screenTex(system.bus9.ppu.fb.top(.front));
        const btm_tex = opengl_impl.screenTex(system.bus9.ppu.fb.btm(.front));
        const top_out_tex = opengl_impl.outTex();
        const btm_out_tex = opengl_impl.outTex();
        defer gl.deleteTextures(4, &[_]GLuint{ top_tex, top_out_tex, btm_tex, btm_out_tex });

        const top_fbo = try opengl_impl.frameBuffer(top_out_tex);
        const btm_fbo = try opengl_impl.frameBuffer(btm_out_tex);
        defer gl.deleteFramebuffers(2, &[_]GLuint{ top_fbo, btm_fbo });

        const prog_id = try opengl_impl.program();
        defer gl.deleteProgram(prog_id);

        var event: SDL.SDL_Event = undefined;

        emu_loop: while (true) {
            emu.runFrame(scheduler, system);

            while (SDL.SDL_PollEvent(&event) != 0) {
                _ = zgui.backend.processEvent(&event);

                switch (event.type) {
                    SDL.SDL_QUIT => break :emu_loop,
                    SDL.SDL_WINDOWEVENT => {
                        if (event.window.event == SDL.SDL_WINDOWEVENT_RESIZED) {
                            std.log.debug("window resized to: {}x{}", .{ event.window.data1, event.window.data2 });

                            self.state.dim.width = @intCast(event.window.data1);
                            self.state.dim.height = @intCast(event.window.data2);
                        }
                    },
                    SDL.SDL_KEYDOWN => {
                        // TODO: Make use of compare_and_xor?
                        const key_code = event.key.keysym.sym;
                        var keyinput: KeyInput = .{ .raw = 0x0000 };

                        switch (key_code) {
                            SDL.SDLK_UP => keyinput.up.set(),
                            SDL.SDLK_DOWN => keyinput.down.set(),
                            SDL.SDLK_LEFT => keyinput.left.set(),
                            SDL.SDLK_RIGHT => keyinput.right.set(),
                            SDL.SDLK_x => keyinput.a.set(),
                            SDL.SDLK_z => keyinput.b.set(),
                            SDL.SDLK_a => keyinput.shoulder_l.set(),
                            SDL.SDLK_s => keyinput.shoulder_r.set(),
                            SDL.SDLK_RETURN => keyinput.start.set(),
                            SDL.SDLK_RSHIFT => keyinput.select.set(),
                            else => {},
                        }

                        system.bus9.io.shr.keyinput.fetchAnd(~keyinput.raw, .Monotonic);
                    },
                    SDL.SDL_KEYUP => {
                        // TODO: Make use of compare_and_xor?
                        const key_code = event.key.keysym.sym;
                        var keyinput: KeyInput = .{ .raw = 0x0000 };

                        switch (key_code) {
                            SDL.SDLK_UP => keyinput.up.set(),
                            SDL.SDLK_DOWN => keyinput.down.set(),
                            SDL.SDLK_LEFT => keyinput.left.set(),
                            SDL.SDLK_RIGHT => keyinput.right.set(),
                            SDL.SDLK_x => keyinput.a.set(),
                            SDL.SDLK_z => keyinput.b.set(),
                            SDL.SDLK_a => keyinput.shoulder_l.set(),
                            SDL.SDLK_s => keyinput.shoulder_r.set(),
                            SDL.SDLK_RETURN => keyinput.start.set(),
                            SDL.SDLK_RSHIFT => keyinput.select.set(),
                            else => {},
                        }

                        system.bus9.io.shr.keyinput.fetchOr(keyinput.raw, .Monotonic);
                    },
                    else => {},
                }
            }

            {
                gl.bindFramebuffer(gl.FRAMEBUFFER, top_fbo);
                defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                gl.viewport(0, 0, nds_width, nds_height);
                opengl_impl.drawScreen(top_tex, prog_id, vao_id, system.bus9.ppu.fb.top(.front));
            }

            {
                gl.bindFramebuffer(gl.FRAMEBUFFER, btm_fbo);
                defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                gl.viewport(0, 0, nds_width, nds_height);
                opengl_impl.drawScreen(btm_tex, prog_id, vao_id, system.bus9.ppu.fb.btm(.front));
            }

            const zgui_redraw = imgui.draw(&self.state, top_out_tex, btm_out_tex, system);

            if (zgui_redraw) {
                // Background Colour
                const size = zgui.io.getDisplaySize();
                gl.viewport(0, 0, @intFromFloat(size[0]), @intFromFloat(size[1]));
                gl.clearColor(0, 0, 0, 1.0);
                gl.clear(gl.COLOR_BUFFER_BIT);

                zgui.backend.draw();
            }

            SDL.SDL_GL_SwapWindow(self.window);
        }
    }

    pub fn setTitle(self: *@This(), title: [12]u8) void {
        self.state.title = title ++ [_:0]u8{};
    }
};

fn panic() noreturn {
    const str: [*:0]const u8 = SDL.SDL_GetError() orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}

const opengl_impl = struct {
    fn drawScreen(tex_id: GLuint, prog_id: GLuint, vao_id: GLuint, buf: []const u8) void {
        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, nds_width, nds_height, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

        // Bind VAO
        gl.bindVertexArray(vao_id);
        defer gl.bindVertexArray(0);

        // Use compiled frag + vertex shader
        gl.useProgram(prog_id);
        defer gl.useProgram(0);

        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 3);
    }

    fn program() !GLuint {
        const vert_shader = @embedFile("shader/pixelbuf.vert");
        const frag_shader = @embedFile("shader/pixelbuf.frag");

        const vs = gl.createShader(gl.VERTEX_SHADER);
        defer gl.deleteShader(vs);

        gl.shaderSource(vs, 1, &[_][*c]const u8{vert_shader}, 0);
        gl.compileShader(vs);

        if (!shader.didCompile(vs)) return error.VertexCompileError;

        const fs = gl.createShader(gl.FRAGMENT_SHADER);
        defer gl.deleteShader(fs);

        gl.shaderSource(fs, 1, &[_][*c]const u8{frag_shader}, 0);
        gl.compileShader(fs);

        if (!shader.didCompile(fs)) return error.FragmentCompileError;

        const prog = gl.createProgram();
        gl.attachShader(prog, vs);
        gl.attachShader(prog, fs);
        gl.linkProgram(prog);

        return prog;
    }

    fn vao() GLuint {
        var vao_id: GLuint = undefined;
        gl.genVertexArrays(1, &vao_id);

        return vao_id;
    }

    fn screenTex(buf: []const u8) GLuint {
        var tex_id: GLuint = undefined;
        gl.genTextures(1, &tex_id);

        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, nds_width, nds_height, 0, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

        return tex_id;
    }

    fn outTex() GLuint {
        var tex_id: GLuint = undefined;
        gl.genTextures(1, &tex_id);

        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, nds_width, nds_height, 0, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, null);

        return tex_id;
    }

    fn frameBuffer(tex_id: GLuint) !GLuint {
        var fbo_id: GLuint = undefined;
        gl.genFramebuffers(1, &fbo_id);

        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo_id);
        defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        gl.framebufferTexture(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, tex_id, 0);
        gl.drawBuffers(1, &@as(GLuint, gl.COLOR_ATTACHMENT0));

        if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)
            return error.FrameBufferObejctInitFailed;

        return fbo_id;
    }

    const shader = struct {
        const log = std.log.scoped(.shader);

        fn didCompile(id: gl.GLuint) bool {
            var success: gl.GLint = undefined;
            gl.getShaderiv(id, gl.COMPILE_STATUS, &success);

            if (success == 0) err(id);

            return success == 1;
        }

        fn err(id: gl.GLuint) void {
            const buf_len = 512;
            var error_msg: [buf_len]u8 = undefined;

            gl.getShaderInfoLog(id, buf_len, 0, &error_msg);
            log.err("{s}", .{std.mem.sliceTo(&error_msg, 0)});
        }
    };
};
