#ifndef WINGHOSTTY_WIN32_HOST_H
#define WINGHOSTTY_WIN32_HOST_H

#include <stdint.h>
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct winghostty_host winghostty_host;
typedef struct winghostty_surface winghostty_surface;

typedef int32_t winghostty_result;

#define WINGHOSTTY_OK ((winghostty_result)0)
#define WINGHOSTTY_INVALID_ARGUMENT ((winghostty_result)1)
#define WINGHOSTTY_WRONG_THREAD ((winghostty_result)2)
#define WINGHOSTTY_OUT_OF_MEMORY ((winghostty_result)3)
#define WINGHOSTTY_SHUTTING_DOWN ((winghostty_result)4)
#define WINGHOSTTY_WIN32_ERROR ((winghostty_result)5)
#define WINGHOSTTY_SURFACE_INVALIDATED ((winghostty_result)6)
#define WINGHOSTTY_RENDERER_ERROR ((winghostty_result)7)
#define WINGHOSTTY_CONTEXT_ERROR ((winghostty_result)8)
#define WINGHOSTTY_PRESENT_ERROR ((winghostty_result)9)
#define WINGHOSTTY_PASTE_REQUIRES_CONFIRMATION ((winghostty_result)10)
#define WINGHOSTTY_INVALID_UTF8 ((winghostty_result)11)
#define WINGHOSTTY_CLIPBOARD_UNAVAILABLE ((winghostty_result)12)

typedef int32_t winghostty_theme;

#define WINGHOSTTY_THEME_SYSTEM ((winghostty_theme)0)
#define WINGHOSTTY_THEME_LIGHT ((winghostty_theme)1)
#define WINGHOSTTY_THEME_DARK ((winghostty_theme)2)

typedef struct winghostty_rect {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
} winghostty_rect;

typedef struct winghostty_cell_metrics {
    uint32_t font_width;
    uint32_t font_height;
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t baseline;
} winghostty_cell_metrics;

typedef enum winghostty_accessibility_role {
    WINGHOSTTY_ACCESSIBILITY_TERMINAL = 0,
    WINGHOSTTY_ACCESSIBILITY_EDIT = 1,
} winghostty_accessibility_role;

typedef struct winghostty_callbacks {
    void (*on_exit)(
        void *user_data,
        winghostty_surface *surface,
        int32_t status
    );
    void (*on_title)(
        void *user_data,
        winghostty_surface *surface,
        const char *title
    );
    void (*on_cwd)(
        void *user_data,
        winghostty_surface *surface,
        const char *cwd
    );
    void (*on_bell)(void *user_data, winghostty_surface *surface);
    void (*on_notification)(
        void *user_data,
        winghostty_surface *surface,
        const char *notification
    );
    void (*on_redraw)(void *user_data, winghostty_surface *surface);
    void (*on_focus)(
        void *user_data,
        winghostty_surface *surface,
        uint8_t focused
    );
    void (*on_fatal_error)(
        void *user_data,
        winghostty_surface *surface,
        winghostty_result error,
        const char *message
    );
} winghostty_callbacks;

typedef struct winghostty_callbacks_v2 {
    void (*on_exit)(
        void *user_data,
        winghostty_surface *surface,
        int32_t status
    );
    void (*on_title)(
        void *user_data,
        winghostty_surface *surface,
        const char *title
    );
    void (*on_cwd)(
        void *user_data,
        winghostty_surface *surface,
        const char *cwd
    );
    void (*on_bell)(void *user_data, winghostty_surface *surface);
    void (*on_notification)(
        void *user_data,
        winghostty_surface *surface,
        const char *notification
    );
    void (*on_redraw)(void *user_data, winghostty_surface *surface);
    void (*on_focus)(
        void *user_data,
        winghostty_surface *surface,
        uint8_t focused
    );
    void (*on_fatal_error)(
        void *user_data,
        winghostty_surface *surface,
        winghostty_result error,
        const char *message
    );
    void (*on_dpi_changed)(
        void *user_data,
        winghostty_surface *surface,
        uint32_t dpi,
        float scale
    );
    void (*on_metrics_changed)(
        void *user_data,
        winghostty_surface *surface,
        const winghostty_cell_metrics *metrics
    );
    void (*on_accessibility_selection)(
        void *user_data,
        winghostty_surface *surface,
        uint64_t start,
        uint64_t end
    );
} winghostty_callbacks_v2;

