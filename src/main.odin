package main;import wasm "wasm"

SDL_MAIN_USE_CALLBACKS :: #config(SDL_MAIN_USE_CALLBACKS, 1);

import "base:runtime";
import "core:c"
import "core:math";
import "core:fmt";
import "core:thread";
import "core:sync";
import mem "core:mem";
import os "core:os";
import time "core:time";
import sdl3 "vendor:sdl3";
import vk "vendor:vulkan";
import vk_backend "vk_backend";

vertices := []vk_backend.Vertex{
    {{-0.5, -0.5}, {0.0, 0.0, 1.0}},
    {{ 0.5, -0.5}, {1.0, 0.0, 0.0}},
    {{ 0.5,  0.5}, {0.0, 1.0, 0.0}},
    {{-0.5,  0.5}, {1.0, 0.0, 0.0}},
};
indicies := []u16{
    0, 1, 2,
    2, 3, 0,
};
workerData :: struct {
    waitgroupdata: ^sync.Wait_Group,
    runtimeVertices: ^[dynamic]vk_backend.Vertex,
    ctx: ^vk_backend.Context
};

simulationMutex : sync.Mutex;
runSimulation := true;
tickStart : time.Tick;
runtimeVertices : [dynamic]vk_backend.Vertex;
vkContext : ^vk_backend.Context;

@(private="file")
modifiedContext: runtime.Context

@export
main_start :: proc "c" () {
    context = runtime.default_context()
    context.allocator = wasm.emscripten_allocator()
    context.logger = wasm.create_emscripten_logger()
    modifiedContext = context;
    
    runtime.init_global_temporary_allocator(1*mem.Megabyte)
    main()
}

main :: proc() {
    fmt.println("Hello!");
    
    init : sdl3.AppInit_func = proc "c" (appstate: ^rawptr, argc: c.int, argv: [^]cstring) -> sdl3.AppResult {
        modifiedContext = runtime.default_context();
        context = modifiedContext;
        ctxPointer := new(vk_backend.Context);

        vkContext = ctxPointer;
        using ctx := vkContext;
        
        fmt.println(appstate^, cast(rawptr)ctxPointer);
        
        if !sdl3.Init(sdl3.INIT_VIDEO | sdl3.INIT_EVENTS) {
            fmt.eprintfln("ERROR: Failed to initialize sdl3 {0}", sdl3.GetError());
            os.exit(1);
        }
        
        tickStart = time.tick_now();
        window = sdl3.CreateWindow("Vulkan!", 800, 600, {sdl3.WindowFlags.RESIZABLE, sdl3.WindowFlags.VULKAN, sdl3.WindowFlags.HIGH_PIXEL_DENSITY});
        vk_backend.init(ctx, vertices, indicies);
        runtimeVertices = make([dynamic]vk_backend.Vertex, 4);
        return sdl3.AppResult.CONTINUE;
    }
    
    iter : sdl3.AppIterate_func = proc "c" (appstate: rawptr) -> sdl3.AppResult  {
        context = modifiedContext;
        using ctx := vkContext;
        assert(ctx.instance != {}, "Instance is null");

        draw_frame(ctx);
        return sdl3.AppResult.CONTINUE;
    }
    
    events : sdl3.AppEvent_func = proc "c" (appstate: rawptr, event: ^sdl3.Event) -> sdl3.AppResult {
        context = modifiedContext;
        using ctx := vkContext;
        
        if event.type == sdl3.EventType.QUIT {
            return sdl3.AppResult.SUCCESS;
        }
        #partial switch event.type {
            case .QUIT:
                return sdl3.AppResult.SUCCESS;
            case .WINDOW_RESIZED:
                ctx.framebuffer_resized = true;
                break;
        }

        return sdl3.AppResult.CONTINUE;
    }
    
    quit : sdl3.AppQuit_func = proc "c" (appstate: rawptr, r: sdl3.AppResult) {
        context = modifiedContext;
        using ctx := vkContext;
        vk_backend.deinit(ctx);
        sdl3.DestroyWindow(window);
        delete(runtimeVertices);
        free(vkContext);
    }
    res := sdl3.EnterAppMainCallbacks(0, nil, init, iter, events, quit)
    if res < 0 {
       os.exit(int(res)); 
    }
