#include "../../include/winghostty/win32_host.h"

#include <stdio.h>
#include <string.h>

#define WM_IME_STARTCOMPOSITION 0x010D
#define WM_IME_ENDCOMPOSITION 0x010E
#define WM_KEYDOWN 0x0100
#define WM_KEYUP 0x0101
#define WM_CHAR 0x0102
#define WM_DEADCHAR 0x0103
#define WM_UNICHAR 0x0109
#define WM_MOUSEMOVE 0x0200
#define WM_LBUTTONDOWN 0x0201
#define WM_LBUTTONUP 0x0202
#define WM_LBUTTONDBLCLK 0x0203
#define WM_RBUTTONDBLCLK 0x0206
#define WM_MBUTTONDBLCLK 0x0209
#define WM_MOUSEWHEEL 0x020A
#define WM_XBUTTONDBLCLK 0x020D
#define WM_MOUSELEAVE 0x02A3
#define WM_DPICHANGED 0x02E0

typedef struct input_context {
    HWND parent;
    DWORD ui_thread;
    LONG keys;
    LONG texts;
    LONG ime_start;
    LONG ime_updates;
    LONG ime_end;
    LONG mouse;
    LONG selection;
    LONG links;
    LONG pastes;
    LONG clipboard_reads;
    LONG clipboard_writes;
    LONG focus;
    LONG link_reentrant_callbacks;
    LONG link_leave_callbacks;
    LONG wrong_thread;
    LONG wrong_user_data;
    LONG callbacks_after_destroy;
    LONG destroy_on_key;
    LONG deinit_on_text;
    LONG deinit_on_ime;
    LONG deinit_on_mouse;
    LONG deinit_callbacks;
    LONG legacy_deinit_callbacks;
    int legacy_deinit_kind;
    int destroyed;
    winghostty_host *callback_host;
    int copied_layout;
    int bracketed;
    int unsafe_rejected;
    int saw_unicode;
    int saw_dead_composition;
    int saw_wheel;
    int metrics_phase;
    int saw_initial_hit;
    int saw_initial_selection;
    int saw_scaled_hit;
    int saw_scaled_selection;
    int wheel_x;
    int wheel_y;
    unsigned double_click_buttons;
    int saw_mouse_leave;
    int saw_link_click;
    int saw_link_url_after_reentrant;
    int saw_link_leave_url;
    int link_reentrant_action;
    int saw_selection_drag;
    char pasted[128];
    char clipboard[128];
} input_context;

typedef struct input_admission_stress {
    winghostty_surface *surface;
    volatile LONG stop;
    volatile LONG entered;
    volatile LONG failures;
} input_admission_stress;

static void record(input_context *context, void *user_data);

static void maybe_deinit_legacy(input_context *context, int kind) {
    if (context->legacy_deinit_kind != kind) return;
    context->legacy_deinit_kind = 0;
    InterlockedIncrement(&context->legacy_deinit_callbacks);
    (void)winghostty_host_deinitialize(context->callback_host);
}

static void on_legacy_exit(
    void *user_data,
    winghostty_surface *surface,
    int32_t status
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)status;
    record(context, user_data);
    maybe_deinit_legacy(context, 1);
}

static void on_legacy_title(
    void *user_data,
    winghostty_surface *surface,
    const char *title
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)title;
    record(context, user_data);
    maybe_deinit_legacy(context, 2);
}

static void on_legacy_cwd(
    void *user_data,
    winghostty_surface *surface,
    const char *cwd
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)cwd;
    record(context, user_data);
    maybe_deinit_legacy(context, 3);
}

static void on_legacy_bell(void *user_data, winghostty_surface *surface) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    maybe_deinit_legacy(context, 4);
}

static void on_legacy_notification(
    void *user_data,
    winghostty_surface *surface,
    const char *notification
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)notification;
    record(context, user_data);
    maybe_deinit_legacy(context, 5);
}

static void on_legacy_fatal(
    void *user_data,
    winghostty_surface *surface,
    winghostty_result error,
    const char *message
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)error;
    (void)message;
    record(context, user_data);
    maybe_deinit_legacy(context, 6);
}

static void record(input_context *context, void *user_data) {
    if (GetCurrentThreadId() != context->ui_thread) {
        InterlockedIncrement(&context->wrong_thread);
    }
    if (user_data != context) {
        InterlockedIncrement(&context->wrong_user_data);
    }
    if (context->destroyed) {
        InterlockedIncrement(&context->callbacks_after_destroy);
    }
}