typedef enum winghostty_key_action {
    WINGHOSTTY_KEY_RELEASE = 0,
    WINGHOSTTY_KEY_PRESS = 1,
    WINGHOSTTY_KEY_REPEAT = 2
} winghostty_key_action;

typedef enum winghostty_mouse_kind {
    WINGHOSTTY_MOUSE_MOVE = 0,
    WINGHOSTTY_MOUSE_BUTTON_DOWN = 1,
    WINGHOSTTY_MOUSE_BUTTON_UP = 2,
    WINGHOSTTY_MOUSE_WHEEL = 3,
    WINGHOSTTY_MOUSE_LEAVE = 4
} winghostty_mouse_kind;

typedef enum winghostty_clipboard_format {
    WINGHOSTTY_CLIPBOARD_TEXT = 0,
    WINGHOSTTY_CLIPBOARD_HTML = 1
} winghostty_clipboard_format;

typedef enum winghostty_paste_severity {
    WINGHOSTTY_PASTE_SAFE = 0,
    WINGHOSTTY_PASTE_CONTAINS_NEWLINE = 1,
    WINGHOSTTY_PASTE_SHELL_METACHAR = 2,
    WINGHOSTTY_PASTE_CONTROL_CHARS = 3,
    WINGHOSTTY_PASTE_MIXED_CONTENT = 4
} winghostty_paste_severity;

typedef struct winghostty_key_event {
    uint32_t action;
    uint32_t virtual_key;
    uint32_t scan_code;
    uint32_t repeat_count;
    uint32_t flags;
    uint32_t modifiers;
    uintptr_t keyboard_layout;
    uint8_t composing;
    uint8_t dead_key;
    uint8_t reserved[6];
    const char *keyboard_layout_name;
} winghostty_key_event;

typedef struct winghostty_mouse_event {
    uint32_t kind;
    uint32_t button;
    uint32_t modifiers;
    int32_t x;
    int32_t y;
    int32_t cell_x;
    int32_t cell_y;
    int32_t wheel_delta;
    uint32_t click_count;
} winghostty_mouse_event;

typedef struct winghostty_selection_event {
    uint8_t active;
    uint8_t dragging;
    uint8_t rectangular;
    uint8_t reserved;
    int32_t anchor_x;
    int32_t anchor_y;
    int32_t current_x;
    int32_t current_y;
} winghostty_selection_event;

typedef struct winghostty_input_callbacks {
    void (*on_key)(
        void *user_data,
        winghostty_surface *surface,
        const winghostty_key_event *event
    );
    void (*on_text)(
        void *user_data,
        winghostty_surface *surface,
        const char *text,
        uint32_t length
    );
    void (*on_ime_start)(void *user_data, winghostty_surface *surface);
    void (*on_ime_update)(
        void *user_data,
        winghostty_surface *surface,
        const char *text,
        uint32_t length,
        uint8_t committed
    );
    void (*on_ime_end)(void *user_data, winghostty_surface *surface);
    void (*on_mouse)(
        void *user_data,
        winghostty_surface *surface,
        const winghostty_mouse_event *event
    );
    void (*on_selection)(
        void *user_data,
        winghostty_surface *surface,
        const winghostty_selection_event *event
    );
    void (*on_link)(
        void *user_data,
        winghostty_surface *surface,
        const char *url,
        uint8_t hovered,
        uint8_t clicked
    );
    void (*on_paste)(
        void *user_data,
        winghostty_surface *surface,
        const char *text,
        uint32_t length,
        uint8_t bracketed
    );
    void (*on_clipboard_read)(
        void *user_data,
        winghostty_surface *surface,
        uint32_t format,
        const char *text,
        uint32_t length
    );
    void (*on_clipboard_write)(
        void *user_data,
        winghostty_surface *surface,
        uint32_t format,
        const char *text,
        uint32_t length
    );
} winghostty_input_callbacks;

