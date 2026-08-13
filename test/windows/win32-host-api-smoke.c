#include "../../include/winghostty/win32_host.h"
#include <string.h>

#define WM_HOST_API_TRIGGER (WM_APP + 1)
#define WM_HOST_API_DONE (WM_APP + 2)
#define WM_HOST_API_AFTER_DESTROY (WM_APP + 3)

typedef struct smoke_context {
    HWND parent;
    winghostty_host *host;
    winghostty_surface *surface;
    DWORD ui_thread;
    DWORD callback_thread;
    LONG redraw_count;
    LONG focus_count;
    LONG callbacks_after_destroy;
    LONG callbacks_wrong_thread;
    LONG callbacks_wrong_user_data;
    int surface_destroyed;
    int loop_active;
    int destroy_on_focus;
    int deinit_on_focus;
    int deinit_on_parent_notify;
    int parent_notify_called;
    int reentrant_called;
    winghostty_result reentrant_result;
} smoke_context;

static smoke_context *parent_context(HWND hwnd) {
    return (smoke_context *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
}

static LRESULT CALLBACK parent_window_proc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam
) {
    (void)lparam;

    smoke_context *context = parent_context(hwnd);
    switch (message) {
        case WM_PARENTNOTIFY:
            if (context &&
                LOWORD(wparam) == WM_CREATE &&
                context->deinit_on_parent_notify &&
                !context->parent_notify_called) {
                context->parent_notify_called = 1;
                context->reentrant_result =
                    winghostty_host_deinitialize(context->host);
            }
            break;
        case WM_HOST_API_TRIGGER:
            if (context && context->surface) {
                InvalidateRect(winghostty_surface_get_hwnd(context->surface), NULL, FALSE);
            }
            return 0;
        case WM_HOST_API_DONE:
        case WM_HOST_API_AFTER_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_NCDESTROY:
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            break;
        default:
            break;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static void record_callback(smoke_context *context, void *user_data) {
    if (GetCurrentThreadId() != context->ui_thread) {
        InterlockedIncrement(&context->callbacks_wrong_thread);
    }
    if (context->surface_destroyed) {
        InterlockedIncrement(&context->callbacks_after_destroy);
    }
    if (user_data != context) {
        InterlockedIncrement(&context->callbacks_wrong_user_data);
    }
    context->callback_thread = GetCurrentThreadId();
}

static void on_redraw(void *user_data, winghostty_surface *surface) {
    smoke_context *context = (smoke_context *)user_data;
    (void)surface;
    record_callback(context, user_data);
    InterlockedIncrement(&context->redraw_count);
    if (context->loop_active) {
        PostMessageW(context->parent, WM_HOST_API_DONE, 0, 0);
    }
}

static void on_focus(void *user_data, winghostty_surface *surface, uint8_t focused) {
    smoke_context *context = (smoke_context *)user_data;
    record_callback(context, user_data);
    InterlockedIncrement(&context->focus_count);
    if (focused == 0 || context->reentrant_called) return;

    if (context->destroy_on_focus) {
        context->reentrant_called = 1;
        context->reentrant_result = winghostty_surface_destroy(surface);
    } else if (context->deinit_on_focus) {
        context->reentrant_called = 1;
        context->reentrant_result = winghostty_host_deinitialize(context->host);
    }
}

static int run_message_loop(void) {
    MSG message;
    for (;;) {
        const BOOL result = GetMessageW(&message, NULL, 0, 0);
        if (result == 0) return 0;
        if (result == -1) return 1;
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

static int fail(void) {
    return 1;
}

int main(void) {
    const wchar_t class_name[] = L"WinghosttyHostApiSmoke";
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
        return fail();
    }

    smoke_context context = {
        .ui_thread = GetCurrentThreadId(),
    };
    context.parent = CreateWindowExW(
        0,
        class_name,
        L"Winghostty host API smoke",
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
    if (!context.parent) return fail();
    SetWindowLongPtrW(
        context.parent,
        GWLP_USERDATA,
        (LONG_PTR)&context
    );

    ShowWindow(context.parent, SW_SHOW);
    UpdateWindow(context.parent);
    SetActiveWindow(context.parent);
    SetFocus(context.parent);

    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 1;
    options.focus = 1;
    options.bounds.width = 400;
    options.bounds.height = 300;
    options.callbacks.on_redraw = on_redraw;
    options.callbacks.on_focus = on_focus;
    options.user_data = &context;
    context.surface_destroyed = 0;

    char command[] = "cmd.exe";
    char cwd[] = "C:\\";
    char environment[] = "TERM=xterm-256color";
    options.command = command;
    options.cwd = cwd;
    options.environment = environment;

    if (winghostty_host_initialize(&context.host) != WINGHOSTTY_OK) {
        DestroyWindow(context.parent);
        return fail();
    }
    context.loop_active = 0;

    context.deinit_on_parent_notify = 1;
    context.parent_notify_called = 0;
    context.reentrant_result = WINGHOSTTY_INVALID_ARGUMENT;
    options.focus = 0;
    winghostty_surface *parent_notify_surface = NULL;
    const winghostty_result parent_notify_create_result =
        winghostty_host_create_surface(
            context.host,
            context.parent,
            &options,
            &parent_notify_surface
        );
    if (parent_notify_create_result != WINGHOSTTY_SHUTTING_DOWN ||
        parent_notify_surface != NULL ||
    !context.parent_notify_called ||
        context.reentrant_result != WINGHOSTTY_OK) {
        if (!context.parent_notify_called && context.host) {
            winghostty_host_deinitialize(context.host);
        }
        DestroyWindow(context.parent);
        return fail();
    }
    context.host = NULL;
    context.deinit_on_parent_notify = 0;

    if (winghostty_host_initialize(&context.host) != WINGHOSTTY_OK) {
        DestroyWindow(context.parent);
        return fail();
    }
    options.focus = 1;

    context.destroy_on_focus = 1;
    winghostty_surface *reentrant_destroy_surface = NULL;
    const winghostty_result destroy_create_result =
        winghostty_host_create_surface(
            context.host,
            context.parent,
            &options,
            &reentrant_destroy_surface
        );
    if (destroy_create_result == WINGHOSTTY_OK ||
        reentrant_destroy_surface != NULL ||
        !context.reentrant_called ||
        context.reentrant_result != WINGHOSTTY_OK) {
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }
    context.destroy_on_focus = 0;
    context.reentrant_called = 0;

    if (winghostty_host_deinitialize(context.host) != WINGHOSTTY_OK) {
        DestroyWindow(context.parent);
        return fail();
    }
    context.host = NULL;

    if (winghostty_host_initialize(&context.host) != WINGHOSTTY_OK) {
        DestroyWindow(context.parent);
        return fail();
    }

    context.deinit_on_focus = 1;
    winghostty_surface *reentrant_deinit_surface = NULL;
    const winghostty_result deinit_create_result =
        winghostty_host_create_surface(
            context.host,
            context.parent,
            &options,
            &reentrant_deinit_surface
        );
    if (deinit_create_result == WINGHOSTTY_OK ||
        reentrant_deinit_surface != NULL ||
        !context.reentrant_called ||
        context.reentrant_result != WINGHOSTTY_OK) {
        return fail();
    }
    context.host = NULL;
    context.deinit_on_focus = 0;
    context.reentrant_called = 0;

    if (winghostty_host_initialize(&context.host) != WINGHOSTTY_OK) {
        DestroyWindow(context.parent);
        return fail();
    }

    InterlockedExchange(&context.redraw_count, 0);
    InterlockedExchange(&context.focus_count, 0);
    InterlockedExchange(&context.callbacks_after_destroy, 0);
    InterlockedExchange(&context.callbacks_wrong_thread, 0);
    InterlockedExchange(&context.callbacks_wrong_user_data, 0);
    options.focus = 0;
    options.user_data = &context;
    winghostty_surface *first = NULL;
    if (winghostty_host_create_surface(
            context.host,
            context.parent,
            &options,
            &first
        ) != WINGHOSTTY_OK ||
        !first) {
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }
    if (GetParent(winghostty_surface_get_hwnd(first)) != context.parent ||
        !IsChild(context.parent, winghostty_surface_get_hwnd(first))) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }

    winghostty_cell_metrics cell_metrics = {8, 16, 8, 16, 13};
    if (winghostty_surface_set_cell_metrics(first, &cell_metrics) != WINGHOSTTY_OK ||
        winghostty_surface_notify_dpi_changed(first, 96) != WINGHOSTTY_OK) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }
    winghostty_cell_metrics scaled_metrics;
    if (winghostty_surface_notify_dpi_changed(first, 120) != WINGHOSTTY_OK ||
        winghostty_surface_get_cell_metrics(first, &scaled_metrics) != WINGHOSTTY_OK ||
        scaled_metrics.cell_width != 10 ||
        scaled_metrics.cell_height != 20 ||
        winghostty_surface_notify_dpi_changed(first, 96) != WINGHOSTTY_OK) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }
    if (winghostty_surface_notify_terminal_text(
            first,
            "hello terminal",
            14,
            0,
            14,
            6,
            14,
            14
        ) != WINGHOSTTY_OK) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }
    char copied[32] = {0};
    uint64_t copied_length = 0;
    if (winghostty_surface_copy_accessibility_range(
            first,
            6,
            14,
            copied,
            sizeof(copied),
            &copied_length
        ) != WINGHOSTTY_OK ||
        copied_length != 8 ||
        memcmp(copied, "terminal", 8) != 0) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }

    options.callbacks.on_redraw = NULL;
    options.callbacks.on_focus = NULL;
    options.user_data = NULL;
    command[0] = 'X';
    cwd[0] = 'X';
    environment[0] = 'X';

    context.surface = first;
    if (winghostty_surface_notify_redraw(first) != WINGHOSTTY_OK ||
        context.redraw_count != 1 ||
        context.callbacks_wrong_user_data != 0) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }

    context.loop_active = 1;
    PostMessageW(context.parent, WM_HOST_API_TRIGGER, 0, 0);
    if (run_message_loop() != 0 ||
        context.redraw_count < 2 ||
        context.callback_thread != context.ui_thread ||
        context.callbacks_wrong_thread != 0 ||
        context.callbacks_wrong_user_data != 0) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }
    context.loop_active = 0;

    const LONG callbacks_before_destroy = context.redraw_count + context.focus_count;
    context.surface_destroyed = 1;
    if (winghostty_surface_destroy(first) != WINGHOSTTY_OK) {
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }
    context.surface = NULL;
    PostMessageW(context.parent, WM_HOST_API_AFTER_DESTROY, 0, 0);
    if (run_message_loop() != 0 ||
        callbacks_before_destroy != context.redraw_count + context.focus_count ||
        context.callbacks_after_destroy != 0) {
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }

    options.callbacks.on_redraw = on_redraw;
    options.callbacks.on_focus = on_focus;
    options.user_data = &context;
    winghostty_surface *second = NULL;
    if (winghostty_host_create_surface(
            context.host,
            context.parent,
            &options,
            &second
        ) != WINGHOSTTY_OK ||
        !second ||
        !IsChild(context.parent, winghostty_surface_get_hwnd(second))) {
        winghostty_host_deinitialize(context.host);
        DestroyWindow(context.parent);
        return fail();
    }

    HWND second_hwnd = winghostty_surface_get_hwnd(second);
    DestroyWindow(context.parent);
    if (winghostty_surface_get_hwnd(second) != NULL ||
        winghostty_surface_get_hdc(second) != NULL ||
        winghostty_surface_get_hglrc(second) != NULL ||
        IsWindow(second_hwnd) ||
        winghostty_surface_notify_redraw(second) != WINGHOSTTY_SURFACE_INVALIDATED ||
        winghostty_surface_destroy(second) != WINGHOSTTY_OK ||
        winghostty_host_deinitialize(context.host) != WINGHOSTTY_OK) {
        return fail();
    }

    UnregisterClassW(class_name, parent_class.hInstance);
    return 0;
}
