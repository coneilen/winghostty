#include "../../include/winghostty/win32_host.h"
#include <stddef.h>

#if defined(__cplusplus)
#define WINGHOSTTY_LAYOUT_ASSERT static_assert
#else
#define WINGHOSTTY_LAYOUT_ASSERT _Static_assert
#endif

WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_result) == sizeof(int32_t),
    "winghostty_result must remain int32_t"
);
WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_theme) == sizeof(int32_t),
    "winghostty_theme must remain int32_t"
);
WINGHOSTTY_LAYOUT_ASSERT(sizeof(winghostty_rect) == 16, "rect ABI changed");
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_rect, width) == 8,
    "rect width offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_callbacks) == 64,
    "callback ABI changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_callbacks, on_fatal_error) == 56,
    "fatal callback offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_surface_options) == 128,
    "surface options ABI changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_surface_options, theme) == 44,
    "surface theme offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_surface_options, callbacks) == 56,
    "surface callbacks offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_surface_options, user_data) == 120,
    "surface user data offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_input_callbacks) == 88,
    "input callback ABI changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_input_options) == 24,
    "input options ABI changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_callbacks_v2) == 88,
    "callback v2 ABI changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    sizeof(winghostty_surface_options_v2) == 272,
    "surface options v2 ABI changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_surface_options_v2, callbacks) == 64,
    "surface callbacks v2 offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_surface_options_v2, user_data) == 152,
    "surface user data v2 offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_surface_options_v2, input_callbacks) == 160,
    "input options offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(
    offsetof(winghostty_surface_options_v2, input) == 248,
    "input options offset changed"
);
WINGHOSTTY_LAYOUT_ASSERT(sizeof(winghostty_key_event) == 48, "key event ABI changed");
WINGHOSTTY_LAYOUT_ASSERT(sizeof(winghostty_mouse_event) == 36, "mouse event ABI changed");
WINGHOSTTY_LAYOUT_ASSERT(sizeof(winghostty_selection_event) == 20, "selection event ABI changed");

static void on_exit(void *user_data, winghostty_surface *surface, int32_t status) {
    (void)user_data;
    (void)surface;
    (void)status;
}

static void on_title(void *user_data, winghostty_surface *surface, const char *title) {
    (void)user_data;
    (void)surface;
    (void)title;
}

static void on_cwd(void *user_data, winghostty_surface *surface, const char *cwd) {
    (void)user_data;
    (void)surface;
    (void)cwd;
}

static void on_bell(void *user_data, winghostty_surface *surface) {
    (void)user_data;
    (void)surface;
}

static void on_notification(
    void *user_data,
    winghostty_surface *surface,
    const char *notification
) {
    (void)user_data;
    (void)surface;
    (void)notification;
}

static void on_redraw(void *user_data, winghostty_surface *surface) {
    (void)user_data;
    (void)surface;
}

static void on_focus(void *user_data, winghostty_surface *surface, uint8_t focused) {
    (void)user_data;
    (void)surface;
    (void)focused;
}

static void on_fatal_error(
    void *user_data,
    winghostty_surface *surface,
    winghostty_result error,
    const char *message
) {
    (void)user_data;
    (void)surface;
    (void)error;
    (void)message;
}

static void on_key(
    void *user_data,
    winghostty_surface *surface,
    const winghostty_key_event *event
) {
    (void)user_data;
    (void)surface;
    (void)event;
}

static void on_text(
    void *user_data,
    winghostty_surface *surface,
    const char *text,
    uint32_t length
) {
    (void)user_data;
    (void)surface;
    (void)text;
    (void)length;
}

static void on_dpi_changed(
    void *user_data,
    winghostty_surface *surface,
    uint32_t dpi,
    float scale
) {
    (void)user_data;
    (void)surface;
    (void)dpi;
    (void)scale;
}

static void on_metrics_changed(
    void *user_data,
    winghostty_surface *surface,
    const winghostty_cell_metrics *metrics
) {
    (void)user_data;
    (void)surface;
    (void)metrics;
}

static void on_accessibility_selection(
    void *user_data,
    winghostty_surface *surface,
    uint64_t start,
    uint64_t end
) {
    (void)user_data;
    (void)surface;
    (void)start;
    (void)end;
}

