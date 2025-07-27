package shader_compile

import fmt "core:fmt"
import os "core:os"
import vk "vendor:vulkan"

ShaderType :: enum u8 {
    vertex_shader,
    fragment_shader
}

compile :: proc(name: string, kind: ShaderType) -> []u8
{
    switch kind {
    case .vertex_shader:
        vertex, error := os.read_entire_file_from_filename_or_err("shaders/compiled/shader_vertex.spv");
        return vertex;
    case .fragment_shader:
        fragment, error := os.read_entire_file_from_filename_or_err("shaders/compiled/shader_fragment.spv");
        return fragment;
    }
    return []u8{};
}