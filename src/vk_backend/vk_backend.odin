package vk_backend

import "base:runtime"
import fmt "core:fmt"
import os "core:os"
import "vendor:sdl3"
import vk "vendor:vulkan"
import shader "../shader"
import mem "core:mem"

MAX_FRAMES_IN_FLIGHT :: 2

Context :: struct
{
    instance: vk.Instance,
    device:   vk.Device,
    physical_device: vk.PhysicalDevice,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    swap_chain: Swapchain,
    pipeline: Pipeline,
    queue_indices:   [QueueFamily]int,
    queues:   [QueueFamily]vk.Queue,
    surface:  vk.SurfaceKHR,
    window:   ^sdl3.Window,
    command_pool: vk.CommandPool,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
    vertex_buffer: Buffer,
    index_buffer: Buffer,

    image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
    render_finished: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
    in_flight: [MAX_FRAMES_IN_FLIGHT]vk.Fence,

    curr_frame: u32,
    framebuffer_resized: bool,
}

Buffer :: struct
{
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    length: int,
    size:   vk.DeviceSize,
}

Pipeline :: struct
{
    handle: vk.Pipeline,
    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
}

QueueFamily :: enum
{
    Graphics,
    Present,
}

Swapchain :: struct
{
    handle: vk.SwapchainKHR,
    images: []vk.Image,
    image_views: []vk.ImageView,
    format: vk.SurfaceFormatKHR,
    extent: vk.Extent2D,
    present_mode: vk.PresentModeKHR,
    image_count: u32,
    support: SwapChainDetails,
    framebuffers: []vk.Framebuffer,
}

SwapChainDetails :: struct
{
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
}

Vertex :: struct
{
    pos: [2]f32,
    color: [3]f32,
}

VERTEX_BINDING := vk.VertexInputBindingDescription{
    binding = 0,
    stride = size_of(Vertex),
    inputRate = .VERTEX,
};

VERTEX_ATTRIBUTES := [?]vk.VertexInputAttributeDescription{
    {
        binding = 0,
        location = 0,
        format = .R32G32_SFLOAT,
        offset = cast(u32)offset_of(Vertex, pos),
    },
    {
        binding = 0,
        location = 1,
        format = .R32G32B32_SFLOAT,
        offset = cast(u32)offset_of(Vertex, color),
    },
};

DEVICE_EXTENSIONS := [?]cstring{
    "VK_KHR_swapchain",
};
VALIDATION_LAYERS := [?]cstring{"VK_LAYER_KHRONOS_validation"};

init :: proc (using ctx: ^Context, vertices: []Vertex, indices: []u16) {
    for &q in &queue_indices do q = -1;
    init_vulkan(ctx, vertices, indices);
}

deinit :: proc (using ctx: ^Context) {
    deinit_vulkan(ctx);
}

init_vulkan :: proc(using ctx: ^Context, vertices: []Vertex, indices: []u16)
{
    context.user_ptr = ctx;
// Load initial Vulkan procedures
    vk.load_proc_addresses(cast(rawptr)sdl3.Vulkan_GetVkGetInstanceProcAddr());

    create_instance(ctx);
    // Load instance-specific procedures after creating instance
    vk.load_proc_addresses_instance(instance);

    extensions := get_extensions();
    for &ext in &extensions do fmt.println(cstring(raw_data(&ext.extensionName)));

    create_debug_messenger(ctx);

    create_surface(ctx);
    get_suitable_device(ctx);
    find_queue_families(ctx);

    fmt.println("Queue Indices:");
    for q, f in queue_indices do fmt.printf("  %v: %d\n", f, q);

    create_device(ctx);

    vk.load_proc_addresses_device(device);

    for &q, f in &queues {
        vk.GetDeviceQueue(device, u32(queue_indices[f]), 0, &q);
    }

    create_swap_chain(ctx);
    create_image_views(ctx);
    create_graphics_pipeline(ctx, "shader.vert", "shader.frag");
    create_framebuffers(ctx);
    create_command_pool(ctx);
    create_vertex_buffer(ctx, vertices);
    create_index_buffer(ctx, indices);
    create_command_buffers(ctx);
    create_sync_objects(ctx);
}

deinit_vulkan :: proc(using ctx: ^Context)
{
    if device != {} {
        vk.DeviceWaitIdle(device);
    }
    
    cleanup_swap_chain(ctx);

    vk.FreeMemory(device, index_buffer.memory, nil);
    vk.DestroyBuffer(device, index_buffer.buffer, nil);

    vk.FreeMemory(device, vertex_buffer.memory, nil);
    vk.DestroyBuffer(device, vertex_buffer.buffer, nil);

    vk.DestroyPipeline(device, pipeline.handle, nil);
    vk.DestroyPipelineLayout(device, pipeline.layout, nil);
    vk.DestroyRenderPass(device, pipeline.render_pass, nil);

    for i in 0..<MAX_FRAMES_IN_FLIGHT
    {
        vk.DestroySemaphore(device, image_available[i], nil);
        vk.DestroySemaphore(device, render_finished[i], nil);
        vk.DestroyFence(device, in_flight[i], nil);

    }
    vk.DestroyCommandPool(device, command_pool, nil);

    vk.DestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil);
    vk.DestroyDevice(device, nil);
    sdl3.Vulkan_DestroySurface(ctx.instance, ctx.surface, nil);
    vk.DestroyInstance(instance, nil);
}

