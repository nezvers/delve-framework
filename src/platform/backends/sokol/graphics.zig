
const std = @import("std");
const debug = @import("../../../debug.zig");
const graphics = @import("../../graphics.zig");
const images = @import("../../../images.zig");
const sokol = @import("sokol");
const shader_default = @import("../../../graphics/shaders/default.glsl.zig");

const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sgapp = sokol.app_gfx_glue;
const debugtext = sokol.debugtext;

pub const Bindings = graphics.Bindings;
pub const Material = graphics.Material;
pub const Vertex = graphics.Vertex;
pub const Texture = graphics.Texture;
pub const Shader = graphics.Shader;

pub const BindingsImpl = struct {
    sokol_bindings: ?sg.Bindings,
    default_sokol_sampler: sg.Sampler = undefined,
    index_type_size: u8 = @sizeOf(u32),

    pub fn init(cfg: graphics.BindingConfig) Bindings {
        var bindingsImpl = BindingsImpl {
            .sokol_bindings = .{},
            .index_type_size = if(cfg.vertex_layout.index_size == .UINT16) @sizeOf(u16) else @sizeOf(u32),
        };

        var bindings: Bindings = Bindings {
            .length = 0,
            .impl = bindingsImpl,
            .config = cfg,
        };

        // Updatable buffers will need to be created ahead-of-time
        if(cfg.updatable) {
            for(cfg.vertex_layout.attributes, 0..) |attr, idx| {
                bindings.impl.sokol_bindings.?.vertex_buffers[idx] = sg.makeBuffer(.{
                    .usage = .STREAM,
                    .size = cfg.vert_len * attr.item_size,
                });
            }

            if(cfg.vertex_layout.has_index_buffer) {
                bindings.impl.sokol_bindings.?.index_buffer = sg.makeBuffer(.{
                    .usage = .STREAM,
                    .type = .INDEXBUFFER,
                    .size = cfg.index_len * bindingsImpl.index_type_size,
                });
            }
        }

        // maybe have a default material instead?
        const samplerDesc = convertFilterModeToSamplerDesc(.NEAREST);
        bindings.impl.default_sokol_sampler = sg.makeSampler(samplerDesc);
        bindings.impl.sokol_bindings.?.fs.samplers[0] = bindings.impl.default_sokol_sampler;

        return bindings;
    }

    pub fn set(self: *Bindings, vertices: anytype, indices: anytype, opt_normals: anytype, opt_tangents: anytype, length: usize) void {
        if(self.impl.sokol_bindings == null) {
            return;
        }

        self.length = length;

        for(self.config.vertex_layout.attributes, 0..) |attr, idx| {
            self.impl.sokol_bindings.?.vertex_buffers[idx] = sg.makeBuffer(.{
                .data = switch(attr.binding) {
                    .VERT_PACKED => sg.asRange(vertices),
                    .VERT_NORMALS => sg.asRange(opt_normals),
                    .VERT_TANGENTS => sg.asRange(opt_tangents),
                },
            });
        }

        if(self.config.vertex_layout.has_index_buffer) {
            self.impl.sokol_bindings.?.index_buffer = sg.makeBuffer(.{
                .type = .INDEXBUFFER,
                .data = sg.asRange(indices),
            });
        }
    }

    pub fn update(self: *Bindings, vertices: anytype, indices: anytype, vert_len: usize, index_len: usize) void {
        if(self.impl.sokol_bindings == null) {
            return;
        }

        self.length = index_len;

        if(index_len == 0)
            return;

        sg.updateBuffer(self.impl.sokol_bindings.?.vertex_buffers[0], sg.asRange(vertices[0..vert_len]));
        sg.updateBuffer(self.impl.sokol_bindings.?.index_buffer, sg.asRange(indices[0..index_len]));

        // TODO: Update normals and tangents as well, if available
    }

    /// Sets the texture that will be used to draw this binding
    pub fn setTexture(self: *Bindings, texture: Texture) void {
        if(texture.sokol_image == null)
            return;

        // set the texture to the default fragment shader image slot
        self.impl.sokol_bindings.?.fs.images[0] = texture.sokol_image.?;
    }

    pub fn updateFromMaterial(self: *Bindings, material: *Material) void {
        for(0..material.textures.len) |i| {
            if(material.textures[i] != null)
                self.impl.sokol_bindings.?.fs.images[i] = material.textures[i].?.sokol_image.?;
        }

        // bind samplers
        for(material.sokol_samplers, 0..) |sampler, i| {
            if(sampler) |s|
                self.impl.sokol_bindings.?.fs.samplers[i] = s;
        }

        // also set shader uniforms here?
    }

    /// Destroy our binding
    pub fn destroy(self: *Bindings) void {
        for(self.config.vertex_layout.attributes, 0..) |_, idx| {
            sg.destroyBuffer(self.impl.sokol_bindings.?.vertex_buffers[idx]);
        }

        if(self.config.vertex_layout.has_index_buffer)
            sg.destroyBuffer(self.impl.sokol_bindings.?.index_buffer);

        sg.destroySampler(self.impl.default_sokol_sampler);
    }

    /// Resize buffers used by our binding. Will destroy buffers and recreate them!
    pub fn resize(self: *Bindings, vertex_len: usize, index_len: usize) void {
        if(!self.config.updatable)
            return;

        // debug.log("Resizing buffer! {}x{}", .{vertex_len, index_len});

        const vert_layout = self.config.vertex_layout;

        // destory the old index buffer
        if(vert_layout.has_index_buffer)
            sg.destroyBuffer(self.impl.sokol_bindings.?.index_buffer);

        // destroy all the old vertex buffers
        for(vert_layout.attributes, 0..) |_, idx| {
            sg.destroyBuffer(self.impl.sokol_bindings.?.vertex_buffers[idx]);
        }

        // create new index buffer
        if(vert_layout.has_index_buffer) {
            self.impl.sokol_bindings.?.index_buffer = sg.makeBuffer(.{
                .usage = .STREAM,
                .type = .INDEXBUFFER,
                .size = index_len * self.impl.index_type_size,
            });
        }

        // create new vertex buffers
        for(vert_layout.attributes, 0..) |attr, idx| {
            self.impl.sokol_bindings.?.vertex_buffers[idx] = sg.makeBuffer(.{
                .usage = .STREAM,
                .size = vertex_len * attr.item_size,
            });
        }
    }

    pub fn drawSubset(bindings: *Bindings, start: u32, end: u32, shader: *Shader) void {
        if(bindings.impl.sokol_bindings == null or shader.impl.sokol_pipeline == null)
            return;

        shader.apply();

        sg.applyBindings(bindings.impl.sokol_bindings.?);
        sg.draw(start, end, 1);
    }
};