static void on_key(
    void *user_data,
    winghostty_surface *surface,
    const winghostty_key_event *event
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    InterlockedIncrement(&context->keys);
    if (event->keyboard_layout_name &&
        strcmp(event->keyboard_layout_name, "copied-layout") == 0) {
        context->copied_layout = 1;
    }
    if (event->composing) context->saw_dead_composition = 1;
    if (context->destroy_on_key) {
        context->destroyed = 1;
        (void)winghostty_surface_destroy(surface);
    }
}

static void on_text(
    void *user_data,
    winghostty_surface *surface,
    const char *text,
    uint32_t length
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    InterlockedIncrement(&context->texts);
    if (context->deinit_on_text) {
        context->deinit_on_text = 0;
        InterlockedIncrement(&context->deinit_callbacks);
        (void)winghostty_host_deinitialize(context->callback_host);
    }
    if (length == 4 && memcmp(text, "\xF0\x9F\x9A\x80", 4) == 0) {
        context->saw_unicode = 1;
    }
}

static void on_ime_start(void *user_data, winghostty_surface *surface) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    InterlockedIncrement(&context->ime_start);
    if (context->deinit_on_ime) {
        context->deinit_on_ime = 0;
        InterlockedIncrement(&context->deinit_callbacks);
        (void)winghostty_host_deinitialize(context->callback_host);
    }
}

static void on_ime_update(
    void *user_data,
    winghostty_surface *surface,
    const char *text,
    uint32_t length,
    uint8_t committed
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)text;
    (void)length;
    (void)committed;
    record(context, user_data);
    InterlockedIncrement(&context->ime_updates);
}

static void on_ime_end(void *user_data, winghostty_surface *surface) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    InterlockedIncrement(&context->ime_end);
}

static void on_mouse(
    void *user_data,
    winghostty_surface *surface,
    const winghostty_mouse_event *event
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    InterlockedIncrement(&context->mouse);
    if (event->kind == WINGHOSTTY_MOUSE_WHEEL &&
        event->wheel_delta == 120) {
        context->saw_wheel = 1;
        context->wheel_x = event->x;
        context->wheel_y = event->y;
    }
    if (context->metrics_phase == 1 &&
        event->x == 9 && event->y == 19 &&
        event->cell_x == 0 && event->cell_y == 0) {
        context->saw_initial_hit = 1;
    }
    if (context->metrics_phase == 2 &&
        event->x == 14 && event->y == 29 &&
        event->cell_x == 0 && event->cell_y == 0) {
        context->saw_scaled_hit = 1;
    }
    if (event->click_count == 2 && event->button < 32) {
        context->double_click_buttons |= 1u << event->button;
    }
    if (event->kind == WINGHOSTTY_MOUSE_LEAVE) context->saw_mouse_leave = 1;
    if (context->deinit_on_mouse) {
        context->deinit_on_mouse = 0;
        InterlockedIncrement(&context->deinit_callbacks);
        (void)winghostty_host_deinitialize(context->callback_host);
    }
}

static void on_selection(
    void *user_data,
    winghostty_surface *surface,
    const winghostty_selection_event *event
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    InterlockedIncrement(&context->selection);
    if (event->dragging) context->saw_selection_drag = 1;
    if (context->metrics_phase == 1 &&
        event->anchor_x == 0 && event->anchor_y == 0 &&
        event->current_x == 0 && event->current_y == 0) {
        context->saw_initial_selection = 1;
    }
    if (context->metrics_phase == 2 &&
        event->anchor_x == 0 && event->anchor_y == 0 &&
        event->current_x == 0 && event->current_y == 0) {
        context->saw_scaled_selection = 1;
    }
}

static void on_link(
    void *user_data,
    winghostty_surface *surface,
    const char *url,
    uint8_t hovered,
    uint8_t clicked
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    if (hovered && strcmp(url, "https://example.com") == 0) {
        InterlockedIncrement(&context->links);
    }
    if (!hovered) {
        InterlockedIncrement(&context->link_leave_callbacks);
        if (strcmp(url, "https://example.com") == 0) {
            context->saw_link_leave_url = 1;
        }
    }
    if (clicked) context->saw_link_click = 1;
    if (context->link_reentrant_action != 0) {
        const int action = context->link_reentrant_action;
        context->link_reentrant_action = 0;
        InterlockedIncrement(&context->link_reentrant_callbacks);
        if (action == 1) {
            for (int i = 0; i < 8; i++) {
                (void)winghostty_surface_set_link(
                    surface,
                    "https://replacement.example/long-url-to-force-reuse"
                );
            }
        } else if (action == 2) {
            (void)winghostty_surface_clear_link(surface);
            for (int i = 0; i < 8; i++) {
                (void)winghostty_surface_set_link(
                    surface,
                    "https://replacement.example/long-url-to-force-reuse"
                );
            }
        } else {
            (void)winghostty_host_deinitialize(context->callback_host);
        }
        if (strcmp(url, "https://example.com") == 0) {
            context->saw_link_url_after_reentrant = 1;
        }
    }
}