create_instance :: proc(using ctx: ^Context)
{
    app_info: vk.ApplicationInfo;
    app_info.sType = .APPLICATION_INFO;
    app_info.pApplicationName = "Vulkan!";
    app_info.applicationVersion = vk.MAKE_VERSION(0, 0, 1);
    app_info.pEngineName = "No Engine";
    app_info.engineVersion = vk.MAKE_VERSION(1, 0, 0);
    app_info.apiVersion = vk.API_VERSION_1_0;

    create_info: vk.InstanceCreateInfo;
    create_info.sType = .INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;

    instance_extensions_count := u32(0);
    instance_extensions_c := sdl3.Vulkan_GetInstanceExtensions(&instance_extensions_count);
    
    instance_extensions := make([dynamic]cstring, instance_extensions_count + 1);
    assign_at(&instance_extensions, instance_extensions_count, vk.EXT_DEBUG_UTILS_EXTENSION_NAME);

    for ext, i in instance_extensions_c[:instance_extensions_count] {
        assign_at(&instance_extensions, i, ext);
    }
    for ext in instance_extensions {
        fmt.println(ext);
    }
    
    create_info.ppEnabledExtensionNames = raw_data(instance_extensions);
    create_info.enabledExtensionCount = u32(len(instance_extensions));
    
    when ODIN_DEBUG {
        layer_count: u32;
        vk.EnumerateInstanceLayerProperties(&layer_count, nil);
        layers := make([]vk.LayerProperties, layer_count);
        defer delete(layers);
        vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layers));

        outer: for name in VALIDATION_LAYERS {
            for &layer in &layers {
                layer_name := cstring(raw_data(&layer.layerName));
                if name == layer_name do continue outer;
            }
            fmt.eprintf("ERROR: validation layer %q not available\n", name);
            os.exit(1); // Uncomment this to enforce validation layers
        }

        create_info.ppEnabledLayerNames = &VALIDATION_LAYERS[0];
        create_info.enabledLayerCount = len(VALIDATION_LAYERS);
        fmt.println("Validation Layers Loaded");
    } else {
        create_info.enabledLayerCount = 0;
        create_info.pNext = nil;
    }

    if (vk.CreateInstance(&create_info, nil, &instance) != .SUCCESS) {
        fmt.eprintfln("ERROR: Failed to create instance: {0}", sdl3.GetError());
        os.exit(1);
    }

    fmt.printfln("Instance Created: {0}", instance);
}

create_debug_messenger :: proc(using ctx: ^Context) {
    when ODIN_DEBUG {
        create_info: vk.DebugUtilsMessengerCreateInfoEXT;
        create_info.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        create_info.messageSeverity = {.WARNING, .ERROR};
        create_info.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE};
        create_info.pfnUserCallback = debug_callback;

        // Get the function pointer
        vkCreateDebugUtilsMessengerEXT := cast(vk.ProcCreateDebugUtilsMessengerEXT)vk.GetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
        
        if vkCreateDebugUtilsMessengerEXT == nil {
            fmt.eprintfln("ERROR: Could not load vkCreateDebugUtilsMessengerEXT");
            return;
        }

        if vkCreateDebugUtilsMessengerEXT(instance, &create_info, nil, &debug_messenger) != .SUCCESS {
            fmt.eprintfln("ERROR: Failed to create debug messenger");
        }
    }
}

debug_callback :: proc "system" (
messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
messageType: vk.DebugUtilsMessageTypeFlagsEXT,
pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
pUserData: rawptr,
) -> b32 {
    context = runtime.default_context();
    fmt.eprintfln("Validation layer: {}", pCallbackData.pMessage);
    return false;
}

get_extensions :: proc() -> []vk.ExtensionProperties
{
    n_ext: u32;
    vk.EnumerateInstanceExtensionProperties(nil, &n_ext, nil);
    extensions := make([]vk.ExtensionProperties, n_ext);
    vk.EnumerateInstanceExtensionProperties(nil, &n_ext, raw_data(extensions));

    return extensions;
}

create_surface :: proc(using ctx: ^Context)
{
    width, height :i32 = 0, 0;
    sdl3.GetWindowSize(&window^, &width, &height);
    if !sdl3.Vulkan_CreateSurface(window, instance, nil, &surface)
    {
        fmt.eprintfln("ERROR: Failed to create surface {0} {1}", sdl3.GetError(), &instance);
        os.exit(1);
    }
}

check_device_extension_support :: proc(physical_device: vk.PhysicalDevice) -> bool
{
    ext_count: u32;
    vk.EnumerateDeviceExtensionProperties(physical_device, nil, &ext_count, nil);

    available_extensions := make([]vk.ExtensionProperties, ext_count);
    vk.EnumerateDeviceExtensionProperties(physical_device, nil, &ext_count, raw_data(available_extensions));

    for ext in DEVICE_EXTENSIONS
    {
        found: b32;
        for &available in &available_extensions
        {
            if cstring(raw_data(&available.extensionName)) == ext
            {
                found = true;
                break;
            }
        }
        if !found do return false;
    }
    return true;
}

