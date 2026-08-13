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

void winghostty_surface_options_init(winghostty_surface_options *options);

winghostty_result winghostty_host_initialize(winghostty_host **out_host);
winghostty_result winghostty_host_deinitialize(winghostty_host *host);

winghostty_result winghostty_host_create_surface(
    winghostty_host *host,
    HWND parent,
    const winghostty_surface_options *options,
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

HWND winghostty_surface_get_hwnd(const winghostty_surface *surface);

winghostty_result winghostty_host_drain(
    winghostty_host *host,
    uint32_t *out_drained
);

#ifdef __cplusplus
}
#endif

#endif