void winghostty_win32_host_compile_contract(void) {
    winghostty_host *host = 0;
    winghostty_surface *surface = 0;
    winghostty_surface_options options;
    winghostty_surface_options_v2 options_v2;
    winghostty_rect bounds = {0, 0, 800, 600};
    uint32_t drained = 0;

    winghostty_surface_options_init(&options);
    options.command = "cmd.exe";
    options.cwd = "C:\\";
    options.environment = "TERM=xterm-256color";
    options.bounds = bounds;
    options.callbacks.on_exit = on_exit;
    options.callbacks.on_title = on_title;
    options.callbacks.on_cwd = on_cwd;
    options.callbacks.on_bell = on_bell;
    options.callbacks.on_notification = on_notification;
    options.callbacks.on_redraw = on_redraw;
    options.callbacks.on_focus = on_focus;
    options.callbacks.on_fatal_error = on_fatal_error;
    options.callbacks.on_dpi_changed = on_dpi_changed;
    options.callbacks.on_metrics_changed = on_metrics_changed;
    options.callbacks.on_accessibility_selection = on_accessibility_selection;
    winghostty_surface_options_v2 options_v2;
    winghostty_surface_options_v2_init(&options_v2);
    options_v2.command = options.command;
    options_v2.cwd = options.cwd;
    options_v2.environment = options.environment;
    options_v2.bounds = options.bounds;
    options_v2.visible = options.visible;
    options_v2.focus = options.focus;
    options_v2.theme = options.theme;
    options_v2.font_scale = options.font_scale;
    options_v2.callbacks.on_exit = on_exit;
    options_v2.callbacks.on_title = on_title;
    options_v2.callbacks.on_cwd = on_cwd;
    options_v2.callbacks.on_bell = on_bell;
    options_v2.callbacks.on_notification = on_notification;
    options_v2.callbacks.on_redraw = on_redraw;
    options_v2.callbacks.on_focus = on_focus;
    options_v2.callbacks.on_fatal_error = on_fatal_error;
    options_v2.callbacks.on_dpi_changed = on_dpi_changed;
    options_v2.callbacks.on_metrics_changed = on_metrics_changed;
    options_v2.callbacks.on_accessibility_selection =
        on_accessibility_selection;
    options_v2.user_data = options.user_data;
    options_v2.input_callbacks.on_key = on_key;
    options_v2.input_callbacks.on_text = on_text;

    (void)winghostty_host_initialize(&host);
    (void)winghostty_host_create_surface_v2(
        host,
        (HWND)0,
        &options_v2,
        &surface
    );
    (void)winghostty_surface_set_bounds(surface, &bounds);
    (void)winghostty_surface_set_visible(surface, 1);
    (void)winghostty_surface_set_focus(surface, 1);
    (void)winghostty_surface_set_theme(surface, WINGHOSTTY_THEME_DARK);
    (void)winghostty_surface_set_font_scale(surface, 1.0f);
    winghostty_cell_metrics metrics = {8, 16, 8, 16, 13};
    (void)winghostty_surface_set_cell_metrics(surface, &metrics);
    (void)winghostty_surface_get_cell_metrics(surface, &metrics);
    (void)winghostty_surface_get_dpi(surface);
    (void)winghostty_surface_notify_dpi_changed(surface, 120);
    (void)winghostty_surface_set_keyboard_layout(surface, 0);
    (void)winghostty_surface_ime_update(surface, "preedit", 7, 0);
    (void)winghostty_surface_paste_text(surface, "echo", 4, 1);
    (void)winghostty_paste_validate("echo", 4);
    (void)winghostty_surface_read_clipboard(surface, WINGHOSTTY_CLIPBOARD_TEXT);
    (void)winghostty_surface_write_clipboard(
        surface,
        WINGHOSTTY_CLIPBOARD_TEXT,
        "text",
        4
    );
    (void)winghostty_surface_set_link(surface, "https://example.com");
    (void)winghostty_surface_clear_link(surface);
    (void)winghostty_surface_set_selection_text(surface, "text", 4);
    (void)winghostty_surface_clear_selection(surface);
    (void)winghostty_surface_copy_selection(surface);
    (void)winghostty_surface_notify_exit(surface, 0);
    (void)winghostty_surface_notify_title(surface, "title");
    (void)winghostty_surface_notify_cwd(surface, "C:\\");
    (void)winghostty_surface_notify_bell(surface);
    (void)winghostty_surface_notify_notification(surface, "notification");
    (void)winghostty_surface_notify_redraw(surface);
    (void)winghostty_surface_notify_focus(surface, 1);
    (void)winghostty_surface_notify_fatal_error(
        surface,
        WINGHOSTTY_WIN32_ERROR,
        "fatal"
    );
    (void)winghostty_surface_notify_accessibility_name(surface, "Terminal");
    (void)winghostty_surface_notify_accessibility_text(
        surface,
        "hello",
        5,
        0,
        5,
        0,
        0,
        0
    );
    (void)winghostty_surface_notify_terminal_text(
        surface,
        "hello",
        5,
        0,
        5,
        0,
        0,
        0
    );
    (void)winghostty_surface_notify_accessibility_focus(surface, 1);
    (void)winghostty_surface_set_accessibility_role(
        surface,
        WINGHOSTTY_ACCESSIBILITY_TERMINAL
    );
    char copied[8];
    uint64_t copied_length = 0;
    (void)winghostty_surface_copy_accessibility_range(
        surface,
        0,
        5,
        copied,
        sizeof(copied),
        &copied_length
    );
    (void)winghostty_host_drain(host, &drained);
    (void)winghostty_surface_destroy(surface);
    (void)winghostty_host_deinitialize(host);
}