get_suitable_device :: proc(using ctx: ^Context)
{
    device_count: u32;

    vk.EnumeratePhysicalDevices(instance, &device_count, nil);
    if device_count == 0
    {
        fmt.eprintf("ERROR: Failed to find GPUs with Vulkan support\n");
        os.exit(1);
    }
    devices := make([]vk.PhysicalDevice, device_count);
    vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices));

    suitability :: proc(using ctx: ^Context, dev: vk.PhysicalDevice) -> int
    {
        props: vk.PhysicalDeviceProperties;
        features: vk.PhysicalDeviceFeatures;
        vk.GetPhysicalDeviceProperties(dev, &props);
        vk.GetPhysicalDeviceFeatures(dev, &features);

        score := 0;
        if props.deviceType == .DISCRETE_GPU do score += 1000;
        score += cast(int)props.limits.maxImageDimension2D;

        if !features.geometryShader do return 0;
        if !check_device_extension_support(dev) do return 0;

        query_swap_chain_details(ctx, dev);
        if len(swap_chain.support.formats) == 0 || len(swap_chain.support.present_modes) == 0 do return 0;

        return score;
    }
    
    hiscore := 0;
    for dev in devices
    {
        score := suitability(ctx, dev);
        if score > hiscore
        {
            physical_device = dev;
            hiscore = score;
        }
    }
    
    if (hiscore == 0)
    {
        fmt.eprintf("ERROR: Failed to find a suitable GPU\n");
        os.exit(1);
    }
}

find_queue_families :: proc(using ctx: ^Context)
{
    queue_count: u32;
    vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, nil);
    available_queues := make([]vk.QueueFamilyProperties, queue_count);
    vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, raw_data(available_queues));

    for v, i in available_queues
    {
        if .GRAPHICS in v.queueFlags && queue_indices[.Graphics] == -1 do queue_indices[.Graphics] = i;

        present_support: b32;
        vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, u32(i), surface, &present_support);
        if present_support && queue_indices[.Present] == -1 do queue_indices[.Present] = i;

        for q in queue_indices do if q == -1 do continue;
        break;
    }
}

create_device :: proc(using ctx: ^Context)
{
    unique_indices: map[int]b8;
    defer delete(unique_indices);
    for i in queue_indices do unique_indices[i] = true;

    queue_priority := f32(1.0);

    queue_create_infos: [dynamic]vk.DeviceQueueCreateInfo;
    defer delete(queue_create_infos);
    for k, _ in unique_indices
    {
        queue_create_info: vk.DeviceQueueCreateInfo;
        queue_create_info.sType = .DEVICE_QUEUE_CREATE_INFO;
        queue_create_info.queueFamilyIndex = u32(queue_indices[.Graphics]);
        queue_create_info.queueCount = 1;
        queue_create_info.pQueuePriorities = &queue_priority;
        append(&queue_create_infos, queue_create_info);
    }
    
    device_features: vk.PhysicalDeviceFeatures;
    device_create_info: vk.DeviceCreateInfo;
    device_create_info.sType = .DEVICE_CREATE_INFO;
    device_create_info.enabledExtensionCount = u32(len(DEVICE_EXTENSIONS));
    device_create_info.ppEnabledExtensionNames = &DEVICE_EXTENSIONS[0];
    device_create_info.pQueueCreateInfos = raw_data(queue_create_infos);
    device_create_info.queueCreateInfoCount = u32(len(queue_create_infos));
    device_create_info.pEnabledFeatures = &device_features;
    device_create_info.enabledLayerCount = 0;

    if vk.CreateDevice(physical_device, &device_create_info, nil, &device) != .SUCCESS
    {
        fmt.eprintln("ERROR: Failed to create logical device\n");
        os.exit(1);
    }
}

query_swap_chain_details :: proc(using ctx: ^Context, dev: vk.PhysicalDevice)
{
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(dev, surface, &swap_chain.support.capabilities);

    format_count: u32;

    result := vk.GetPhysicalDeviceSurfaceFormatsKHR(dev, surface, &format_count, nil);
    if(result != .SUCCESS) {
        fmt.eprintfln("ERROR: Failed to get physical device formats {0}", result)
    }
    if format_count > 0
    {
        swap_chain.support.formats = make([]vk.SurfaceFormatKHR, format_count);
        
        fmt.println("Getting formats into formats var");
        vk.GetPhysicalDeviceSurfaceFormatsKHR(dev, surface, &format_count, raw_data(swap_chain.support.formats));
    }
    
    present_mode_count: u32;
    vk.GetPhysicalDeviceSurfacePresentModesKHR(dev, surface, &present_mode_count, nil);
    if present_mode_count > 0
    {
        swap_chain.support.present_modes = make([]vk.PresentModeKHR, present_mode_count);
        
        vk.GetPhysicalDeviceSurfacePresentModesKHR(dev, surface, &present_mode_count, raw_data(swap_chain.support.present_modes));
    }
}