typedef struct winghostty_input_options {
    uint32_t cell_width;
    uint32_t cell_height;
    uint8_t selection_enabled;
    uint8_t links_enabled;
    uint8_t paste_protection;
    uint8_t bracketed_paste;
    uint8_t reserved[4];
    const char *keyboard_layout;
} winghostty_input_options;

typedef struct winghostty_surface_options {
    const char *command;
    const char *cwd;
    const char *environment;
    winghostty_rect bounds;
    uint8_t visible;
    uint8_t focus;
    winghostty_theme theme;
    float font_scale;
    winghostty_callbacks callbacks;
    void *user_data;
} winghostty_surface_options;

typedef struct winghostty_surface_options_v2 {
    uint32_t size;
    uint32_t version;
    const char *command;
    const char *cwd;
    const char *environment;
    winghostty_rect bounds;
    uint8_t visible;
    uint8_t focus;
    winghostty_theme theme;
    float font_scale;
    winghostty_callbacks_v2 callbacks;
    void *user_data;
    winghostty_input_callbacks input_callbacks;
    winghostty_input_options input;
} winghostty_surface_options_v2;

#define WINGHOSTTY_SURFACE_OPTIONS_VERSION_2 ((uint32_t)2)

void winghostty_surface_options_init(winghostty_surface_options *options);
void winghostty_surface_options_v2_init(winghostty_surface_options_v2 *options);

winghostty_result winghostty_host_initialize(winghostty_host **out_host);
winghostty_result winghostty_host_deinitialize(winghostty_host *host);

winghostty_result winghostty_host_create_surface(
    winghostty_host *host,
    HWND parent,
    const winghostty_surface_options *options,
    winghostty_surface **out_surface
);
winghostty_result winghostty_host_create_surface_v2(
    winghostty_host *host,
    HWND parent,
    const winghostty_surface_options_v2 *options,
    winghostty_surface **out_surface
);
winghostty_result winghostty_surface_destroy(winghostty_surface *surface);

winghostty_result winghostty_surface_set_bounds(
    winghostty_surface *surface,
    const winghostty_rect *bounds
);
winghostty_result winghostty_surface_set_visible(
    winghostty_surface *surface,
    uint8_t visible
);
winghostty_result winghostty_surface_set_focus(
    winghostty_surface *surface,
    uint8_t focused
);
winghostty_result winghostty_surface_set_theme(
    winghostty_surface *surface,
    winghostty_theme theme
);
winghostty_result winghostty_surface_set_font_scale(
    winghostty_surface *surface,
    float font_scale
);
winghostty_result winghostty_surface_set_cell_metrics(
    winghostty_surface *surface,
    const winghostty_cell_metrics *metrics
);
winghostty_result winghostty_surface_get_cell_metrics(
    const winghostty_surface *surface,
    winghostty_cell_metrics *out_metrics
);
uint32_t winghostty_surface_get_dpi(const winghostty_surface *surface);
winghostty_result winghostty_surface_notify_dpi_changed(
    winghostty_surface *surface,
    uint32_t dpi
);
winghostty_result winghostty_surface_set_keyboard_layout(
    winghostty_surface *surface,
    uintptr_t keyboard_layout
);
winghostty_result winghostty_surface_ime_update(
    winghostty_surface *surface,
    const char *text,
    uint32_t length,
    uint8_t committed
);

winghostty_result winghostty_surface_paste_text(
    winghostty_surface *surface,
    const char *text,
    uint32_t length,
    uint8_t allow_unsafe
);
uint32_t winghostty_paste_validate(
    const char *text,
    uint32_t length
);

winghostty_result winghostty_surface_read_clipboard(
    winghostty_surface *surface,
    uint32_t format
);
winghostty_result winghostty_surface_write_clipboard(
    winghostty_surface *surface,
    uint32_t format,
    const char *text,
    uint32_t length
);
winghostty_result winghostty_surface_clipboard_read(
    winghostty_surface *surface,
    uint32_t format
);
winghostty_result winghostty_surface_clipboard_write(
    winghostty_surface *surface,
    uint32_t format,
    const char *text,
    uint32_t length
);