static void on_paste(
    void *user_data,
    winghostty_surface *surface,
    const char *text,
    uint32_t length,
    uint8_t bracketed
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    record(context, user_data);
    InterlockedIncrement(&context->pastes);
    context->bracketed = bracketed != 0;
    if (length < sizeof(context->pasted)) {
        memcpy(context->pasted, text, length);
        context->pasted[length] = '\0';
    }
}

static void on_clipboard_read(
    void *user_data,
    winghostty_surface *surface,
    uint32_t format,
    const char *text,
    uint32_t length
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)format;
    record(context, user_data);
    InterlockedIncrement(&context->clipboard_reads);
    if (length < sizeof(context->clipboard)) {
        memcpy(context->clipboard, text, length);
        context->clipboard[length] = '\0';
    }
}

static void on_clipboard_write(
    void *user_data,
    winghostty_surface *surface,
    uint32_t format,
    const char *text,
    uint32_t length
) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)format;
    (void)text;
    (void)length;
    record(context, user_data);
    InterlockedIncrement(&context->clipboard_writes);
}

static void on_focus(void *user_data, winghostty_surface *surface, uint8_t focused) {
    input_context *context = (input_context *)user_data;
    (void)surface;
    (void)focused;
    record(context, user_data);
    InterlockedIncrement(&context->focus);
}

static LRESULT CALLBACK parent_proc(
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

static int fail_line(int line) {
    fprintf(stderr, "input host smoke failed at line %d\n", line);
    return 1;
}

#define fail() fail_line(__LINE__)

static int run_legacy_deinit_case(
    input_context *context,
    const winghostty_surface_options_v2 *template_options,
    int kind
) {
    winghostty_host *host = NULL;
    winghostty_surface *surface = NULL;
    winghostty_surface_options_v2 options = *template_options;
    options.focus = 0;
    context->callback_host = NULL;
    context->legacy_deinit_kind = kind;
    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK) return 1;
    context->callback_host = host;
    if (winghostty_host_create_surface_v2(
            host,
            context->parent,
            &options,
            &surface
        ) != WINGHOSTTY_OK) {
        return 1;
    }
    switch (kind) {
        case 1:
            (void)winghostty_surface_notify_exit(surface, 0);
            break;
        case 2:
            (void)winghostty_surface_notify_title(surface, "title");
            break;
        case 3:
            (void)winghostty_surface_notify_cwd(surface, "C:\\");
            break;
        case 4:
            (void)winghostty_surface_notify_bell(surface);
            break;
        case 5:
            (void)winghostty_surface_notify_notification(surface, "notification");
            break;
        case 6:
            (void)winghostty_surface_notify_fatal_error(
                surface,
                WINGHOSTTY_WIN32_ERROR,
                "fatal"
            );
            break;
        default:
            return 1;
    }
    return context->legacy_deinit_kind == 0 ? 0 : 1;
}

static int run_link_reentrant_case(
    input_context *context,
    const winghostty_surface_options_v2 *template_options,
    int action
) {
    winghostty_host *host = NULL;
    winghostty_surface *surface = NULL;
    winghostty_surface_options_v2 options = *template_options;
    options.focus = 0;
    options.input.selection_enabled = 0;
    options.input.links_enabled = 1;
    context->callback_host = NULL;
    context->link_reentrant_action = action;
    context->link_leave_callbacks = 0;
    context->saw_link_leave_url = 0;
    context->saw_link_url_after_reentrant = 0;
    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK) return 1;
    context->callback_host = host;
    if (winghostty_host_create_surface_v2(
            host,
            context->parent,
            &options,
            &surface
        ) != WINGHOSTTY_OK) {
        return 1;
    }
    if (winghostty_surface_set_link(surface, "https://example.com") !=
        WINGHOSTTY_OK) {
        return 1;
    }
    SendMessageW(
        winghostty_surface_get_hwnd(surface),
        WM_MOUSEMOVE,
        0,
        MAKELPARAM(8, 8)
    );
    const LONG expected_leaves = action == 3 ? 0 : 1;
    if (context->link_leave_callbacks != expected_leaves ||
        (expected_leaves != 0 && !context->saw_link_leave_url)) {
        return 1;
    }
    if (action != 3) (void)winghostty_host_deinitialize(host);
    return context->link_reentrant_action == 0 &&
        context->saw_link_url_after_reentrant
        ? 0
        : 1;
}