choose_surface_format :: proc(using ctx: ^Context) -> vk.SurfaceFormatKHR
{
    for v in swap_chain.support.formats
    {
        if v.format == .B8G8R8A8_SRGB && v.colorSpace == .SRGB_NONLINEAR do return v;
    }
    
    assert(len(swap_chain.support.formats) != 0, "Available swap chain formats should never be 0");
    
    return swap_chain.support.formats[0];
}

choose_present_mode :: proc(using ctx: ^Context) -> vk.PresentModeKHR
{
    /*for v in swap_chain.support.present_modes
    {
        if v == .MAILBOX do return v;
    }*/
    
    return .FIFO;
}

choose_swap_extent :: proc(using ctx: ^Context) -> vk.Extent2D
{
//    if (swap_chain.support.capabilities.currentExtent.width != max(u32)) 
//        return swap_chain.support.capabilities.currentExtent;
//    width, height := glfw.GetFramebufferSize(window);
    width, height : i32 = 0, 0;
    sdl3.GetWindowSizeInPixels(&ctx.window^, &width, &height);
    
    
    fmt.printfln("{0} {1}", width, height);
    fmt.printfln("{0} {1}", swap_chain.support.capabilities.maxImageExtent.width, swap_chain.support.capabilities.maxImageExtent.height);
    
    extent := vk.Extent2D{u32(width), u32(height)};

    extent.width = clamp(extent.width, swap_chain.support.capabilities.minImageExtent.width, swap_chain.support.capabilities.maxImageExtent.width);
    extent.height = clamp(extent.height, swap_chain.support.capabilities.minImageExtent.height, swap_chain.support.capabilities.maxImageExtent.height);

    return extent;
}

create_swap_chain :: proc(using ctx: ^Context, old_swapchain: Maybe(vk.SwapchainKHR) = {})
{
    using ctx.swap_chain.support;
    swap_chain.format       = choose_surface_format(ctx);
    swap_chain.present_mode = choose_present_mode(ctx);
    swap_chain.extent       = choose_swap_extent(ctx);
    swap_chain.image_count  = capabilities.minImageCount + 1;

    if capabilities.maxImageCount > 0 && swap_chain.image_count > capabilities.maxImageCount
    {
        swap_chain.image_count = capabilities.maxImageCount;
    }
    
    create_info: vk.SwapchainCreateInfoKHR;
    create_info.sType = .SWAPCHAIN_CREATE_INFO_KHR;
    create_info.surface = surface;
    create_info.minImageCount = swap_chain.image_count;
    create_info.imageFormat = swap_chain.format.format;
    create_info.imageColorSpace = swap_chain.format.colorSpace;
    create_info.imageExtent = swap_chain.extent;
    create_info.imageArrayLayers = 1;
    create_info.imageUsage = {.COLOR_ATTACHMENT};

    queue_family_indices := [len(QueueFamily)]u32{u32(queue_indices[.Graphics]), u32(queue_indices[.Present])};

    if queue_indices[.Graphics] != queue_indices[.Present]
    {
        create_info.imageSharingMode = .CONCURRENT;
        create_info.queueFamilyIndexCount = 2;
        create_info.pQueueFamilyIndices = &queue_family_indices[0];
    }
    else
    {
        create_info.imageSharingMode = .EXCLUSIVE;
        create_info.queueFamilyIndexCount = 0;
        create_info.pQueueFamilyIndices = nil;
    }
    
    create_info.preTransform = capabilities.currentTransform;
    create_info.compositeAlpha = {.OPAQUE};
    create_info.presentMode = swap_chain.present_mode;
    create_info.clipped = true;
    create_info.oldSwapchain = old_swapchain.? or_else vk.SwapchainKHR{};

    if res := vk.CreateSwapchainKHR(device, &create_info, nil, &swap_chain.handle); res != .SUCCESS
    {
        fmt.eprintfln("Error: failed to create swap chain!");
        os.exit(1);
    }
    fmt.printfln("Swapchain creation = old: {0}, new: {1}, {2}, {3}", old_swapchain, swap_chain.handle, swap_chain.extent.width, swap_chain.extent.height);
    
    vk.GetSwapchainImagesKHR(device, swap_chain.handle, &swap_chain.image_count, nil);
    swap_chain.images = make([]vk.Image, swap_chain.image_count);
    vk.GetSwapchainImagesKHR(device, swap_chain.handle, &swap_chain.image_count, raw_data(swap_chain.images));
}

create_image_views :: proc(using ctx: ^Context)
{
    using ctx.swap_chain;

    image_views = make([]vk.ImageView, len(images));

    for _, i in images
    {
        create_info: vk.ImageViewCreateInfo;
        create_info.sType = .IMAGE_VIEW_CREATE_INFO;
        create_info.image = images[i];
        create_info.viewType = .D2;
        create_info.format = format.format;
        create_info.components.r = .IDENTITY;
        create_info.components.g = .IDENTITY;
        create_info.components.b = .IDENTITY;
        create_info.components.a = .IDENTITY;
        create_info.subresourceRange.aspectMask = {.COLOR};
        create_info.subresourceRange.baseMipLevel = 0;
        create_info.subresourceRange.levelCount = 1;
        create_info.subresourceRange.baseArrayLayer = 0;
        create_info.subresourceRange.layerCount = 1;

        if res := vk.CreateImageView(device, &create_info, nil, &image_views[i]); res != .SUCCESS
        {
            fmt.eprintf("Error: failed to create image view!");
            os.exit(1);
        }
    }
}

