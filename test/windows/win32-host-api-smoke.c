#include "../../include/winghostty/win32_host.h"

static LRESULT CALLBACK parent_window_proc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam
) {
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static volatile LONG redraw_count;
static volatile LONG focus_count;

static void on_redraw(void *user_data, winghostty_surface *surface) {
    (void)user_data;
    (void)surface;
    InterlockedIncrement(&redraw_count);
}

static void on_focus(void *user_data, winghostty_surface *surface, uint8_t focused) {
    (void)user_data;
    (void)surface;
    (void)focused;
    InterlockedIncrement(&focus_count);
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
    if (!RegisterClassW(&parent_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return fail();
    }

    HWND parent = CreateWindowExW(
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
    if (!parent) return fail();

    winghostty_host *host = NULL;
    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK || !host) {
        DestroyWindow(parent);
        return fail();
    }

    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 400;
    options.bounds.height = 300;
    options.callbacks.on_redraw = on_redraw;
    options.callbacks.on_focus = on_focus;

    char command[] = "cmd.exe";
    options.command = command;

    winghostty_surface *first = NULL;
    if (winghostty_host_create_surface(host, parent, &options, &first) != WINGHOSTTY_OK ||
        !first ||
        !winghostty_surface_get_hwnd(first)) {
        winghostty_host_deinitialize(host);
        DestroyWindow(parent);
        return fail();
    }
    command[0] = 'X';

    winghostty_rect first_bounds = {10, 20, 420, 320};
    if (winghostty_surface_set_bounds(first, &first_bounds) != WINGHOSTTY_OK ||
        winghostty_surface_set_visible(first, 1) != WINGHOSTTY_OK ||
        winghostty_surface_set_focus(first, 1) != WINGHOSTTY_OK ||
        winghostty_surface_set_theme(first, WINGHOSTTY_THEME_DARK) != WINGHOSTTY_OK ||
        winghostty_surface_set_font_scale(first, 1.25f) != WINGHOSTTY_OK) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(host);
        DestroyWindow(parent);
        return fail();
    }
    UpdateWindow(winghostty_surface_get_hwnd(first));

    winghostty_surface *second = NULL;
    if (winghostty_host_create_surface(host, parent, &options, &second) != WINGHOSTTY_OK ||
        !second ||
        !winghostty_surface_get_hwnd(second)) {
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(host);
        DestroyWindow(parent);
        return fail();
    }

    if (winghostty_surface_destroy(first) != WINGHOSTTY_OK ||
        winghostty_surface_destroy(second) != WINGHOSTTY_OK) {
        winghostty_host_deinitialize(host);
        DestroyWindow(parent);
        return fail();
    }

    for (int i = 0; i < 32; i++) {
        winghostty_surface *surface = NULL;
        if (winghostty_host_create_surface(host, parent, &options, &surface) != WINGHOSTTY_OK ||
            !surface ||
            winghostty_surface_destroy(surface) != WINGHOSTTY_OK) {
            winghostty_host_deinitialize(host);
            DestroyWindow(parent);
            return fail();
        }
    }

    uint32_t drained = 99;
    if (winghostty_host_drain(host, &drained) != WINGHOSTTY_OK || drained != 0 ||
        winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
        DestroyWindow(parent);
        return fail();
    }

    DestroyWindow(parent);
    UnregisterClassW(class_name, parent_class.hInstance);
    return 0;
}