//    waitGroup : sync.Wait_Group;
//    
//    simulation := thread.create(simulate);
//    simulation.init_context = context;
//    simulation.user_index = 1;
//    simulation.data = &workerData{ 
//        waitgroupdata = &waitGroup, 
//        runtimeVertices = &runtimeVertices,
//        ctx = &ctx
//    };
//    
//    thread.start(simulation);
//    defer sync.wait_group_wait(&waitGroup);
//    defer runSimulation = false;
}

simulate :: proc(thread: ^thread.Thread) {
    dereferenced_value := (cast(^workerData)thread.data);
    runtimeVertices := dereferenced_value.runtimeVertices;
    prevTick := time.tick_now();
    for runSimulation {
        tick := time.tick_now();
        elapsedFromStart := cast(f32)time.duration_seconds(time.tick_diff(tickStart, tick));
        defer prevTick = tick;
        deltaTime := cast(f32)time.duration_seconds(time.tick_diff(prevTick, tick));
        
        change := [2]f32{math.cos(elapsedFromStart), math.sin(elapsedFromStart)};
        
        vertices[0].pos = vertices[0].pos + change * [2]f32{deltaTime, deltaTime};
    }
}

draw_frame :: proc(using ctx: ^vk_backend.Context) {
    if(device == {}){
        fmt.eprintln("Error: There's no device to draw frame");
        os.exit(1);
    }
    vk.WaitForFences(device, 1, &in_flight[curr_frame], true, max(u64));
    image_index: u32;

    res := vk.AcquireNextImageKHR(device, swap_chain.handle, max(u64), image_available[curr_frame], {}, &image_index);
    if res == .ERROR_OUT_OF_DATE_KHR
    {
        framebuffer_resized = false;
        fmt.printfln("{0}, swapchain handle: {1}", res, swap_chain.handle);
        vk_backend.recreate_swap_chain(ctx);
        return;
    }
    else if (res != .SUCCESS && res != .SUBOPTIMAL_KHR)
    {
        fmt.eprintfln("Error: Failed to acquire swap chain image! {0}\n", res);
        os.exit(1);
    }
    
    vk.ResetFences(device, 1, &in_flight[curr_frame]);
    vk.ResetCommandBuffer(command_buffers[curr_frame], {});
    vk_backend.recreate_vertex_buffer(ctx, vertices);
    vk_backend.record_command_buffer(ctx, command_buffers[curr_frame], image_index);

    submit_info: vk.SubmitInfo;
    submit_info.sType = .SUBMIT_INFO;

    wait_semaphores := [?]vk.Semaphore{image_available[curr_frame]};
    wait_stages := [?]vk.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}};
    submit_info.waitSemaphoreCount = 1;
    submit_info.pWaitSemaphores = &wait_semaphores[0];
    submit_info.pWaitDstStageMask = &wait_stages[0];
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &command_buffers[curr_frame];

    signal_semaphores := [?]vk.Semaphore{render_finished[curr_frame]};
    submit_info.signalSemaphoreCount = 1;
    submit_info.pSignalSemaphores = &signal_semaphores[0];

    if res := vk.QueueSubmit(queues[.Graphics], 1, &submit_info, in_flight[curr_frame]); res != .SUCCESS
    {
        fmt.eprintf("Error: Failed to submit draw command buffer!\n");
        os.exit(1);
    }

    present_info: vk.PresentInfoKHR;
    present_info.sType = .PRESENT_INFO_KHR;
    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = &signal_semaphores[0];

    swap_chains := [?]vk.SwapchainKHR{swap_chain.handle};
    present_info.swapchainCount = 1;
    present_info.pSwapchains = &swap_chains[0];
    present_info.pImageIndices = &image_index;
    present_info.pResults = nil;

    res = vk.QueuePresentKHR(queues[.Present], &present_info);

    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR || framebuffer_resized
    {
        framebuffer_resized = false;
        fmt.printfln("{0}, swapchain handle: {1}", res, swap_chain.handle);
        vk_backend.recreate_swap_chain(ctx);
        return;
    }
    else if res != .SUCCESS
    {
        fmt.eprintfln("Error: Failed to acquire swap chain image! {0}\n", res);
        os.exit(1);
    }
    
    curr_frame = (curr_frame + 1) % vk_backend.MAX_FRAMES_IN_FLIGHT;
}