create_graphics_pipeline :: proc(using ctx: ^Context, vs_name: string, fs_name: string)
{
    vs_code := shader.compile(vs_name, shader.ShaderType.vertex_shader);
    fs_code := shader.compile(fs_name, shader.ShaderType.fragment_shader);

    defer
    {
        delete(vs_code);
        delete(fs_code);
    }
    
    vs_shader := create_shader_module(ctx, vs_code);
    fs_shader := create_shader_module(ctx, fs_code);
    defer
    {
        vk.DestroyShaderModule(device, vs_shader, nil);
        vk.DestroyShaderModule(device, fs_shader, nil);
    }
    
    vs_info: vk.PipelineShaderStageCreateInfo;
    vs_info.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO;
    vs_info.stage = {.VERTEX};
    vs_info.module = vs_shader;
    vs_info.pName = "main";

    fs_info: vk.PipelineShaderStageCreateInfo;
    fs_info.sType = .PIPELINE_SHADER_STAGE_CREATE_INFO;
    fs_info.stage = {.FRAGMENT};
    fs_info.module = fs_shader;
    fs_info.pName = "main";

    shader_stages := [?]vk.PipelineShaderStageCreateInfo{vs_info, fs_info};

    dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR};
    dynamic_state: vk.PipelineDynamicStateCreateInfo;
    dynamic_state.sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic_state.dynamicStateCount = len(dynamic_states);
    dynamic_state.pDynamicStates = &dynamic_states[0];

    vertex_input: vk.PipelineVertexInputStateCreateInfo;
    vertex_input.sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertex_input.vertexBindingDescriptionCount = 1;
    vertex_input.pVertexBindingDescriptions = &VERTEX_BINDING;
    vertex_input.vertexAttributeDescriptionCount = len(VERTEX_ATTRIBUTES);
    vertex_input.pVertexAttributeDescriptions = &VERTEX_ATTRIBUTES[0];

    input_assembly: vk.PipelineInputAssemblyStateCreateInfo;
    input_assembly.sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = .TRIANGLE_LIST;
    input_assembly.primitiveRestartEnable = false;

    viewport: vk.Viewport;
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = cast(f32)swap_chain.extent.width;
    viewport.height = cast(f32)swap_chain.extent.height;
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;

    scissor: vk.Rect2D;
    scissor.offset = {0, 0};
    scissor.extent = swap_chain.extent;

    viewport_state: vk.PipelineViewportStateCreateInfo;
    viewport_state.sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    rasterizer: vk.PipelineRasterizationStateCreateInfo;
    rasterizer.sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.depthClampEnable = false;
    rasterizer.rasterizerDiscardEnable = false;
    rasterizer.polygonMode = .FILL;
    rasterizer.lineWidth = 1.0;
    rasterizer.cullMode = {.BACK};
    rasterizer.frontFace = .CLOCKWISE;
    rasterizer.depthBiasEnable = false;
    rasterizer.depthBiasConstantFactor = 0.0;
    rasterizer.depthBiasClamp = 0.0;
    rasterizer.depthBiasSlopeFactor = 0.0;

    multisampling: vk.PipelineMultisampleStateCreateInfo;
    multisampling.sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.sampleShadingEnable = false;
    multisampling.rasterizationSamples = {._1};
    multisampling.minSampleShading = 1.0;
    multisampling.pSampleMask = nil;
    multisampling.alphaToCoverageEnable = false;
    multisampling.alphaToOneEnable = false;

    color_blend_attachment: vk.PipelineColorBlendAttachmentState;
    color_blend_attachment.colorWriteMask = {.R, .G, .B, .A};
    color_blend_attachment.blendEnable = true;
    color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA;
    color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
    color_blend_attachment.colorBlendOp = .ADD;
    color_blend_attachment.srcAlphaBlendFactor = .ONE;
    color_blend_attachment.dstAlphaBlendFactor = .ZERO;
    color_blend_attachment.alphaBlendOp = .ADD;

    color_blending: vk.PipelineColorBlendStateCreateInfo;
    color_blending.sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    color_blending.logicOpEnable = false;
    color_blending.logicOp = .COPY;
    color_blending.attachmentCount = 1;
    color_blending.pAttachments = &color_blend_attachment;
    color_blending.blendConstants[0] = 0.0;
    color_blending.blendConstants[1] = 0.0;
    color_blending.blendConstants[2] = 0.0;
    color_blending.blendConstants[3] = 0.0;

    pipeline_layout_info: vk.PipelineLayoutCreateInfo;
    pipeline_layout_info.sType = .PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = 0;
    pipeline_layout_info.pSetLayouts = nil;
    pipeline_layout_info.pushConstantRangeCount = 0;
    pipeline_layout_info.pPushConstantRanges = nil;

    if res := vk.CreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline.layout); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to create pipeline layout!\n");
        os.exit(1);
    }
    
    create_render_pass(ctx);

    pipeline_info: vk.GraphicsPipelineCreateInfo;
    pipeline_info.sType = .GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_info.stageCount = 2;
    pipeline_info.pStages = &shader_stages[0];
    pipeline_info.pVertexInputState = &vertex_input;
    pipeline_info.pInputAssemblyState = &input_assembly;
    pipeline_info.pViewportState = &viewport_state;
    pipeline_info.pRasterizationState = &rasterizer;
    pipeline_info.pMultisampleState = &multisampling;
    pipeline_info.pDepthStencilState = nil;
    pipeline_info.pColorBlendState = &color_blending;
    pipeline_info.pDynamicState = &dynamic_state;
    pipeline_info.layout = pipeline.layout;
    pipeline_info.renderPass = pipeline.render_pass;
    pipeline_info.subpass = 0;
    pipeline_info.basePipelineHandle = vk.Pipeline{};
    pipeline_info.basePipelineIndex = -1;

    if res := vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_info, nil, &pipeline.handle); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to create graphics pipeline!\n");
        os.exit(1);
    }
}