winghostty_result winghostty_surface_set_link(
    winghostty_surface *surface,
    const char *url
);
winghostty_result winghostty_surface_clear_link(winghostty_surface *surface);
winghostty_result winghostty_surface_set_selection_text(
    winghostty_surface *surface,
    const char *text,
    uint32_t length
);
winghostty_result winghostty_surface_clear_selection(
    winghostty_surface *surface
);
winghostty_result winghostty_surface_copy_selection(
    winghostty_surface *surface
);

/*
 * Renderer ownership is explicit. Window creation and surface mutation are
 * UI-thread-affine. The first render-context operation claims the host's
 * render thread; subsequent render operations must use that same thread. A
 * pending teardown may be released by calling clear_current from the owning
 * render thread. Scoped rendering and presentation preserve any prior WGL
 * binding, including another surface's persistent context.
 */
winghostty_result winghostty_surface_make_current(winghostty_surface *surface);
winghostty_result winghostty_surface_clear_current(winghostty_surface *surface);
winghostty_result winghostty_surface_render(winghostty_surface *surface);
winghostty_result winghostty_surface_present(winghostty_surface *surface);

HDC winghostty_surface_get_hdc(const winghostty_surface *surface);
HGLRC winghostty_surface_get_hglrc(const winghostty_surface *surface);
uint32_t winghostty_host_get_ui_thread_id(const winghostty_host *host);
uint32_t winghostty_host_get_render_thread_id(const winghostty_host *host);
uint32_t winghostty_surface_get_last_error(const winghostty_surface *surface);
uint64_t winghostty_surface_get_present_count(
    const winghostty_surface *surface
);

winghostty_result winghostty_surface_notify_exit(
    winghostty_surface *surface,
    int32_t status
);
winghostty_result winghostty_surface_notify_title(
    winghostty_surface *surface,
    const char *title
);
winghostty_result winghostty_surface_notify_cwd(
    winghostty_surface *surface,
    const char *cwd
);
winghostty_result winghostty_surface_notify_bell(winghostty_surface *surface);
winghostty_result winghostty_surface_notify_notification(
    winghostty_surface *surface,
    const char *notification
);
winghostty_result winghostty_surface_notify_redraw(winghostty_surface *surface);
winghostty_result winghostty_surface_notify_focus(
    winghostty_surface *surface,
    uint8_t focused
);
winghostty_result winghostty_surface_notify_fatal_error(
    winghostty_surface *surface,
    winghostty_result error,
    const char *message
);
winghostty_result winghostty_surface_notify_accessibility_name(
    winghostty_surface *surface,
    const char *name
);
winghostty_result winghostty_surface_notify_accessibility_text(
    winghostty_surface *surface,
    const char *text,
    uint64_t text_length,
    uint64_t visible_start,
    uint64_t visible_end,
    uint64_t selection_start,
    uint64_t selection_end,
    uint64_t caret
);
winghostty_result winghostty_surface_notify_terminal_text(
    winghostty_surface *surface,
    const char *text,
    uint64_t text_length,
    uint64_t visible_start,
    uint64_t visible_end,
    uint64_t selection_start,
    uint64_t selection_end,
    uint64_t caret
);
winghostty_result winghostty_surface_notify_accessibility_focus(
    winghostty_surface *surface,
    uint8_t focused
);
winghostty_result winghostty_surface_set_accessibility_role(
    winghostty_surface *surface,
    winghostty_accessibility_role role
);
winghostty_result winghostty_surface_copy_accessibility_range(
    winghostty_surface *surface,
    uint64_t start,
    uint64_t end,
    char *buffer,
    uint64_t buffer_length,
    uint64_t *out_written
);

HWND winghostty_surface_get_hwnd(const winghostty_surface *surface);

winghostty_result winghostty_host_drain(
    winghostty_host *host,
    uint32_t *out_drained
);

#ifdef __cplusplus
}
#endif

#endif
