#include "../../include/winghostty/win32_host.h"

#include <stdint.h>
#include <stdio.h>
#include <windows.h>

typedef struct test_state {
    HWND parent;
    winghostty_host *host;
    winghostty_surface *surface;
    DWORD ui_thread;
    LONG redraw_count;
    LONG focus_count;
    LONG callback_mismatch;
} test_state;

typedef struct render_call {
    winghostty_surface *surface;
    winghostty_surface *other_surface;
    winghostty_result make_current_result;
    winghostty_result other_present_result;
    winghostty_result clear_current_result;
    winghostty_result render_result;
    winghostty_result present_result;
    winghostty_result ui_call_result;
    DWORD thread_id;
    int current_after_make;
    int current_after_other_present;
    int current_after_render;
    int current_after_clear;
} render_call;

static int current_matches(winghostty_surface *surface);
static int current_is_clear(void);

typedef struct teardown_stress {
    winghostty_surface *surface;
    volatile LONG stop;
    volatile LONG entered;
    volatile LONG failures;
} teardown_stress;

static LRESULT CALLBACK parent_window_proc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam
) {
    (void)wparam;
    (void)lparam;
    if (message == WM_NCDESTROY) {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static void on_redraw(void *user_data, winghostty_surface *surface) {
    test_state *state = (test_state *)user_data;
    if ((state->surface != NULL && surface != state->surface) ||
        GetCurrentThreadId() != state->ui_thread) {
        InterlockedIncrement(&state->callback_mismatch);
    }
    InterlockedIncrement(&state->redraw_count);
}

static void on_focus(
    void *user_data,
    winghostty_surface *surface,
    uint8_t focused
) {
    test_state *state = (test_state *)user_data;
    (void)focused;
    if ((state->surface != NULL && surface != state->surface) ||
        GetCurrentThreadId() != state->ui_thread) {
        InterlockedIncrement(&state->callback_mismatch);
    }
    InterlockedIncrement(&state->focus_count);
}

static DWORD WINAPI render_thread(void *parameter) {
    render_call *call = (render_call *)parameter;
    call->thread_id = GetCurrentThreadId();
    call->make_current_result =
        winghostty_surface_make_current(call->surface);
    call->current_after_make = current_matches(call->surface);
    call->other_present_result =
        winghostty_surface_present(call->other_surface);
    call->current_after_other_present = current_matches(call->surface);
    call->render_result = winghostty_surface_render(call->surface);
    call->current_after_render = current_matches(call->surface);
    call->clear_current_result =
        winghostty_surface_clear_current(call->surface);
    call->current_after_clear = current_is_clear();
    call->present_result = winghostty_surface_present(call->surface);

    winghostty_rect bounds = {0, 0, 11, 11};
    call->ui_call_result =
        winghostty_surface_set_bounds(call->surface, &bounds);
    return 0;
}

static int renderer_result_allowed(winghostty_result result) {
    return result == WINGHOSTTY_OK ||
        result == WINGHOSTTY_INVALID_ARGUMENT ||
        result == WINGHOSTTY_WRONG_THREAD ||
        result == WINGHOSTTY_SHUTTING_DOWN ||
        result == WINGHOSTTY_SURFACE_INVALIDATED ||
        result == WINGHOSTTY_RENDERER_ERROR ||
        result == WINGHOSTTY_CONTEXT_ERROR ||
        result == WINGHOSTTY_PRESENT_ERROR;
}

static DWORD WINAPI teardown_stress_thread(void *parameter) {
    teardown_stress *stress = (teardown_stress *)parameter;
    while (InterlockedCompareExchange(&stress->stop, 0, 0) == 0) {
        InterlockedIncrement(&stress->entered);
        winghostty_result result =
            winghostty_surface_make_current(stress->surface);
        if (!renderer_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_render(stress->surface);
        if (!renderer_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_present(stress->surface);
        if (!renderer_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_clear_current(stress->surface);
        if (!renderer_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        Sleep(1);
    }
    return 0;
}

static int fail(const char *message) {
    fprintf(stderr, "win32 host renderer test: %s (error=%lu)\n", message, GetLastError());
    return 1;
}

static int check(int condition, const char *message) {
    return condition ? 0 : fail(message);
}

static int current_matches(winghostty_surface *surface) {
    return wglGetCurrentContext() == winghostty_surface_get_hglrc(surface) &&
        wglGetCurrentDC() == winghostty_surface_get_hdc(surface);
}

static int current_is_clear(void) {
    return wglGetCurrentContext() == NULL && wglGetCurrentDC() == NULL;
}

static HWND create_parent(void) {
    const wchar_t class_name[] = L"WinghosttyHostRendererParent";
    WNDCLASSW parent_class = {
        .style = 0,
        .lpfnWndProc = parent_window_proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(NULL),
        .hIcon = NULL,
        .hCursor = NULL,
        .hbrBackground = NULL,
        .lpszMenuName = NULL,
        .lpszClassName = class_name,
    };
    if (!RegisterClassW(&parent_class) &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return NULL;
    }
    return CreateWindowExW(
        0,
        class_name,
        L"Winghostty host renderer",
        WS_OVERLAPPEDWINDOW,
        0,
        0,
        900,
        700,
        NULL,
        NULL,
        parent_class.hInstance,
        NULL
    );
}

static int run_renderer_contract(test_state *state) {
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 1;
    options.focus = 1;
    options.bounds.width = 320;
    options.bounds.height = 240;
    options.theme = WINGHOSTTY_THEME_DARK;
    options.font_scale = 1.0f;
    options.callbacks.on_redraw = on_redraw;
    options.callbacks.on_focus = on_focus;
    options.user_data = state;
    options.command = "cmd.exe";
    options.cwd = "C:\\";
    options.environment = "TERM=xterm-256color";

    if (winghostty_host_initialize(&state->host) != WINGHOSTTY_OK) {
        return fail("host initialization failed");
    }
    if (check(
            winghostty_host_get_ui_thread_id(state->host) == state->ui_thread,
            "host did not capture the UI thread"
        )) {
        return 1;
    }
    if (check(
            winghostty_host_get_render_thread_id(state->host) == 0,
            "render thread was claimed before rendering"
        )) {
        return 1;
    }

    char command[] = "cmd.exe";
    char cwd[] = "C:\\";
    char environment[] = "TERM=xterm-256color";
    options.command = command;
    options.cwd = cwd;
    options.environment = environment;

    if (winghostty_host_create_surface(
            state->host,
            state->parent,
            &options,
            &state->surface
        ) != WINGHOSTTY_OK ||
        state->surface == NULL) {
        return fail("surface creation failed");
    }
    command[0] = 'X';
    cwd[0] = 'X';
    environment[0] = 'X';

    HWND child = winghostty_surface_get_hwnd(state->surface);
    if (check(child != NULL, "surface HWND was not created") ||
        check(GetParent(child) == state->parent, "surface is not caller-parented") ||
        check(IsChild(state->parent, child), "surface is not a child HWND") ||
        check(winghostty_surface_get_hdc(state->surface) != NULL, "surface HDC missing") ||
        check(winghostty_surface_get_hglrc(state->surface) != NULL, "surface HGLRC missing")) {
        return 1;
    }

    winghostty_rect bounds = {13, 17, 640, 360};
    if (check(
            winghostty_surface_set_bounds(state->surface, &bounds) == WINGHOSTTY_OK,
            "setBounds failed"
        ) ||
        check(
            winghostty_surface_set_visible(state->surface, 0) == WINGHOSTTY_OK &&
                !IsWindowVisible(child),
            "visibility hide failed"
        ) ||
        check(
            winghostty_surface_set_visible(state->surface, 1) == WINGHOSTTY_OK &&
                IsWindowVisible(child),
            "visibility show failed"
        ) ||
        check(
            winghostty_surface_set_theme(state->surface, WINGHOSTTY_THEME_LIGHT) ==
                WINGHOSTTY_OK,
            "theme update failed"
        ) ||
        check(
            winghostty_surface_set_font_scale(state->surface, 1.25f) ==
                WINGHOSTTY_OK,
            "font scale update failed"
        )) {
        return 1;
    }

    if (winghostty_surface_notify_redraw(state->surface) != WINGHOSTTY_OK) {
        return fail("redraw notification failed");
    }
    if (check(state->redraw_count == 1, "redraw callback was not synchronous") ||
        check(state->callback_mismatch == 0, "callback thread or user data mismatch")) {
        return 1;
    }

    winghostty_surface *second = NULL;
    if (winghostty_host_create_surface(
            state->host,
            state->parent,
            &options,
            &second
        ) != WINGHOSTTY_OK ||
        second == NULL) {
        return fail("second surface creation failed");
    }
    HWND second_hwnd = winghostty_surface_get_hwnd(second);
    if (check(
            winghostty_surface_get_hdc(second) !=
                winghostty_surface_get_hdc(state->surface),
            "surfaces unexpectedly share an HDC"
        ) ||
        check(
            winghostty_surface_get_hglrc(second) !=
                winghostty_surface_get_hglrc(state->surface),
            "surfaces unexpectedly share an HGLRC"
        )) {
        return 1;
    }

    render_call call = {
        .surface = state->surface,
        .other_surface = second,
        .make_current_result = WINGHOSTTY_INVALID_ARGUMENT,
        .other_present_result = WINGHOSTTY_INVALID_ARGUMENT,
        .clear_current_result = WINGHOSTTY_INVALID_ARGUMENT,
        .render_result = WINGHOSTTY_INVALID_ARGUMENT,
        .present_result = WINGHOSTTY_INVALID_ARGUMENT,
        .ui_call_result = WINGHOSTTY_INVALID_ARGUMENT,
        .thread_id = 0,
        .current_after_make = 0,
        .current_after_other_present = 0,
        .current_after_render = 0,
        .current_after_clear = 0,
    };
    HANDLE thread = CreateThread(NULL, 0, render_thread, &call, 0, NULL);
    if (check(thread != NULL, "render thread creation failed")) return 1;
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);

    if (call.make_current_result != WINGHOSTTY_OK) {
        fprintf(
            stderr,
            "makeCurrent result=%ld last_error=%lu hdc=%p hglrc=%p\n",
            (long)call.make_current_result,
            (unsigned long)winghostty_surface_get_last_error(state->surface),
            (void *)winghostty_surface_get_hdc(state->surface),
            (void *)winghostty_surface_get_hglrc(state->surface)
        );
        return fail("makeCurrent failed");
    }
    if (check(call.clear_current_result == WINGHOSTTY_OK, "clearCurrent failed") ||
        check(call.current_after_make, "makeCurrent did not bind surface A") ||
        check(
            call.other_present_result == WINGHOSTTY_OK,
            "surface B presentation failed"
        ) ||
        check(
            call.current_after_other_present,
            "surface B presentation did not restore surface A"
        ) ||
        check(call.render_result == WINGHOSTTY_OK, "render/presentation failed") ||
        check(
            call.current_after_render,
            "surface A render lost its persistent context"
        ) ||
        check(call.current_after_clear, "clearCurrent did not clear WGL state") ||
        check(call.present_result == WINGHOSTTY_OK, "explicit presentation failed") ||
        check(call.ui_call_result == WINGHOSTTY_WRONG_THREAD, "UI affinity was not enforced") ||
        check(
            winghostty_host_get_render_thread_id(state->host) == call.thread_id,
            "render thread identity was not retained"
        ) ||
        check(
            winghostty_surface_get_present_count(state->surface) == 2,
            "presentation count did not advance"
        ) ||
        check(
            winghostty_surface_get_present_count(second) == 1,
            "surface B presentation count did not advance"
        )) {
        return 1;
    }

    if (check(
            winghostty_surface_render(state->surface) == WINGHOSTTY_WRONG_THREAD,
            "render affinity was not enforced"
        )) {
        return 1;
    }

    if (winghostty_surface_destroy(second) != WINGHOSTTY_OK ||
        IsWindow(second_hwnd)) {
        return fail("synchronous second-surface teardown failed");
    }

    if (winghostty_surface_destroy(state->surface) != WINGHOSTTY_OK ||
        IsWindow(child) ||
        winghostty_host_deinitialize(state->host) != WINGHOSTTY_OK) {
        return fail("synchronous renderer teardown failed");
    }
    state->surface = NULL;
    state->host = NULL;
    return 0;
}

static int run_persistent_teardown_contract(HWND parent) {
    winghostty_host *host = NULL;
    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK) {
        return fail("persistent-current host initialization failed");
    }

    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;

    winghostty_surface *surface = NULL;
    if (winghostty_host_create_surface(host, parent, &options, &surface) !=
            WINGHOSTTY_OK ||
        surface == NULL ||
        winghostty_surface_make_current(surface) != WINGHOSTTY_OK) {
        winghostty_host_deinitialize(host);
        return fail("persistent-current setup failed");
    }

    HWND child = winghostty_surface_get_hwnd(surface);
    if (winghostty_surface_destroy(surface) != WINGHOSTTY_OK ||
        IsWindow(child) ||
        winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
        return fail("persistent-current teardown failed");
    }
    return 0;
}

static int run_teardown_admission_contract(HWND parent, int destroy_surface) {
    winghostty_host *host = NULL;
    winghostty_surface *surface = NULL;
    winghostty_surface_options options;
    teardown_stress stress = {0};

    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK) {
        return fail("teardown-race host initialization failed");
    }
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;
    if (winghostty_host_create_surface(host, parent, &options, &surface) !=
            WINGHOSTTY_OK ||
        surface == NULL) {
        winghostty_host_deinitialize(host);
        return fail("teardown-race surface creation failed");
    }

    stress.surface = surface;
    HANDLE thread = CreateThread(NULL, 0, teardown_stress_thread, &stress, 0, NULL);
    if (thread == NULL) {
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return fail("teardown-race worker creation failed");
    }
    for (int i = 0; i < 100 && stress.entered == 0; ++i) {
        Sleep(1);
    }
    if (check(stress.entered != 0, "teardown-race worker did not enter renderer")) {
        InterlockedExchange(&stress.stop, 1);
        WaitForSingleObject(thread, 10000);
        CloseHandle(thread);
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return 1;
    }

    winghostty_result teardown_result;
    if (destroy_surface) {
        teardown_result = winghostty_surface_destroy(surface);
    } else {
        teardown_result = winghostty_host_deinitialize(host);
    }
    if (check(
            teardown_result == WINGHOSTTY_OK,
            destroy_surface
                ? "surface destroy admission race failed"
                : "host deinitialize admission race failed"
        )) {
        InterlockedExchange(&stress.stop, 1);
        WaitForSingleObject(thread, 10000);
        CloseHandle(thread);
        if (destroy_surface) winghostty_host_deinitialize(host);
        return 1;
    }

    InterlockedExchange(&stress.stop, 1);
    if (check(
            WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0,
            "teardown-race worker did not terminate"
        )) {
        CloseHandle(thread);
        return 1;
    }
    CloseHandle(thread);
    if (check(stress.failures == 0, "teardown-race returned an invalid result")) {
        return 1;
    }

    if (destroy_surface) {
        if (check(
                winghostty_host_deinitialize(host) == WINGHOSTTY_OK,
                "surface-race host teardown failed"
            )) {
            return 1;
        }
    }
    return 0;
}

int main(void) {
    test_state state = {
        .ui_thread = GetCurrentThreadId(),
    };
    state.parent = create_parent();
    if (!state.parent) return fail("parent window creation failed");
    ShowWindow(state.parent, SW_SHOW);
    UpdateWindow(state.parent);

    if (run_renderer_contract(&state) != 0) {
        if (state.host) winghostty_host_deinitialize(state.host);
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_persistent_teardown_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_teardown_admission_contract(state.parent, 1) != 0 ||
        run_teardown_admission_contract(state.parent, 0) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    const DWORD user_before = GetGuiResources(GetCurrentProcess(), GR_USEROBJECTS);
    const DWORD gdi_before = GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);

    winghostty_host *cycle_host = NULL;
    if (winghostty_host_initialize(&cycle_host) != WINGHOSTTY_OK) {
        DestroyWindow(state.parent);
        return fail("cycle host initialization failed");
    }
    winghostty_surface_options cycle_options;
    winghostty_surface_options_init(&cycle_options);
    cycle_options.visible = 0;
    cycle_options.bounds.width = 80;
    cycle_options.bounds.height = 40;
    cycle_options.command = "cmd.exe";
    cycle_options.cwd = "C:\\";
    cycle_options.environment = "TERM=xterm-256color";

    for (int i = 0; i < 100; ++i) {
        winghostty_surface *surface = NULL;
        if (winghostty_host_create_surface(
                cycle_host,
                state.parent,
                &cycle_options,
                &surface
            ) != WINGHOSTTY_OK ||
            surface == NULL ||
            winghostty_surface_get_hdc(surface) == NULL ||
            winghostty_surface_get_hglrc(surface) == NULL ||
            winghostty_surface_destroy(surface) != WINGHOSTTY_OK) {
            winghostty_host_deinitialize(cycle_host);
            DestroyWindow(state.parent);
            return fail("create/destroy cycle failed");
        }
    }
    if (winghostty_host_deinitialize(cycle_host) != WINGHOSTTY_OK) {
        DestroyWindow(state.parent);
        return fail("cycle host teardown failed");
    }

    if (check(
            GetGuiResources(GetCurrentProcess(), GR_USEROBJECTS) == user_before,
            "USER handle count leaked"
        ) ||
        check(
            GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS) == gdi_before,
            "GDI handle count leaked"
        )) {
        DestroyWindow(state.parent);
        return 1;
    }

    DestroyWindow(state.parent);
    printf("Win32 host renderer contract passed: child HWND/HDC/HGLRC, affinity, presentation, teardown, 100 cycles.\n");
    return 0;
}