create_shader_module :: proc(using ctx: ^Context, code: []u8) -> vk.ShaderModule
{
    create_info: vk.ShaderModuleCreateInfo;
    create_info.sType = .SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = len(code);
    create_info.pCode = cast(^u32)raw_data(code);

    shader: vk.ShaderModule;
    if res := vk.CreateShaderModule(device, &create_info, nil, &shader); res != .SUCCESS
    {
        fmt.eprintf("Error: Could not create shader module!\n");
        os.exit(1);
    }
    
    return shader;
}

create_render_pass :: proc(using ctx: ^Context)
{
    color_attachment: vk.AttachmentDescription;
    color_attachment.format = swap_chain.format.format;
    color_attachment.samples = {._1};
    color_attachment.loadOp = .CLEAR;
    color_attachment.storeOp = .STORE;
    color_attachment.stencilLoadOp = .DONT_CARE;
    color_attachment.stencilStoreOp = .DONT_CARE;
    color_attachment.initialLayout = .UNDEFINED;
    color_attachment.finalLayout = .PRESENT_SRC_KHR;

    color_attachment_ref: vk.AttachmentReference;
    color_attachment_ref.attachment = 0;
    color_attachment_ref.layout = .COLOR_ATTACHMENT_OPTIMAL;

    subpass: vk.SubpassDescription;
    subpass.pipelineBindPoint = .GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_attachment_ref;

    dependency: vk.SubpassDependency;
    dependency.srcSubpass = vk.SUBPASS_EXTERNAL;
    dependency.dstSubpass = 0;
    dependency.srcStageMask = {.COLOR_ATTACHMENT_OUTPUT};
    dependency.srcAccessMask = {};
    dependency.dstStageMask = {.COLOR_ATTACHMENT_OUTPUT};
    dependency.dstAccessMask = {.COLOR_ATTACHMENT_WRITE};

    render_pass_info: vk.RenderPassCreateInfo;
    render_pass_info.sType = .RENDER_PASS_CREATE_INFO;
    render_pass_info.attachmentCount = 1;
    render_pass_info.pAttachments = &color_attachment;
    render_pass_info.subpassCount = 1;
    render_pass_info.pSubpasses = &subpass;
    render_pass_info.dependencyCount = 1;
    render_pass_info.pDependencies = &dependency;

    if res := vk.CreateRenderPass(device, &render_pass_info, nil, &pipeline.render_pass); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to create render pass!\n");
        os.exit(1);
    }
}

create_framebuffers :: proc(using ctx: ^Context)
{
    swap_chain.framebuffers = make([]vk.Framebuffer, len(swap_chain.image_views));
    
    for v, i in swap_chain.image_views
    {
        attachments := [?]vk.ImageView{v};

        framebuffer_info: vk.FramebufferCreateInfo;
        framebuffer_info.sType = .FRAMEBUFFER_CREATE_INFO;
        framebuffer_info.renderPass = pipeline.render_pass;
        framebuffer_info.attachmentCount = 1;
        framebuffer_info.pAttachments = &attachments[0];
        framebuffer_info.width = swap_chain.extent.width;
        framebuffer_info.height = swap_chain.extent.height;
        framebuffer_info.layers = 1;

        if res := vk.CreateFramebuffer(device, &framebuffer_info, nil, &swap_chain.framebuffers[i]); res != .SUCCESS
        {
            fmt.eprintf("Error: Failed to create framebuffer #%d!\n", i);
            os.exit(1);
        }
    }
}

create_command_pool :: proc(using ctx: ^Context)
{
    pool_info: vk.CommandPoolCreateInfo;
    pool_info.sType = .COMMAND_POOL_CREATE_INFO;
    pool_info.flags = {.RESET_COMMAND_BUFFER};
    pool_info.queueFamilyIndex = u32(queue_indices[.Graphics]);

    if res := vk.CreateCommandPool(device, &pool_info, nil, &command_pool); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to create command pool!\n");
        os.exit(1);
    }
}

