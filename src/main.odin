package main;

import "core:math";
import "core:fmt";
import "vendor:glfw";
import vk "vendor:vulkan";
import vk_backend "vk_backend";
import os "core:os";
import "core:thread";
import "core:sync";
import time "core:time";

vertices := []vk_backend.Vertex{
    {{-0.5, -0.5}, {0.0, 0.0, 1.0}},
    {{ 0.5, -0.5}, {1.0, 0.0, 0.0}},
    {{ 0.5,  0.5}, {0.0, 1.0, 0.0}},
    {{-0.5,  0.5}, {1.0, 0.0, 0.0}},
};
workerData :: struct {
    waitgroupdata: ^sync.Wait_Group,
    runtimeVertices: ^[dynamic]vk_backend.Vertex,
    ctx: ^vk_backend.Context
};

simulationMutex : sync.Mutex;
runSimulation := true;
tickStart : time.Tick;

main :: proc() {
    tickStart = time.tick_now();
    
    glfw.Init();
    defer glfw.Terminate();

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API);
    glfw.WindowHint(glfw.RESIZABLE, 1);

    using ctx := vk_backend.Context{};
    window = glfw.CreateWindow(800, 600, "Vulkan", nil, nil);
    defer glfw.DestroyWindow(window);

    glfw.SetWindowUserPointer(window, &ctx);
    glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback);
    
    indicies := []u16{
        0, 1, 2,
        2, 3, 0,
    };
    
    vk_backend.init(&ctx, vertices, indicies);
    defer vk_backend.deinit(&ctx);
    
    runtimeVertices := make([dynamic]vk_backend.Vertex, 4);
    defer delete(runtimeVertices);
    
    waitGroup : sync.Wait_Group;
    
    simulation := thread.create(simulate);
    simulation.init_context = context;
    simulation.user_index = 1;
    simulation.data = &workerData{ 
        waitgroupdata = &waitGroup, 
        runtimeVertices = &runtimeVertices,
        ctx = &ctx
    };
    
    thread.start(simulation);
    defer sync.wait_group_wait(&waitGroup);
    defer runSimulation = false;
    
    for !glfw.WindowShouldClose(window)
    {
        glfw.PollEvents();
        draw_frame(&ctx);
    }
    
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32)
{
    using ctx := cast(^vk_backend.Context)glfw.GetWindowUserPointer(window);
    framebuffer_resized = true;
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
    vk.WaitForFences(device, 1, &in_flight[curr_frame], true, max(u64));
    image_index: u32;

    res := vk.AcquireNextImageKHR(device, swap_chain.handle, max(u64), image_available[curr_frame], {}, &image_index);
    if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR || framebuffer_resized
    {
        framebuffer_resized = false;
        fmt.printfln("{0}, swapchain handle: {1}", res, swap_chain.handle);
        vk_backend.recreate_swap_chain(ctx);
        return;
    }
    else if res != .SUCCESS
    {
        fmt.eprintf("Error: Failed tp acquire swap chain image!\n");
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

    vk.QueuePresentKHR(queues[.Present], &present_info);
    curr_frame = (curr_frame + 1) % vk_backend.MAX_FRAMES_IN_FLIGHT;
}