pub const ShaderImpl = struct {
    sokol_pipeline: ?sg.Pipeline,
    sokol_shader_desc: sg.ShaderDesc,

    /// Create a new shader using the default
    pub fn initDefault(cfg: graphics.ShaderConfig, layout: graphics.VertexLayout) Shader {
        const shader_desc = shader_default.defaultShaderDesc(sg.queryBackend());
        return initSokolShader(cfg, layout, shader_desc);
    }

    /// Creates a shader from a shader built in as a zig file
    pub fn initFromBuiltin(cfg: graphics.ShaderConfig, layout: graphics.VertexLayout, comptime builtin: anytype) ?Shader {
        const shader_desc_fn = getBuiltinSokolCreateFunction(builtin);
        if(shader_desc_fn == null)
            return null;

        return initSokolShader(cfg, layout, shader_desc_fn.?(sg.queryBackend()));
    }

    pub fn cloneFromShader(cfg: graphics.ShaderConfig, shader: ?Shader) Shader {
        if(shader == null)
            return initDefault(cfg, graphics.getDefaultVertexLayout());

        return initSokolShader(cfg, shader.?.vertex_layout, shader.?.impl.sokol_shader_desc);
    }

    /// Find the function in the builtin that can actually make the ShaderDesc
    fn getBuiltinSokolCreateFunction(comptime builtin: anytype) ?fn(sg.Backend) sg.ShaderDesc {
        comptime {
            const decls = @typeInfo(builtin).Struct.decls;
            for (decls) |d| {
                const field = @field(builtin, d.name);
                const field_type = @typeInfo(@TypeOf(field));
                if(field_type == .Fn) {
                    const fn_info = field_type.Fn;
                    if(fn_info.return_type == sg.ShaderDesc) {
                        return field;
                    }
                }
            }
        }
        return null;
    }

    /// Create a shader from a Sokol Shader Description - useful for loading built-in shaders
    pub fn initSokolShader(cfg: graphics.ShaderConfig, layout: graphics.VertexLayout, shader_desc: sg.ShaderDesc) Shader {
        const shader = sg.makeShader(shader_desc);

        // TODO: Fill in the rest of these values!
        var num_fs_images: u8 = 0;
        for(0..5) |i| {
            if(shader_desc.fs.images[i].used) {
                num_fs_images += 1;
            } else {
                break;
            }
        }

        var pipe_desc: sg.PipelineDesc = .{
            .index_type = if(layout.index_size == .UINT16) .UINT16 else .UINT32,
            .shader = shader,
            .depth = .{
                .compare = convertCompareFunc(cfg.depth_compare),
                .write_enabled = cfg.depth_write_enabled,
            },
            .cull_mode = convertCullMode(cfg.cull_mode),
        };

        // Set the vertex attributes
        for(cfg.vertex_attributes, 0..) |attr, idx| {
            pipe_desc.layout.attrs[idx].format = convertVertexFormat(attr.attr_type);

            // Find which binding slot we should use by looking at our layout
            for(layout.attributes) |la| {
                if(attr.binding == la.binding) {
                    pipe_desc.layout.attrs[idx].buffer_index = la.buffer_slot;
                    break;
                }
            }
        }

        // apply blending values
        pipe_desc.colors[0].blend = convertBlendMode(cfg.blend_mode);

        defer graphics.next_shader_handle += 1;
        return Shader {
            .impl = .{
                .sokol_pipeline = sg.makePipeline(pipe_desc),
                .sokol_shader_desc = shader_desc,
            },
            .handle = graphics.next_shader_handle,
            .cfg = cfg,
            .fs_texture_slots = num_fs_images,
            .vertex_attributes = cfg.vertex_attributes,
            .vertex_layout = layout,
        };
    }

    pub fn apply(self: *Shader) void {
        if(self.impl.sokol_pipeline == null)
            return;

        sg.applyPipeline(self.impl.sokol_pipeline.?);

        // apply uniform blocks
        for(self.vs_uniform_blocks, 0..) |block, i| {
            if(block) |b|
                sg.applyUniforms(.VS, @intCast(i), sg.Range{ .ptr = b.ptr, .size = b.size });
        }

        for(self.fs_uniform_blocks, 0..) |block, i| {
            if(block) |b|
                sg.applyUniforms(.FS, @intCast(i), sg.Range{ .ptr = b.ptr, .size = b.size });
        }
    }

    pub fn setParams(self: *Shader, params: graphics.ShaderParams) void {
        self.params = params;
    }
};