create_command_buffers :: proc(using ctx: ^Context)
{
    alloc_info: vk.CommandBufferAllocateInfo;
    alloc_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.commandPool = command_pool;
    alloc_info.level = .PRIMARY;
    alloc_info.commandBufferCount = len(command_buffers);

    if res := vk.AllocateCommandBuffers(device, &alloc_info, &command_buffers[0]); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to allocate command buffers!\n");
        os.exit(1);
    }
}

record_command_buffer :: proc(using ctx: ^Context, buffer: vk.CommandBuffer, image_index: u32)
{
    begin_info: vk.CommandBufferBeginInfo;
    begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = {};
    begin_info.pInheritanceInfo = nil;

    if res := vk.BeginCommandBuffer(buffer,  &begin_info); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to begin recording command buffer!\n");
        os.exit(1);
    }
    
    render_pass_info: vk.RenderPassBeginInfo;
    render_pass_info.sType = .RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = pipeline.render_pass;
    render_pass_info.framebuffer = swap_chain.framebuffers[image_index];
    render_pass_info.renderArea.offset = {0, 0};
    render_pass_info.renderArea.extent = swap_chain.extent;

    clear_color: vk.ClearValue;
    clear_color.color.float32 = [4]f32{0.0, 0.0, 0.0, 1.0};
    render_pass_info.clearValueCount = 1;
    render_pass_info.pClearValues = &clear_color;

    vk.CmdBeginRenderPass(buffer, &render_pass_info, .INLINE);

    vk.CmdBindPipeline(buffer, .GRAPHICS, pipeline.handle);

    vertex_buffers := [?]vk.Buffer{vertex_buffer.buffer};
    offsets := [?]vk.DeviceSize{0};
    vk.CmdBindVertexBuffers(buffer, 0, 1, &vertex_buffers[0], &offsets[0]);
    vk.CmdBindIndexBuffer(buffer, index_buffer.buffer, 0, .UINT16);

    viewport: vk.Viewport;
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = f32(swap_chain.extent.width);
    viewport.height = f32(swap_chain.extent.height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    vk.CmdSetViewport(buffer, 0, 1, &viewport);

    scissor: vk.Rect2D;
    scissor.offset = {0, 0};
    scissor.extent = swap_chain.extent;
    vk.CmdSetScissor(buffer, 0, 1, &scissor);

    vk.CmdDrawIndexed(buffer, cast(u32)index_buffer.length, 1, 0, 0, 0);

    vk.CmdEndRenderPass(buffer);

    if res := vk.EndCommandBuffer(buffer); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to record command buffer!\n");
        os.exit(1);
    }
}

create_sync_objects :: proc(using ctx: ^Context)
{
    semaphore_info: vk.SemaphoreCreateInfo;
    semaphore_info.sType = .SEMAPHORE_CREATE_INFO;

    fence_info: vk.FenceCreateInfo;
    fence_info.sType = .FENCE_CREATE_INFO;
    fence_info.flags = {.SIGNALED}
    
    for i in 0..<MAX_FRAMES_IN_FLIGHT
    {
        res := vk.CreateSemaphore(device, &semaphore_info, nil, &image_available[i]);
        if res != .SUCCESS
        {
            fmt.eprintf("Error: Failed to create \"image_available\" semaphore\n");
            os.exit(1);
        }
        res = vk.CreateSemaphore(device, &semaphore_info, nil, &render_finished[i]);
        if res != .SUCCESS
        {
            fmt.eprintf("Error: Failed to create \"render_finished\" semaphore\n");
            os.exit(1);
        }
        res = vk.CreateFence(device, &fence_info, nil, &in_flight[i]);
        if res != .SUCCESS
        {
            fmt.eprintf("Error: Failed to create \"in_flight\" fence\n");
            os.exit(1);
        }
    }
}

recreate_vertex_buffer :: proc(using ctx: ^Context, vertices: []Vertex) {
    vertex_buffer.length = len(vertices);
    vertex_buffer.size = cast(vk.DeviceSize)(len(vertices) * size_of(Vertex));

    staging: Buffer;
    create_buffer(ctx, size_of(Vertex), len(vertices), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, &staging);

    data: rawptr;
    vk.MapMemory(device, staging.memory, 0, vertex_buffer.size, {}, &data);
    mem.copy(data, raw_data(vertices), cast(int)vertex_buffer.size);
    vk.UnmapMemory(device, staging.memory);

    copy_buffer(ctx, staging, vertex_buffer, vertex_buffer.size);

    vk.FreeMemory(device, staging.memory, nil);
    vk.DestroyBuffer(device, staging.buffer, nil);
}

recreate_swap_chain :: proc(using ctx: ^Context)
{
    width, height : i32 = 0, 0;
    sdl3.GetWindowSize(&ctx.window^, &width, &height);
    if width == 0 && height == 0 {
        ctx.framebuffer_resized = true;
        return;
    }
    vk.DeviceWaitIdle(device);
    
    cleanup_framebuffer_and_images(ctx);
    old_handle := swap_chain.handle;
    
    create_swap_chain(ctx);
    

    vk.DestroySwapchainKHR(device, old_handle, nil);

    create_image_views(ctx);
    create_framebuffers(ctx);
    fmt.println("Swapchain recreated");
}