static int input_result_allowed(winghostty_result result) {
    return result >= WINGHOSTTY_OK && result <= WINGHOSTTY_CLIPBOARD_UNAVAILABLE;
}

static void record_input_result(
    input_admission_stress *stress,
    winghostty_result result
) {
    if (!input_result_allowed(result)) {
        InterlockedIncrement(&stress->failures);
    }
}

static DWORD WINAPI input_admission_stress_thread(void *parameter) {
    input_admission_stress *stress = (input_admission_stress *)parameter;
    char text[] = "stress";
    char name[] = "stress";
    char output[64];
    uint64_t written = 0;
    InterlockedExchange(&stress->entered, 1);
    for (int i = 0; i < 4096 &&
                    InterlockedCompareExchange(&stress->stop, 0, 0) == 0;
         ++i) {
        record_input_result(
            stress,
            winghostty_surface_paste_text(stress->surface, text, 6, 0)
        );
        record_input_result(
            stress,
            winghostty_surface_read_clipboard(
                stress->surface,
                WINGHOSTTY_CLIPBOARD_TEXT
            )
        );
        record_input_result(
            stress,
            winghostty_surface_write_clipboard(
                stress->surface,
                WINGHOSTTY_CLIPBOARD_TEXT,
                text,
                6
            )
        );
        record_input_result(
            stress,
            winghostty_surface_clipboard_read(
                stress->surface,
                WINGHOSTTY_CLIPBOARD_TEXT
            )
        );
        record_input_result(
            stress,
            winghostty_surface_clipboard_write(
                stress->surface,
                WINGHOSTTY_CLIPBOARD_TEXT,
                text,
                6
            )
        );
        record_input_result(
            stress,
            winghostty_surface_set_keyboard_layout(stress->surface, 0)
        );
        record_input_result(
            stress,
            winghostty_surface_ime_update(stress->surface, text, 6, 0)
        );
        record_input_result(
            stress,
            winghostty_surface_set_link(stress->surface, "https://stress")
        );
        record_input_result(
            stress,
            winghostty_surface_clear_link(stress->surface)
        );
        record_input_result(
            stress,
            winghostty_surface_set_selection_text(stress->surface, text, 6)
        );
        record_input_result(
            stress,
            winghostty_surface_clear_selection(stress->surface)
        );
        record_input_result(
            stress,
            winghostty_surface_copy_selection(stress->surface)
        );
        record_input_result(
            stress,
            winghostty_surface_notify_accessibility_name(
                stress->surface,
                name
            )
        );
        record_input_result(
            stress,
            winghostty_surface_notify_accessibility_text(
                stress->surface,
                text,
                6,
                0,
                6,
                0,
                0,
                0
            )
        );
        record_input_result(
            stress,
            winghostty_surface_notify_terminal_text(
                stress->surface,
                text,
                6,
                0,
                6,
                0,
                0,
                0
            )
        );
        record_input_result(
            stress,
            winghostty_surface_notify_accessibility_focus(
                stress->surface,
                1
            )
        );
        record_input_result(
            stress,
            winghostty_surface_set_accessibility_role(stress->surface, 0)
        );
        written = 0;
        record_input_result(
            stress,
            winghostty_surface_copy_accessibility_range(
                stress->surface,
                0,
                6,
                output,
                sizeof(output),
                &written
            )
        );
    }
    return 0;
}