/// Converts our FilterMode to a sokol sampler description
fn convertFilterModeToSamplerDesc(filter: graphics.FilterMode) sg.SamplerDesc {
    const filter_mode = if (filter == .LINEAR) sg.Filter.LINEAR else sg.Filter.NEAREST;
    return sg.SamplerDesc {
        .min_filter = filter_mode,
        .mag_filter = filter_mode,
        .mipmap_filter = filter_mode,
    };
}

/// Converts our CompareFunc enum to a Sokol CompareFunc enum
fn convertCompareFunc(func: graphics.CompareFunc) sg.CompareFunc {
    // Our enums match up, so this is easy!
    return @enumFromInt(@intFromEnum(func));
}

/// Converts our CullMode enum to a Sokol CullMode enum
fn convertCullMode(mode: graphics.CullMode) sg.CullMode {
    switch(mode) {
        .NONE => {
            return sg.CullMode.NONE;
        },
        .BACK => {
            return sg.CullMode.FRONT;
        },
        .FRONT => {
            return sg.CullMode.BACK;
        }
    }
}

/// Converts our BlendMode enum to a Sokol BlendState struct
fn convertBlendMode(mode: graphics.BlendMode) sg.BlendState {
    switch(mode) {
        .NONE => {
            return sg.BlendState{ };
        },
        .BLEND => {
            return sg.BlendState{
                .enabled = true,
                .src_factor_rgb = sg.BlendFactor.SRC_ALPHA,
                .dst_factor_rgb = sg.BlendFactor.ONE_MINUS_SRC_ALPHA,
                .op_rgb = sg.BlendOp.ADD,
                .src_factor_alpha = sg.BlendFactor.ONE,
                .dst_factor_alpha = sg.BlendFactor.ONE_MINUS_SRC_ALPHA,
                .op_alpha = sg.BlendOp.ADD,
            };
        },
        .ADD => {
            return sg.BlendState{
                .enabled = true,
                .src_factor_rgb = sg.BlendFactor.SRC_ALPHA,
                .dst_factor_rgb = sg.BlendFactor.ONE,
                .op_rgb = sg.BlendOp.ADD,
                .src_factor_alpha = sg.BlendFactor.ZERO,
                .dst_factor_alpha = sg.BlendFactor.ONE,
                .op_alpha = sg.BlendOp.ADD,
            };
        },
        .MUL => {
            return sg.BlendState{
                .enabled = true,
                .src_factor_rgb = sg.BlendFactor.DST_COLOR,
                .dst_factor_rgb = sg.BlendFactor.ONE_MINUS_SRC_ALPHA,
                .op_rgb = sg.BlendOp.ADD,
                .src_factor_alpha = sg.BlendFactor.DST_ALPHA,
                .dst_factor_alpha = sg.BlendFactor.ONE_MINUS_SRC_ALPHA,
                .op_alpha = sg.BlendOp.ADD,
            };
        },
        .MOD => {
            return sg.BlendState{
                .enabled = true,
                .src_factor_rgb = sg.BlendFactor.DST_COLOR,
                .dst_factor_rgb = sg.BlendFactor.ZERO,
                .op_rgb = sg.BlendOp.ADD,
                .src_factor_alpha = sg.BlendFactor.ZERO,
                .dst_factor_alpha = sg.BlendFactor.ONE,
                .op_alpha = sg.BlendOp.ADD,
            };
        },
    }
}

fn convertVertexFormat(format: graphics.VertexFormat) sg.VertexFormat {
    switch(format) {
        .FLOAT2 => { return .FLOAT2; },
        .FLOAT3 => { return .FLOAT3; },
        .FLOAT4 => { return .FLOAT4; },
        .UBYTE4N => { return .UBYTE4N; },
    }
}