cleanup_framebuffer_and_images :: proc(using ctx: ^Context) {
    for f in swap_chain.framebuffers
    {
        vk.DestroyFramebuffer(device, f, nil);
    }
    for view in swap_chain.image_views
    {
        vk.DestroyImageView(device, view, nil);
    }
}

cleanup_swap_chain :: proc(using ctx: ^Context)
{
    cleanup_framebuffer_and_images(ctx);
    vk.DestroySwapchainKHR(device, swap_chain.handle, nil);
}

create_vertex_buffer :: proc(using ctx: ^Context, vertices: []Vertex)
{
    vertex_buffer.length = len(vertices);
    vertex_buffer.size = cast(vk.DeviceSize)(len(vertices) * size_of(Vertex));

    staging: Buffer;
    create_buffer(ctx, size_of(Vertex), len(vertices), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, &staging);

    data: rawptr;
    vk.MapMemory(device, staging.memory, 0, vertex_buffer.size, {}, &data);
    mem.copy(data, raw_data(vertices), cast(int)vertex_buffer.size);
    vk.UnmapMemory(device, staging.memory);

    create_buffer(ctx, size_of(Vertex), len(vertices), {.VERTEX_BUFFER, .TRANSFER_DST}, {.DEVICE_LOCAL}, &vertex_buffer);
    copy_buffer(ctx, staging, vertex_buffer, vertex_buffer.size);

    vk.FreeMemory(device, staging.memory, nil);
    vk.DestroyBuffer(device, staging.buffer, nil);
}

create_index_buffer :: proc(using ctx: ^Context, indices: []u16)
{
    index_buffer.length = len(indices);
    index_buffer.size = cast(vk.DeviceSize)(len(indices) * size_of(indices[0]));

    staging: Buffer;
    create_buffer(ctx, size_of(indices[0]), len(indices), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}, &staging);

    data: rawptr;
    vk.MapMemory(device, staging.memory, 0, index_buffer.size, {}, &data);
    mem.copy(data, raw_data(indices), cast(int)index_buffer.size);
    vk.UnmapMemory(device, staging.memory);

    create_buffer(ctx, size_of(Vertex), len(indices), {.INDEX_BUFFER, .TRANSFER_DST}, {.DEVICE_LOCAL}, &index_buffer);
    copy_buffer(ctx, staging, index_buffer, index_buffer.size);

    vk.FreeMemory(device, staging.memory, nil);
    vk.DestroyBuffer(device, staging.buffer, nil);
}

copy_buffer :: proc(using ctx: ^Context, src, dst: Buffer, size: vk.DeviceSize)
{
    alloc_info := vk.CommandBufferAllocateInfo{
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        level = .PRIMARY,
        commandPool = command_pool,
        commandBufferCount = 1,
    };

    cmd_buffer: vk.CommandBuffer;
    vk.AllocateCommandBuffers(device, &alloc_info, &cmd_buffer);

    begin_info := vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }
    
    vk.BeginCommandBuffer(cmd_buffer, &begin_info);

    copy_region := vk.BufferCopy{
        srcOffset = 0,
        dstOffset = 0,
        size = size,
    }
    vk.CmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, &copy_region);
    vk.EndCommandBuffer(cmd_buffer);

    submit_info := vk.SubmitInfo{
        sType = .SUBMIT_INFO,
        commandBufferCount = 1,
        pCommandBuffers = &cmd_buffer,
    };

    vk.QueueSubmit(queues[.Graphics], 1, &submit_info, {});
    vk.QueueWaitIdle(queues[.Graphics]);
    vk.FreeCommandBuffers(device, command_pool, 1, &cmd_buffer);
}

find_memory_type :: proc(using ctx: ^Context, type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32
{
    mem_properties: vk.PhysicalDeviceMemoryProperties;
    vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);
    for i in 0..<mem_properties.memoryTypeCount
    {
        if (type_filter & (1 << i) != 0) && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties
        {
            return i;
        }
    }
    
    fmt.eprintf("Error: Failed to find suitable memory type!\n");
    os.exit(1);
}

create_buffer :: proc(using ctx: ^Context, member_size: int, count: int, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: ^Buffer)
{
    buffer_info := vk.BufferCreateInfo{
        sType = .BUFFER_CREATE_INFO,
        size  = cast(vk.DeviceSize)(member_size * count),
        usage = usage,
        sharingMode = .EXCLUSIVE,
    };

    if res := vk.CreateBuffer(device, &buffer_info, nil, &buffer.buffer); res != .SUCCESS
    {
        fmt.eprintf("Error: failed to create buffer\n");
        os.exit(1);
    }
    
    mem_requirements: vk.MemoryRequirements;
    vk.GetBufferMemoryRequirements(device, buffer.buffer, &mem_requirements);

    alloc_info := vk.MemoryAllocateInfo{
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize = mem_requirements.size,
        memoryTypeIndex = find_memory_type(ctx, mem_requirements.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT})
    };

    if res := vk.AllocateMemory(device, &alloc_info, nil, &buffer.memory); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to allocate buffer memory!\n");
        os.exit(1);
    }
    
    vk.BindBufferMemory(device, buffer.buffer, buffer.memory, 0);
}