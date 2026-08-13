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
#define WM_MOUSEWHEEL 0x020A
#define WM_MOUSELEAVE 0x02A3

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
    LONG wrong_thread;
    LONG wrong_user_data;
    LONG callbacks_after_destroy;
    LONG destroy_on_key;
    LONG deinit_on_text;
    LONG deinit_on_ime;
    LONG deinit_on_mouse;
    LONG deinit_callbacks;
    int destroyed;
    winghostty_host *callback_host;
    int copied_layout;
    int bracketed;
    int unsafe_rejected;
    int saw_unicode;
    int saw_dead_composition;
    int saw_wheel;
    int wheel_x;
    int wheel_y;
    int saw_double_click;
    int saw_link_click;
    int saw_selection_drag;
    char pasted[128];
    char clipboard[128];
} input_context;

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
    if (event->click_count == 2) context->saw_double_click = 1;
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
    if (clicked) context->saw_link_click = 1;
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

    winghostty_surface *first = NULL;
    if (winghostty_host_create_surface_v2(host, context.parent, &options, &first) !=
            WINGHOSTTY_OK ||
        !first) {
        return fail();
    }
    layout[0] = 'X';
    HWND first_hwnd = winghostty_surface_get_hwnd(first);
    if (!first_hwnd) return fail();

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

    winghostty_surface_options_v2 second_options = options;
    second_options.focus = 0;
    second_options.bounds.x = 400;
    second_options.input.keyboard_layout = NULL;
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
    LONG keys_before_unfocused = context.keys;
    SendMessageW(first_hwnd, WM_KEYDOWN, 'B', 1u << 16);
    if (context.keys != keys_before_unfocused) return fail();
    SendMessageW(winghostty_surface_get_hwnd(second), WM_KEYDOWN, 'C', 1u << 16);
    if (context.keys == keys_before_unfocused) return fail();

    context.destroy_on_key = 1;
    context.destroyed = 0;
    HWND second_hwnd = winghostty_surface_get_hwnd(second);
    SendMessageW(second_hwnd, WM_KEYDOWN, 'D', 1u << 16);
    context.destroy_on_key = 0;
    if (!context.destroyed ||
        winghostty_surface_notify_redraw(second) != WINGHOSTTY_SURFACE_INVALIDATED ||
        context.callbacks_after_destroy != 0) {
        fprintf(
            stderr,
            "destroy check destroyed=%d redraw=%d after=%ld keys=%ld focus=%ld\n",
            context.destroyed,
            winghostty_surface_notify_redraw(second),
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
        !context.saw_wheel ||
        !context.saw_unicode ||
        !context.saw_dead_composition ||
        context.wheel_x != 80 ||
        context.wheel_y != 48 ||
        !context.saw_double_click ||
        !context.copied_layout ||
        context.pastes != 2 ||
        context.clipboard_reads !=
            (clipboard_read == WINGHOSTTY_OK ? 1 : 0) ||
        context.clipboard_writes !=
            (clipboard_write == WINGHOSTTY_OK ? 1 : 0) ||
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

    DestroyWindow(context.parent);
    UnregisterClassW(class_name, parent_class.hInstance);
    return 0;
}
