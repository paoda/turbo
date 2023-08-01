const std = @import("std");
const SDL = @import("sdl2");
const gl = @import("gl");
const zgui = @import("zgui");

const nds9 = @import("core/nds9.zig");
const nds7 = @import("core/nds7.zig");

const ppu = @import("core/ppu.zig");
const imgui = @import("ui/imgui.zig");
const emu = @import("core/emu.zig");

const KeyInput = @import("core/nds9/io.zig").KeyInput;

const Allocator = std.mem.Allocator;

const GLuint = gl.GLuint;
const GLsizei = gl.GLsizei;
const SDL_GLContext = *anyopaque;

const nds_width = ppu.screen_width;
const nds_height = ppu.screen_height;

pub const Dimensions = struct { width: u32, height: u32 };

const window_title = "Turbo (Name Pending)";

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
        if (SDL.SDL_GL_SetAttribute(SDL.SDL_GL_CONTEXT_MAJOR_VERSION, 3) < 0) panic();

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

    fn glGetProcAddress(ctx: SDL.SDL_GLContext, proc: [:0]const u8) ?*anyopaque {
        _ = ctx;
        return SDL.SDL_GL_GetProcAddress(proc.ptr);
    }

    pub fn run(self: *Self, nds7_group: nds7.Group, nds9_group: nds9.Group) !void {
        // TODO: Sort this out please

        const objects = opengl_impl.createObjects();
        defer gl.deleteBuffers(3, &[_]GLuint{ objects.vao, objects.vbo, objects.ebo });

        const top_tex = opengl_impl.createScreenTexture(nds9_group.bus.ppu.fb.top(.front));
        const btm_tex = opengl_impl.createScreenTexture(nds9_group.bus.ppu.fb.btm(.front));
        const top_out_tex = opengl_impl.createOutputTexture();
        const btm_out_tex = opengl_impl.createOutputTexture();
        defer gl.deleteTextures(4, &[_]GLuint{ top_tex, top_out_tex, btm_tex, btm_out_tex });

        const top_fbo = try opengl_impl.createFrameBuffer(top_out_tex);
        const btm_fbo = try opengl_impl.createFrameBuffer(btm_out_tex);
        defer gl.deleteFramebuffers(2, &[_]GLuint{ top_fbo, btm_fbo });

        const prog_id = try opengl_impl.compileShaders();
        defer gl.deleteProgram(prog_id);

        var event: SDL.SDL_Event = undefined;

        emu_loop: while (true) {
            emu.runFrame(nds7_group, nds9_group);

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

                        nds9_group.bus.io.keyinput.fetchAnd(~keyinput.raw, .Monotonic);
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

                        nds9_group.bus.io.keyinput.fetchOr(keyinput.raw, .Monotonic);
                    },
                    else => {},
                }
            }

            {
                gl.bindFramebuffer(gl.FRAMEBUFFER, top_fbo);
                defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                gl.viewport(0, 0, nds_width, nds_height);
                opengl_impl.drawScreenTexture(top_tex, prog_id, objects, nds9_group.bus.ppu.fb.top(.front));
            }

            {
                gl.bindFramebuffer(gl.FRAMEBUFFER, btm_fbo);
                defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

                gl.viewport(0, 0, nds_width, nds_height);
                opengl_impl.drawScreenTexture(btm_tex, prog_id, objects, nds9_group.bus.ppu.fb.btm(.front));
            }

            const zgui_redraw = imgui.draw(&self.state, top_out_tex, btm_out_tex, nds9_group.cpu);

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
    // zig fmt: off
    const vertices: [32]f32 = [_]f32{
        // Positions        // Colours      // Texture Coords
         1.0, -1.0, 0.0,    1.0, 0.0, 0.0,  1.0, 1.0, // Top Right
         1.0,  1.0, 0.0,    0.0, 1.0, 0.0,  1.0, 0.0, // Bottom Right
        -1.0,  1.0, 0.0,    0.0, 0.0, 1.0,  0.0, 0.0, // Bottom Left
        -1.0, -1.0, 0.0,    1.0, 1.0, 0.0,  0.0, 1.0, // Top Left
    };

    const indices: [6]u32 = [_]u32{
        0, 1, 3, // First Triangle
        1, 2, 3, // Second Triangle
    };
    // zig fmt: on

    const Objects = struct { vao: GLuint, vbo: GLuint, ebo: GLuint };

    fn drawScreenTexture(tex_id: GLuint, prog_id: GLuint, ids: Objects, buf: []const u8) void {
        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, nds_width, nds_height, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

        // Bind VAO, EBO. VBO not bound
        gl.bindVertexArray(ids.vao); // VAO
        defer gl.bindVertexArray(0);

        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ids.ebo); // EBO
        defer gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);

        // Use compiled frag + vertex shader
        gl.useProgram(prog_id);
        defer gl.useProgram(0);

        gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, null);
    }

    fn compileShaders() !GLuint {
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

        const program = gl.createProgram();
        gl.attachShader(program, vs);
        gl.attachShader(program, fs);
        gl.linkProgram(program);

        return program;
    }

    // Returns the VAO ID since it's used in run()
    fn createObjects() Objects {
        var vao_id: GLuint = undefined;
        var vbo_id: GLuint = undefined;
        var ebo_id: GLuint = undefined;

        gl.genVertexArrays(1, &vao_id);
        gl.genBuffers(1, &vbo_id);
        gl.genBuffers(1, &ebo_id);

        gl.bindVertexArray(vao_id);
        defer gl.bindVertexArray(0);

        gl.bindBuffer(gl.ARRAY_BUFFER, vbo_id);
        defer gl.bindBuffer(gl.ARRAY_BUFFER, 0);

        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo_id);
        defer gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);

        gl.bufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, gl.STATIC_DRAW);
        gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, gl.STATIC_DRAW);

        // Position
        gl.vertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 8 * @sizeOf(f32), null); // lmao
        gl.enableVertexAttribArray(0);
        // Colour
        gl.vertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, 8 * @sizeOf(f32), @ptrFromInt((3 * @sizeOf(f32))));
        gl.enableVertexAttribArray(1);
        // Texture Coord
        gl.vertexAttribPointer(2, 2, gl.FLOAT, gl.FALSE, 8 * @sizeOf(f32), @ptrFromInt((6 * @sizeOf(f32))));
        gl.enableVertexAttribArray(2);

        return .{ .vao = vao_id, .vbo = vbo_id, .ebo = ebo_id };
    }

    fn createScreenTexture(buf: []const u8) GLuint {
        var tex_id: GLuint = undefined;
        gl.genTextures(1, &tex_id);

        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, nds_width, nds_height, 0, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, buf.ptr);

        return tex_id;
    }

    fn createOutputTexture() GLuint {
        var tex_id: GLuint = undefined;
        gl.genTextures(1, &tex_id);

        gl.bindTexture(gl.TEXTURE_2D, tex_id);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, nds_width, nds_height, 0, gl.RGBA, gl.UNSIGNED_INT_8_8_8_8, null);

        return tex_id;
    }

    fn createFrameBuffer(tex_id: GLuint) !GLuint {
        var fbo_id: GLuint = undefined;
        gl.genFramebuffers(1, &fbo_id);

        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo_id);
        defer gl.bindFramebuffer(gl.FRAMEBUFFER, 0);

        gl.framebufferTexture(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, tex_id, 0);

        const draw_buffers: [1]GLuint = .{gl.COLOR_ATTACHMENT0};
        gl.drawBuffers(1, &draw_buffers);

        if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)
            return error.FrameBufferObejctInitFailed;

        return fbo_id;
    }

    const shader = struct {
        const Kind = enum { vertex, fragment };
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
