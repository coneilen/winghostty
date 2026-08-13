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

void winghostty_win32_host_compile_contract(void) {
    winghostty_host *host = 0;
    winghostty_surface *surface = 0;
    winghostty_surface_options options;
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

    (void)winghostty_host_initialize(&host);
    (void)winghostty_host_create_surface(host, (HWND)0, &options, &surface);
    (void)winghostty_surface_set_bounds(surface, &bounds);
    (void)winghostty_surface_set_visible(surface, 1);
    (void)winghostty_surface_set_focus(surface, 1);
    (void)winghostty_surface_set_theme(surface, WINGHOSTTY_THEME_DARK);
    (void)winghostty_surface_set_font_scale(surface, 1.0f);
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
    (void)winghostty_host_drain(host, &drained);
    (void)winghostty_surface_destroy(surface);
    (void)winghostty_host_deinitialize(host);
}