static int run_input_admission_stress(
    HWND parent,
    const winghostty_surface_options_v2 *template_options
) {
    for (int cycle = 0; cycle < 64; ++cycle) {
        winghostty_host *host = NULL;
        winghostty_surface *surface = NULL;
        winghostty_surface_options_v2 options = *template_options;
        input_admission_stress stress = {0};
        options.focus = 0;
        options.visible = 0;
        options.user_data = NULL;
        options.callbacks = (winghostty_callbacks_v2){0};
        options.input_callbacks = (winghostty_input_callbacks){0};
        if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
            winghostty_host_create_surface_v2(
                host,
                parent,
                &options,
                &surface
            ) != WINGHOSTTY_OK ||
            surface == NULL) {
            if (host != NULL) winghostty_host_deinitialize(host);
            return 1;
        }

        stress.surface = surface;
        HANDLE thread = CreateThread(
            NULL,
            0,
            input_admission_stress_thread,
            &stress,
            0,
            NULL
        );
        if (thread == NULL) {
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            return 1;
        }
        for (int i = 0; i < 100 && stress.entered == 0; ++i) {
            Sleep(1);
        }
        if (stress.entered == 0) {
            InterlockedExchange(&stress.stop, 1);
            WaitForSingleObject(thread, 10000);
            CloseHandle(thread);
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            return 1;
        }
        if (winghostty_surface_destroy(surface) != WINGHOSTTY_OK ||
            winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
            InterlockedExchange(&stress.stop, 1);
            WaitForSingleObject(thread, 10000);
            CloseHandle(thread);
            return 1;
        }
        InterlockedExchange(&stress.stop, 1);
        if (WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0) {
            CloseHandle(thread);
            return 1;
        }
        CloseHandle(thread);
        if (stress.failures != 0) return 1;
    }
    return 0;
}

int main(void) {
    const wchar_t class_name[] = L"WinghosttyHostApiInput";
    WNDCLASSW parent_class = {
        .lpfnWndProc = parent_proc,
        .hInstance = GetModuleHandleW(NULL),
        .lpszClassName = class_name,
    };
    if (!RegisterClassW(&parent_class) &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return fail();
    }

    input_context context = {.ui_thread = GetCurrentThreadId()};
    context.parent = CreateWindowExW(
        0,
        class_name,
        L"Winghostty input host API",
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
    ShowWindow(context.parent, SW_SHOW);
    SetActiveWindow(context.parent);
    SetFocus(context.parent);

    winghostty_host *host = NULL;
    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK) return fail();

    char layout[] = "copied-layout";
    winghostty_surface_options_v2 options;
    winghostty_surface_options_v2_init(&options);
    options.visible = 1;
    options.focus = 1;
    options.bounds.width = 400;
    options.bounds.height = 300;
    options.user_data = &context;
    options.input.keyboard_layout = layout;
    options.callbacks.on_focus = on_focus;
    options.input_callbacks.on_key = on_key;
    options.input_callbacks.on_text = on_text;
    options.input_callbacks.on_ime_start = on_ime_start;
    options.input_callbacks.on_ime_update = on_ime_update;
    options.input_callbacks.on_ime_end = on_ime_end;
    options.input_callbacks.on_mouse = on_mouse;
    options.input_callbacks.on_selection = on_selection;
    options.input_callbacks.on_link = on_link;
    options.input_callbacks.on_paste = on_paste;
    options.input_callbacks.on_clipboard_read = on_clipboard_read;
    options.input_callbacks.on_clipboard_write = on_clipboard_write;
    options.input.cell_width = 10;
    options.input.cell_height = 20;

    winghostty_surface_options_v2 invalid_options = options;
    invalid_options.input.cell_width = 0;
    winghostty_surface *invalid_surface = NULL;
    if (winghostty_host_create_surface_v2(
            host,
            context.parent,
            &invalid_options,
            &invalid_surface
        ) != WINGHOSTTY_INVALID_ARGUMENT ||
        invalid_surface != NULL) {
        return fail();
    }

    winghostty_surface *first = NULL;
    if (winghostty_host_create_surface_v2(host, context.parent, &options, &first) !=
            WINGHOSTTY_OK ||
        !first) {
        return fail();
    }
    layout[0] = 'X';
    HWND first_hwnd = winghostty_surface_get_hwnd(first);
    if (!first_hwnd) return fail();
    SendMessageW(first_hwnd, WM_DPICHANGED, MAKELPARAM(96, 96), 0);
    context.metrics_phase = 1;
    SendMessageW(first_hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(9, 19));
    SendMessageW(first_hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(9, 19));
    SendMessageW(first_hwnd, WM_LBUTTONUP, 0, MAKELPARAM(9, 19));

    SendMessageW(first_hwnd, WM_DPICHANGED, MAKELPARAM(144, 144), 0);
    context.metrics_phase = 2;
    SendMessageW(first_hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(14, 29));
    SendMessageW(first_hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(14, 29));
    SendMessageW(first_hwnd, WM_LBUTTONUP, 0, MAKELPARAM(14, 29));

    winghostty_cell_metrics changed_metrics = {
        .font_width = 10,
        .font_height = 20,
        .cell_width = 10,
        .cell_height = 20,
        .baseline = 15,
    };
    if (winghostty_surface_set_cell_metrics(first, &changed_metrics) !=
            WINGHOSTTY_OK) {
        return fail();
    }
    SendMessageW(first_hwnd, WM_DPICHANGED, MAKELPARAM(144, 144), 0);
    SendMessageW(first_hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(14, 29));
    SendMessageW(first_hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(14, 29));
    SendMessageW(first_hwnd, WM_LBUTTONUP, 0, MAKELPARAM(14, 29));

    SendMessageW(first_hwnd, WM_KEYDOWN, 'A', 1u << 16);
    LONG keys_after_keydown = context.keys;
    SendMessageW(first_hwnd, WM_DEADCHAR, 0x00B4, 1u << 16);
    if (context.keys != keys_after_keydown) return fail();
    SendMessageW(first_hwnd, WM_KEYDOWN, 'B', 1u << 16);
    SendMessageW(first_hwnd, WM_CHAR, 0x00E9, 0);
    SendMessageW(first_hwnd, WM_CHAR, 0xD83D, 0);
    SendMessageW(first_hwnd, WM_CHAR, 0xDE80, 0);
    SendMessageW(first_hwnd, WM_IME_STARTCOMPOSITION, 0, 0);
    if (winghostty_surface_ime_update(first, "kana", 4, 0) != WINGHOSTTY_OK ||
        winghostty_surface_ime_update(first, "日本", 6, 1) != WINGHOSTTY_OK) {
        return fail();
    }
    SendMessageW(first_hwnd, WM_IME_ENDCOMPOSITION, 0, 0);

    if (winghostty_surface_set_link(first, "https://example.com") != WINGHOSTTY_OK) {
        return fail();
    }
    SendMessageW(first_hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(24, 32));
    SendMessageW(first_hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(24, 32));
    if (GetCapture() != first_hwnd) return fail();
    SendMessageW(first_hwnd, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(80, 48));
    SendMessageW(first_hwnd, WM_LBUTTONUP, 0, MAKELPARAM(80, 48));
    if (GetCapture() != NULL) return fail();
    SendMessageW(first_hwnd, WM_LBUTTONDBLCLK, MK_LBUTTON, MAKELPARAM(24, 32));
    SendMessageW(first_hwnd, WM_RBUTTONDBLCLK, MK_RBUTTON, MAKELPARAM(24, 32));
    SendMessageW(first_hwnd, WM_MBUTTONDBLCLK, MK_MBUTTON, MAKELPARAM(24, 32));
    SendMessageW(
        first_hwnd,
        WM_XBUTTONDBLCLK,
        MAKEWPARAM(0, 1),
        MAKELPARAM(24, 32)
    );
    POINT wheel_point = {80, 48};
    if (!ClientToScreen(first_hwnd, &wheel_point)) return fail();
    SendMessageW(
        first_hwnd,
        WM_MOUSEWHEEL,
        MAKEWPARAM(0, 120),
        MAKELPARAM(wheel_point.x, wheel_point.y)
    );
    if (SendMessageW(first_hwnd, WM_UNICHAR, 0xFFFF, 0) != 1) return fail();
    SendMessageW(first_hwnd, WM_MOUSELEAVE, 0, 0);

    if (winghostty_paste_validate("echo;whoami", 11) !=
            WINGHOSTTY_PASTE_SHELL_METACHAR ||
        winghostty_surface_paste_text(first, "safe", 4, 0) != WINGHOSTTY_OK ||
        !context.bracketed ||
        winghostty_surface_paste_text(first, "echo;whoami", 11, 0) !=
            WINGHOSTTY_PASTE_REQUIRES_CONFIRMATION ||
        winghostty_surface_paste_text(first, "echo;whoami", 11, 1) != WINGHOSTTY_OK) {
        return fail();
    }
    winghostty_result clipboard_write = winghostty_surface_write_clipboard(
            first,
            WINGHOSTTY_CLIPBOARD_TEXT,
            "clipboard \xF0\x9F\x9A\x80",
            14
        );
    winghostty_result clipboard_read =
        winghostty_surface_read_clipboard(first, WINGHOSTTY_CLIPBOARD_TEXT);
    if ((clipboard_write != WINGHOSTTY_OK &&
         clipboard_write != WINGHOSTTY_CLIPBOARD_UNAVAILABLE) ||
        (clipboard_read != WINGHOSTTY_OK &&
         clipboard_read != WINGHOSTTY_CLIPBOARD_UNAVAILABLE) ||
        (clipboard_write == WINGHOSTTY_OK &&
         clipboard_read == WINGHOSTTY_OK &&
         strcmp(context.clipboard, "clipboard \xF0\x9F\x9A\x80") != 0)) {
        fprintf(
            stderr,
            "clipboard write=%d read=%d text='%s' reads=%ld writes=%ld\n",
            clipboard_write,
            clipboard_read,
            context.clipboard,
            context.clipboard_reads,
            context.clipboard_writes
        );
        return fail();
    }
    winghostty_result html_write = WINGHOSTTY_CLIPBOARD_UNAVAILABLE;
    winghostty_result html_read = WINGHOSTTY_CLIPBOARD_UNAVAILABLE;
    winghostty_result html_plain_read = WINGHOSTTY_CLIPBOARD_UNAVAILABLE;
    if (clipboard_write == WINGHOSTTY_OK) {
        const char html[] = "<p>Hello <b>world</b></p>";
        html_write = winghostty_surface_write_clipboard(
            first,
            WINGHOSTTY_CLIPBOARD_HTML,
            html,
            (uint32_t)(sizeof(html) - 1)
        );
        memset(context.clipboard, 0, sizeof(context.clipboard));
        html_read = winghostty_surface_read_clipboard(
            first,
            WINGHOSTTY_CLIPBOARD_HTML
        );
        if (html_read == WINGHOSTTY_OK &&
            strcmp(context.clipboard, html) != 0) {
            fprintf(
                stderr,
                "CF_HTML fragment mismatch: '%s'\n",
                context.clipboard
            );
            return fail();
        }
        memset(context.clipboard, 0, sizeof(context.clipboard));
        html_plain_read = winghostty_surface_read_clipboard(
            first,
            WINGHOSTTY_CLIPBOARD_TEXT
        );
        if (html_plain_read == WINGHOSTTY_OK &&
            strcmp(context.clipboard, "Hello world") != 0) {
            fprintf(
                stderr,
                "CF_HTML plain fallback mismatch: '%s'\n",
                context.clipboard
            );
            return fail();
        }
        if (html_write != WINGHOSTTY_OK ||
            html_read != WINGHOSTTY_OK ||
            html_plain_read != WINGHOSTTY_OK) {
            return fail();
        }
    }

    winghostty_surface_options_v2 second_options = options;
    second_options.focus = 0;
    second_options.bounds.x = 400;
    second_options.input.keyboard_layout = NULL;
    second_options.input.links_enabled = 0;
    second_options.input.selection_enabled = 0;
    winghostty_surface *second = NULL;
    if (winghostty_host_create_surface_v2(
            host,
            context.parent,
            &second_options,
            &second
        ) != WINGHOSTTY_OK ||
        winghostty_surface_set_focus(second, 1) != WINGHOSTTY_OK) {
        return fail();
    }
    context.saw_mouse_leave = 0;
    HWND second_hwnd = winghostty_surface_get_hwnd(second);
    SendMessageW(second_hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(8, 8));
    SendMessageW(second_hwnd, WM_MOUSELEAVE, 0, 0);
    if (!context.saw_mouse_leave) return fail();
    LONG keys_before_unfocused = context.keys;
    SendMessageW(first_hwnd, WM_KEYDOWN, 'B', 1u << 16);
    if (context.keys != keys_before_unfocused) return fail();
    SendMessageW(second_hwnd, WM_KEYDOWN, 'C', 1u << 16);
    if (context.keys == keys_before_unfocused) return fail();

    context.destroy_on_key = 1;
    context.destroyed = 0;
    SendMessageW(second_hwnd, WM_KEYDOWN, 'D', 1u << 16);
    context.destroy_on_key = 0;
    winghostty_result destroyed_redraw = winghostty_surface_notify_redraw(second);
    if (!context.destroyed ||
        (destroyed_redraw != WINGHOSTTY_INVALID_ARGUMENT &&
            destroyed_redraw != WINGHOSTTY_SURFACE_INVALIDATED &&
            destroyed_redraw != WINGHOSTTY_SHUTTING_DOWN) ||
        context.callbacks_after_destroy != 0) {
        fprintf(
            stderr,
            "destroy check destroyed=%d redraw=%d after=%ld keys=%ld focus=%ld\n",
            context.destroyed,
            destroyed_redraw,
            context.callbacks_after_destroy,
            context.keys,
            context.focus
        );
        return fail();
    }

    if (context.keys < 3 ||
        context.texts < 2 ||
        context.ime_start != 1 ||
        context.ime_updates != 2 ||
        context.ime_end != 1 ||
        context.mouse < 5 ||
        context.selection < 2 ||
        context.links < 1 ||
        !context.saw_link_click ||
        !context.saw_selection_drag ||
        !context.saw_initial_hit ||
        !context.saw_initial_selection ||
        !context.saw_scaled_hit ||
        !context.saw_scaled_selection ||
        !context.saw_wheel ||
        !context.saw_unicode ||
        !context.saw_dead_composition ||
        context.wheel_x != 80 ||
        context.wheel_y != 48 ||
        !context.saw_mouse_leave ||
        (context.double_click_buttons & ((1u << 1) | (1u << 2) | (1u << 3) |
            (1u << 4))) !=
            ((1u << 1) | (1u << 2) | (1u << 3) | (1u << 4)) ||
        !context.copied_layout ||
        context.pastes != 2 ||
        context.clipboard_reads !=
            (clipboard_read == WINGHOSTTY_OK ? 1 : 0) +
                (html_read == WINGHOSTTY_OK ? 1 : 0) +
                (html_plain_read == WINGHOSTTY_OK ? 1 : 0) ||
        context.clipboard_writes !=
            (clipboard_write == WINGHOSTTY_OK ? 1 : 0) +
                (html_write == WINGHOSTTY_OK ? 1 : 0) ||
        context.wrong_thread != 0 ||
        context.wrong_user_data != 0) {
        return fail();
    }

    (void)winghostty_surface_destroy(first);
    (void)winghostty_host_deinitialize(host);

    winghostty_host *callback_host = NULL;
    winghostty_surface *callback_surface = NULL;
    winghostty_surface_options_v2 callback_options = options;
    callback_options.focus = 1;
    context.callback_host = NULL;
    context.deinit_on_text = 1;
    if (winghostty_host_initialize(&callback_host) != WINGHOSTTY_OK) return fail();
    context.callback_host = callback_host;
    if (winghostty_host_create_surface_v2(
            callback_host,
            context.parent,
            &callback_options,
            &callback_surface
        ) != WINGHOSTTY_OK) {
        return fail();
    }
    SendMessageW(winghostty_surface_get_hwnd(callback_surface), WM_CHAR, 'x', 0);

    callback_host = NULL;
    callback_surface = NULL;
    callback_options = options;
    callback_options.focus = 1;
    context.callback_host = NULL;
    context.deinit_on_ime = 1;
    if (winghostty_host_initialize(&callback_host) != WINGHOSTTY_OK) return fail();
    context.callback_host = callback_host;
    if (winghostty_host_create_surface_v2(
            callback_host,
            context.parent,
            &callback_options,
            &callback_surface
        ) != WINGHOSTTY_OK) {
        return fail();
    }
    SendMessageW(
        winghostty_surface_get_hwnd(callback_surface),
        WM_IME_STARTCOMPOSITION,
        0,
        0
    );

    callback_host = NULL;
    callback_surface = NULL;
    callback_options = options;
    callback_options.focus = 0;
    context.callback_host = NULL;
    context.deinit_on_mouse = 1;
    if (winghostty_host_initialize(&callback_host) != WINGHOSTTY_OK) return fail();
    context.callback_host = callback_host;
    if (winghostty_host_create_surface_v2(
            callback_host,
            context.parent,
            &callback_options,
            &callback_surface
        ) != WINGHOSTTY_OK) {
        return fail();
    }
    SendMessageW(
        winghostty_surface_get_hwnd(callback_surface),
        WM_MOUSEMOVE,
        0,
        MAKELPARAM(8, 8)
    );
    if (context.deinit_callbacks != 3) return fail();

    callback_options = options;
    callback_options.callbacks.on_exit = on_legacy_exit;
    callback_options.callbacks.on_title = on_legacy_title;
    callback_options.callbacks.on_cwd = on_legacy_cwd;
    callback_options.callbacks.on_bell = on_legacy_bell;
    callback_options.callbacks.on_notification = on_legacy_notification;
    callback_options.callbacks.on_fatal_error = on_legacy_fatal;
    for (int kind = 1; kind <= 6; kind++) {
        if (run_legacy_deinit_case(&context, &callback_options, kind) != 0) {
            return fail();
        }
    }
    if (context.legacy_deinit_callbacks != 6) return fail();

    for (int action = 1; action <= 3; action++) {
        if (run_link_reentrant_case(&context, &options, action) != 0) {
            return fail();
        }
    }
    if (context.link_reentrant_callbacks != 3) return fail();
    if (run_input_admission_stress(context.parent, &options) != 0) {
        return fail();
    }

    DestroyWindow(context.parent);
    UnregisterClassW(class_name, parent_class.hInstance);
    return 0;
}
