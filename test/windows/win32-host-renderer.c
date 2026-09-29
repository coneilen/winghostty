#include "../../include/winghostty/win32_host.h"
#include "../../include/ghostty/vt.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <objbase.h>
#include <windows.h>

extern void WINAPI glReadPixels(
    int x,
    int y,
    int width,
    int height,
    unsigned int format,
    unsigned int type,
    void *pixels
);
extern void WINAPI glReadBuffer(unsigned int mode);

typedef struct test_state {
    HWND parent;
    winghostty_host *host;
    winghostty_surface *surface;
    DWORD ui_thread;
    LONG redraw_count;
    LONG focus_count;
    LONG callback_mismatch;
    int deinit_on_child_destroy;
    LONG parent_destroy_notifications;
    LONG parent_destroy_wrong_thread;
    winghostty_result parent_deinit_result;
} test_state;

typedef struct render_call {
    winghostty_surface *surface;
    winghostty_surface *other_surface;
    winghostty_result make_current_result;
    winghostty_result other_present_result;
    winghostty_result clear_current_result;
    winghostty_result render_result;
    winghostty_result present_result;
    winghostty_result terminal_cells_result;
    winghostty_result black_snapshot_result;
    winghostty_result black_render_result;
    winghostty_result black_make_current_result;
    winghostty_result black_restore_result;
    winghostty_result ui_call_result;
    DWORD thread_id;
    int current_after_make;
    int current_after_other_present;
    int current_after_render;
    int current_after_clear;
    int black_foreground_seen;
    int black_background_seen;
    unsigned char terminal_pixel[4];
} render_call;

typedef struct persistent_switch_call {
    winghostty_surface *first;
    winghostty_surface *second;
    winghostty_result first_make_current_result;
    winghostty_result second_make_current_result;
    winghostty_result second_clear_current_result;
    winghostty_result second_make_current_again_result;
    winghostty_result second_clear_current_again_result;
    volatile LONG ready_after_clear;
    volatile LONG continue_after_destroy;
    int current_after_second_make;
    int current_after_second_clear;
    int current_after_second_make_again;
    int current_after_second_clear_again;
} persistent_switch_call;

static int current_matches(winghostty_surface *surface);
static int current_is_clear(void);
static int check(int condition, const char *message);

typedef struct teardown_stress {
    winghostty_host *host;
    winghostty_surface *surface;
    HWND parent;
    winghostty_surface_options options;
    volatile LONG stop;
    volatile LONG entered;
    volatile LONG failures;
} teardown_stress;

typedef struct clear_admission_stress {
    winghostty_surface *surface;
    volatile LONG stop;
    volatile LONG entered;
    volatile LONG failures;
    volatile LONG clear_ok;
    volatile LONG clear_rejected;
} clear_admission_stress;

typedef struct reentrant_destroy_cycle {
    volatile LONG destroyed;
    volatile LONG failures;
    winghostty_result destroy_result;
} reentrant_destroy_cycle;

typedef struct deferred_deinit_stress {
    winghostty_host *host;
    winghostty_surface *surface;
    volatile LONG stop;
    volatile LONG entered;
    volatile LONG failures;
} deferred_deinit_stress;

typedef struct process_heap_usage {
    SIZE_T busy_blocks;
    SIZE_T busy_bytes;
} process_heap_usage;

typedef struct vt_snapshot {
    winghostty_terminal_cell *cells;
    uint32_t columns;
    uint32_t rows;
    uint32_t visible_column;
    uint32_t visible_row;
} vt_snapshot;

typedef struct vt_render_call {
    winghostty_surface *surface;
    uint32_t pixel_x;
    uint32_t pixel_y;
    winghostty_result make_current_result;
    winghostty_result render_result;
    winghostty_result present_result;
    winghostty_result clear_current_result;
    unsigned char pixel[4];
} vt_render_call;

#define WM_UIA_SELECTION_TEST (0x8000 + 0x41)

static int read_process_heap_usage(process_heap_usage *usage);

static int vt_snapshot_contains(
    const vt_snapshot *snapshot,
    const char *text
) {
    const size_t text_length = strlen(text);
    for (uint32_t row = 0; row < snapshot->rows; ++row) {
        for (uint32_t column = 0; column + text_length <= snapshot->columns; ++column) {
            size_t index = 0;
            while (
                index < text_length &&
                snapshot->cells[row * snapshot->columns + column + index].codepoint ==
                    (uint32_t)(unsigned char)text[index]
            ) {
                index++;
            }
            if (index == text_length) return 1;
        }
    }
    return 0;
}

static void vt_snapshot_free(vt_snapshot *snapshot) {
    free(snapshot->cells);
    memset(snapshot, 0, sizeof(*snapshot));
}

static int vt_snapshot_from_output(
    const char *output,
    vt_snapshot *snapshot
) {
    memset(snapshot, 0, sizeof(*snapshot));
    GhosttyTerminal terminal = NULL;
    GhosttyRenderState render_state = NULL;
    GhosttyRenderStateRowIterator row_iterator = NULL;
    GhosttyRenderStateRowCells row_cells = NULL;
    int success = 0;

    const GhosttyTerminalOptions terminal_options = {
        .cols = 80,
        .rows = 5,
        .max_scrollback = 64,
    };
    if (
        ghostty_terminal_new(NULL, &terminal, terminal_options) !=
            GHOSTTY_SUCCESS ||
        ghostty_render_state_new(NULL, &render_state) != GHOSTTY_SUCCESS
    ) {
        goto cleanup;
    }
    ghostty_terminal_vt_write(
        terminal,
        (const uint8_t *)output,
        strlen(output)
    );
    if (
        ghostty_render_state_update(render_state, terminal) !=
        GHOSTTY_SUCCESS
    ) {
        goto cleanup;
    }

    uint16_t columns = 0;
    uint16_t rows = 0;
    if (
        ghostty_render_state_get(
            render_state,
            GHOSTTY_RENDER_STATE_DATA_COLS,
            &columns
        ) != GHOSTTY_SUCCESS ||
        ghostty_render_state_get(
            render_state,
            GHOSTTY_RENDER_STATE_DATA_ROWS,
            &rows
        ) != GHOSTTY_SUCCESS ||
        columns == 0 ||
        rows == 0
    ) {
        goto cleanup;
    }
    snapshot->columns = columns;
    snapshot->rows = rows;
    snapshot->cells = calloc(
        (size_t)columns * rows,
        sizeof(*snapshot->cells)
    );
    if (snapshot->cells == NULL) goto cleanup;

    GhosttyRenderStateColors colors =
        GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    if (
        ghostty_render_state_colors_get(render_state, &colors) !=
        GHOSTTY_SUCCESS
    ) {
        goto cleanup;
    }
    if (
        ghostty_render_state_row_iterator_new(NULL, &row_iterator) !=
            GHOSTTY_SUCCESS ||
        ghostty_render_state_get(
            render_state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            &row_iterator
        ) != GHOSTTY_SUCCESS ||
        ghostty_render_state_row_cells_new(NULL, &row_cells) !=
            GHOSTTY_SUCCESS
    ) {
        goto cleanup;
    }

    uint32_t row = 0;
    while (
        row < snapshot->rows &&
        ghostty_render_state_row_iterator_next(row_iterator)
    ) {
        if (
            ghostty_render_state_row_get(
                row_iterator,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &row_cells
            ) != GHOSTTY_SUCCESS
        ) {
            goto cleanup;
        }
        uint32_t column = 0;
        while (
            column < snapshot->columns &&
            ghostty_render_state_row_cells_next(row_cells)
        ) {
            winghostty_terminal_cell *cell =
                &snapshot->cells[row * snapshot->columns + column];
            uint32_t graphemes_len = 0;
            if (
                ghostty_render_state_row_cells_get(
                    row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    &graphemes_len
                ) != GHOSTTY_SUCCESS
            ) {
                goto cleanup;
            }
            if (graphemes_len != 0) {
                uint32_t codepoints[16] = {0};
                if (
                    ghostty_render_state_row_cells_get(
                        row_cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        codepoints
                    ) != GHOSTTY_SUCCESS
                ) {
                    goto cleanup;
                }
                cell->codepoint = codepoints[0];
            }

            GhosttyColorRgb color;
            cell->foreground =
                colors.foreground.r << 16 |
                colors.foreground.g << 8 |
                colors.foreground.b;
            if (
                ghostty_render_state_row_cells_get(
                    row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                    &color
                ) == GHOSTTY_SUCCESS
            ) {
                cell->foreground =
                    color.r << 16 | color.g << 8 | color.b;
            }
            cell->background =
                colors.background.r << 16 |
                colors.background.g << 8 |
                colors.background.b;
            if (
                ghostty_render_state_row_cells_get(
                    row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                    &color
                ) == GHOSTTY_SUCCESS
            ) {
                cell->background =
                    color.r << 16 | color.g << 8 | color.b;
            }
            cell->flags =
                WINGHOSTTY_TERMINAL_CELL_FOREGROUND_DEFAULT |
                WINGHOSTTY_TERMINAL_CELL_BACKGROUND_DEFAULT;
            if (
                ghostty_render_state_row_cells_get(
                    row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                    &color
                ) == GHOSTTY_SUCCESS
            ) {
                    cell->flags =
                        (cell->flags &
                            ~WINGHOSTTY_TERMINAL_CELL_FOREGROUND_DEFAULT) |
                        WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET;
                }
            if (
                ghostty_render_state_row_cells_get(
                    row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                    &color
                ) == GHOSTTY_SUCCESS
            ) {
                    cell->flags =
                        (cell->flags &
                            ~WINGHOSTTY_TERMINAL_CELL_BACKGROUND_DEFAULT) |
                        WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET;
                }
            column++;
        }
        row++;
    }
    if (row != snapshot->rows) goto cleanup;

    for (row = 0; row < snapshot->rows; ++row) {
        for (uint32_t column = 0; column < snapshot->columns; ++column) {
            if (
                snapshot->cells[row * snapshot->columns + column].codepoint ==
                    'v' &&
                snapshot->cells[row * snapshot->columns + column].background ==
                    0xCC2211
            ) {
                snapshot->visible_column = column;
                snapshot->visible_row = row;
                success = 1;
                goto cleanup;
            }
        }
    }

cleanup:
    if (row_cells != NULL) ghostty_render_state_row_cells_free(row_cells);
    if (row_iterator != NULL) {
        ghostty_render_state_row_iterator_free(row_iterator);
    }
    if (render_state != NULL) ghostty_render_state_free(render_state);
    if (terminal != NULL) ghostty_terminal_free(terminal);
    if (!success) vt_snapshot_free(snapshot);
    return success;
}

static DWORD WINAPI vt_render_thread(void *parameter) {
    vt_render_call *call = (vt_render_call *)parameter;
    call->make_current_result =
        winghostty_surface_make_current(call->surface);
    if (call->make_current_result != WINGHOSTTY_OK) return 0;
    call->render_result = winghostty_surface_render(call->surface);
    /*
     * Render the same frame twice, then read GL_BACK.
     *
     * winghostty_surface_render calls SwapBuffers internally, so which buffer
     * holds the frame afterwards is ICD-dependent: hardware drivers swap by
     * flipping, Microsoft's GDI Generic software rasterizer swaps by copying.
     * Worse, under GDI Generic the front buffer of a never-shown window is the
     * window itself, so it is fully clipped and reads back undefined or
     * foreign pixels.
     *
     * Rendering twice makes both buffers hold this frame under flip
     * semantics, while under copy semantics the back buffer always holds the
     * latest frame. The back buffer is a real off-screen surface regardless of
     * window visibility, so GL_BACK is the only portable choice here.
     */
    if (call->render_result == WINGHOSTTY_OK) {
        call->render_result = winghostty_surface_render(call->surface);
    }
    glReadBuffer(0x0405);
    glReadPixels(
        (int)call->pixel_x,
        (int)call->pixel_y,
        1,
        1,
        0x1908,
        0x1401,
        call->pixel
    );
    call->present_result = winghostty_surface_present(call->surface);
    call->clear_current_result =
        winghostty_surface_clear_current(call->surface);
    return 0;
}

static void drain_messages(void) {
    MSG message;
    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

static int wait_for_surface_finalization(winghostty_surface *surface) {
    for (int attempt = 0; attempt < 5000; ++attempt) {
        const winghostty_result result =
            winghostty_surface_destroy(surface);
        drain_messages();
        if (result == WINGHOSTTY_INVALID_ARGUMENT) return 1;
        if (result != WINGHOSTTY_SURFACE_INVALIDATED &&
            result != WINGHOSTTY_SHUTTING_DOWN) {
            return 0;
        }
        Sleep(1);
    }
    return 0;
}

static int wait_for_host_finalization(winghostty_host *host) {
    for (int attempt = 0; attempt < 5000; ++attempt) {
        drain_messages();
        if (winghostty_host_get_ui_thread_id(host) == 0) return 1;
        Sleep(1);
    }
    return 0;
}

static LRESULT CALLBACK parent_window_proc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam
) {
    (void)lparam;
    test_state *state = (test_state *)(LONG_PTR)GetWindowLongPtrW(
        hwnd,
        GWLP_USERDATA
    );
    if (message == WM_PARENTNOTIFY &&
        LOWORD(wparam) == WM_DESTROY &&
        state != NULL) {
        InterlockedIncrement(&state->parent_destroy_notifications);
        if (GetCurrentThreadId() != state->ui_thread) {
            InterlockedIncrement(&state->parent_destroy_wrong_thread);
        }
        if (state->deinit_on_child_destroy && state->host != NULL) {
            state->parent_deinit_result =
                winghostty_host_deinitialize(state->host);
        }

    }
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

static void on_reentrant_destroy_redraw(
    void *user_data,
    winghostty_surface *surface
) {
    reentrant_destroy_cycle *cycle = (reentrant_destroy_cycle *)user_data;
    cycle->destroy_result = winghostty_surface_destroy(surface);
    if (cycle->destroy_result != WINGHOSTTY_OK) {
        InterlockedIncrement(&cycle->failures);
    }
    InterlockedIncrement(&cycle->destroyed);
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
    /*
     * Render twice and read GL_BACK. See the rationale in vt_render_thread:
     * winghostty_surface_render swaps internally, so GL_FRONT is not a
     * portable place to look for the frame we just drew, and under the GDI
     * Generic software rasterizer the front buffer of a never-shown window is
     * the clipped window itself.
     */
    if (call->render_result == WINGHOSTTY_OK) {
        call->render_result = winghostty_surface_render(call->surface);
    }
    call->current_after_render = current_matches(call->surface);
    glReadBuffer(0x0405);
    glReadPixels(
        1,
        1,
        1,
        1,
        0x1908,
        0x1401,
        call->terminal_pixel
    );
    call->black_render_result =
        winghostty_surface_render(call->other_surface);
    if (call->black_render_result == WINGHOSTTY_OK) {
        call->black_render_result =
            winghostty_surface_render(call->other_surface);
    }
    call->black_make_current_result =
        winghostty_surface_make_current(call->other_surface);
    unsigned char pixels[320 * 240 * 4];
    memset(pixels, 0, sizeof(pixels));
    glReadBuffer(0x0405);
    glReadPixels(0, 0, 320, 240, 0x1908, 0x1401, pixels);
    for (int y = 0; y < 240; ++y) {
        for (int x = 0; x < 320; ++x) {
            const unsigned char *pixel = &pixels[(y * 320 + x) * 4];
            if (x < 160 &&
                pixel[0] == 0 &&
                pixel[1] == 0 &&
                pixel[2] == 0) {
                call->black_foreground_seen = 1;
            }
            if (x >= 160 &&
                pixel[0] == 0 &&
                pixel[1] == 0 &&
                pixel[2] == 0) {
                call->black_background_seen = 1;
            }
        }
    }
    call->black_restore_result =
        winghostty_surface_make_current(call->surface);
    call->clear_current_result =
        winghostty_surface_clear_current(call->surface);
    call->current_after_clear = current_is_clear();
    call->present_result = winghostty_surface_present(call->surface);

    winghostty_rect bounds = {0, 0, 11, 11};
    call->ui_call_result =
        winghostty_surface_set_bounds(call->surface, &bounds);
    return 0;
}

static DWORD WINAPI persistent_switch_thread(void *parameter) {
    persistent_switch_call *call = (persistent_switch_call *)parameter;
    call->first_make_current_result =
        winghostty_surface_make_current(call->first);
    call->second_make_current_result =
        winghostty_surface_make_current(call->second);
    call->current_after_second_make = current_matches(call->second);
    call->second_clear_current_result =
        winghostty_surface_clear_current(call->second);
    call->current_after_second_clear = current_is_clear();
    InterlockedExchange(&call->ready_after_clear, 1);
    while (InterlockedCompareExchange(
               &call->continue_after_destroy,
               0,
               0
           ) == 0) {
        Sleep(1);
    }
    call->second_make_current_again_result =
        winghostty_surface_make_current(call->second);
    call->current_after_second_make_again = current_matches(call->second);
    call->second_clear_current_again_result =
        winghostty_surface_clear_current(call->second);
    call->current_after_second_clear_again = current_is_clear();
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

static int public_result_allowed(winghostty_result result) {
    return result >= WINGHOSTTY_OK && result <= WINGHOSTTY_PRESENT_ERROR;
}

static int invalid_state_result(winghostty_result result) {
    return result == WINGHOSTTY_INVALID_ARGUMENT ||
        result == WINGHOSTTY_SHUTTING_DOWN ||
        result == WINGHOSTTY_SURFACE_INVALIDATED;
}

static int check_stale_surface(winghostty_surface *surface) {
    winghostty_rect bounds = {0, 0, 80, 40};
    char title[] = "stale";
    char cwd[] = "C:\\";
    char notification[] = "stale";
    char fatal[] = "stale";
    return check(
        invalid_state_result(winghostty_surface_destroy(surface)) &&
            invalid_state_result(winghostty_surface_set_bounds(surface, &bounds)) &&
            invalid_state_result(winghostty_surface_set_visible(surface, 0)) &&
            invalid_state_result(winghostty_surface_set_focus(surface, 0)) &&
            invalid_state_result(winghostty_surface_set_theme(
                surface,
                WINGHOSTTY_THEME_SYSTEM
            )) &&
            invalid_state_result(winghostty_surface_set_font_scale(surface, 1.0f)) &&
            invalid_state_result(winghostty_surface_make_current(surface)) &&
            invalid_state_result(winghostty_surface_clear_current(surface)) &&
            invalid_state_result(winghostty_surface_render(surface)) &&
            invalid_state_result(winghostty_surface_present(surface)) &&
            invalid_state_result(winghostty_surface_notify_exit(surface, 0)) &&
            invalid_state_result(winghostty_surface_notify_title(surface, title)) &&
            invalid_state_result(winghostty_surface_notify_cwd(surface, cwd)) &&
            invalid_state_result(winghostty_surface_notify_bell(surface)) &&
            invalid_state_result(winghostty_surface_notify_notification(
                surface,
                notification
            )) &&
            invalid_state_result(winghostty_surface_notify_redraw(surface)) &&
            invalid_state_result(winghostty_surface_notify_focus(surface, 0)) &&
            invalid_state_result(winghostty_surface_notify_fatal_error(
                surface,
                WINGHOSTTY_RENDERER_ERROR,
                fatal
            )),
        "stale surface handle was not rejected"
    );
}

static int check_stale_host(
    winghostty_host *host,
    HWND parent
) {
    winghostty_surface_options options;
    winghostty_surface *surface = NULL;
    winghostty_surface_options_init(&options);
    return check(
        winghostty_host_deinitialize(host) == WINGHOSTTY_INVALID_ARGUMENT &&
            winghostty_host_create_surface(
                host,
                parent,
                &options,
                &surface
            ) == WINGHOSTTY_INVALID_ARGUMENT &&
            surface == NULL &&
            winghostty_host_drain(host, NULL) == WINGHOSTTY_INVALID_ARGUMENT &&
            winghostty_host_get_ui_thread_id(host) == 0 &&
            winghostty_host_get_render_thread_id(host) == 0,
        "stale host handle was not rejected"
    );
}

static DWORD WINAPI teardown_stress_thread(void *parameter) {
    teardown_stress *stress = (teardown_stress *)parameter;
    winghostty_rect bounds = {0, 0, 81, 41};
    char title[] = "stress";
    char cwd[] = "C:\\";
    char notification[] = "stress";
    char fatal[] = "stress";
    while (InterlockedCompareExchange(&stress->stop, 0, 0) == 0) {
        InterlockedIncrement(&stress->entered);
        winghostty_surface *created = NULL;
        winghostty_result result = winghostty_host_create_surface(
            stress->host,
            stress->parent,
            &stress->options,
            &created
        );
        if (!public_result_allowed(result) || created != NULL) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_set_bounds(stress->surface, &bounds);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_set_visible(stress->surface, 0);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_set_focus(stress->surface, 0);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_set_theme(
            stress->surface,
            WINGHOSTTY_THEME_DARK
        );
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_set_font_scale(stress->surface, 1.0f);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_exit(stress->surface, 0);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_title(stress->surface, title);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_cwd(stress->surface, cwd);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_bell(stress->surface);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_notification(
            stress->surface,
            notification
        );
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_redraw(stress->surface);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_focus(stress->surface, 0);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_notify_fatal_error(
            stress->surface,
            WINGHOSTTY_RENDERER_ERROR,
            fatal
        );
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_surface_make_current(stress->surface);
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
        (void)winghostty_surface_get_hwnd(stress->surface);
        (void)winghostty_surface_get_hdc(stress->surface);
        (void)winghostty_surface_get_hglrc(stress->surface);
        (void)winghostty_surface_get_last_error(stress->surface);
        (void)winghostty_surface_get_present_count(stress->surface);
        (void)winghostty_host_get_ui_thread_id(stress->host);
        (void)winghostty_host_get_render_thread_id(stress->host);
        result = winghostty_host_drain(stress->host, NULL);
        if (!public_result_allowed(result)) {
            InterlockedIncrement(&stress->failures);
        }
        result = winghostty_host_deinitialize(stress->host);
        if (!public_result_allowed(result)) {
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

static int read_process_heap_usage(process_heap_usage *usage) {
    HANDLE heap = GetProcessHeap();
    PROCESS_HEAP_ENTRY entry = {0};
    usage->busy_blocks = 0;
    usage->busy_bytes = 0;
    if (heap == NULL || !HeapLock(heap)) {
        return 0;
    }
    while (HeapWalk(heap, &entry)) {
        if ((entry.wFlags & PROCESS_HEAP_ENTRY_BUSY) != 0) {
            ++usage->busy_blocks;
            usage->busy_bytes += entry.cbData;
        }
    }
    DWORD error = GetLastError();
    HeapUnlock(heap);
    return error == ERROR_NO_MORE_ITEMS;
}

static int clear_result_allowed(winghostty_result result) {
    return result == WINGHOSTTY_OK ||
        result == WINGHOSTTY_INVALID_ARGUMENT ||
        result == WINGHOSTTY_SHUTTING_DOWN ||
        result == WINGHOSTTY_SURFACE_INVALIDATED;
}

static DWORD WINAPI clear_admission_stress_thread(void *parameter) {
    clear_admission_stress *stress = (clear_admission_stress *)parameter;
    winghostty_result result = winghostty_surface_make_current(stress->surface);
    if (result != WINGHOSTTY_OK) {
        InterlockedIncrement(&stress->failures);
        return 0;
    }
    InterlockedExchange(&stress->entered, 1);
    while (InterlockedCompareExchange(&stress->stop, 0, 0) == 0) {
        result = winghostty_surface_clear_current(stress->surface);
        if (result == WINGHOSTTY_OK) {
            InterlockedIncrement(&stress->clear_ok);
        } else {
            if (!clear_result_allowed(result)) {
                InterlockedIncrement(&stress->failures);
            }
            InterlockedIncrement(&stress->clear_rejected);
        }
    }
    return 0;
}

static DWORD WINAPI deferred_deinit_stress_thread(void *parameter) {
    deferred_deinit_stress *stress = (deferred_deinit_stress *)parameter;
    InterlockedExchange(&stress->entered, 1);
    while (InterlockedCompareExchange(&stress->stop, 0, 0) == 0) {
        (void)winghostty_surface_get_hdc(stress->surface);
        (void)winghostty_surface_get_hglrc(stress->surface);
        (void)winghostty_surface_get_present_count(stress->surface);
        Sleep(0);
    }
    return 0;
}

static int run_clear_admission_stress(HWND parent) {
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;

    for (int cycle = 0; cycle < 64; ++cycle) {
        winghostty_host *host = NULL;
        winghostty_surface *surface = NULL;
        clear_admission_stress stress = {0};
        if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
            winghostty_host_create_surface(
                host,
                parent,
                &options,
                &surface
            ) != WINGHOSTTY_OK ||
            surface == NULL) {
            if (host != NULL) winghostty_host_deinitialize(host);
            return fail("clear-admission setup failed");
        }

        stress.surface = surface;
        HANDLE thread = CreateThread(
            NULL,
            0,
            clear_admission_stress_thread,
            &stress,
            0,
            NULL
        );
        if (thread == NULL) {
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            return fail("clear-admission worker creation failed");
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
            return fail("clear-admission worker did not enter");
        }
        Sleep(1);
        if (winghostty_surface_destroy(surface) != WINGHOSTTY_OK) {
            InterlockedExchange(&stress.stop, 1);
            WaitForSingleObject(thread, 10000);
            CloseHandle(thread);
            winghostty_host_deinitialize(host);
            return fail("clear-admission destroy failed");
        }
        Sleep(1);
        InterlockedExchange(&stress.stop, 1);
        if (WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0) {
            CloseHandle(thread);
            winghostty_host_deinitialize(host);
            return fail("clear-admission worker did not finish");
        }
        CloseHandle(thread);
        if (stress.failures != 0 ||
            stress.clear_ok == 0 ||
            stress.clear_rejected == 0) {
            winghostty_host_deinitialize(host);
            return fail("clear-admission pre-admitted/late race failed");
        }
        if (winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
            return fail("clear-admission host teardown failed");
        }
    }
    return 0;
}

static int run_uia_selection_token_contract(HWND parent) {
    winghostty_host *host = NULL;
    winghostty_surface *surface = NULL;
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;
    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
        winghostty_host_create_surface(
            host,
            parent,
            &options,
            &surface
        ) != WINGHOSTTY_OK ||
        surface == NULL) {
        if (host != NULL) winghostty_host_deinitialize(host);
        return fail("UIA selection token setup failed");
    }

    HWND hwnd = winghostty_surface_get_hwnd(surface);
    if (hwnd == NULL) {
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return fail("UIA selection token HWND lookup failed");
    }
    (void)SendMessageW(hwnd, WM_UIA_SELECTION_TEST, 0, (LPARAM)1);
    (void)SendMessageW(hwnd, WM_UIA_SELECTION_TEST, 0, (LPARAM)-1);
    (void)SendMessageW(hwnd, WM_UIA_SELECTION_TEST, 0, (LPARAM)0x7fffffff);

    if (winghostty_surface_destroy(surface) != WINGHOSTTY_OK ||
        winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
        return fail("UIA selection token teardown failed");
    }
    return 0;
}

static int run_reentrant_destroy_heap_contract(HWND parent) {
    winghostty_host *host = NULL;
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;
    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK) {
        return fail("reentrant callback host setup failed");
    }

    process_heap_usage before;
    process_heap_usage after;
    if (!read_process_heap_usage(&before)) {
        winghostty_host_deinitialize(host);
        return fail("reentrant callback heap measurement failed before");
    }

    for (int cycle = 0; cycle < 100; ++cycle) {
        reentrant_destroy_cycle state = {0};
        options.user_data = &state;
        options.callbacks.on_redraw = on_reentrant_destroy_redraw;
        winghostty_surface *surface = NULL;
        if (winghostty_host_create_surface(
                host,
                parent,
                &options,
                &surface
            ) != WINGHOSTTY_OK ||
            surface == NULL) {
            winghostty_host_deinitialize(host);
            return fail("reentrant callback surface setup failed");
        }
        if (winghostty_surface_notify_redraw(surface) != WINGHOSTTY_OK ||
            state.destroyed != 1 ||
            state.failures != 0 ||
            !invalid_state_result(winghostty_surface_destroy(surface))) {
            winghostty_host_deinitialize(host);
            return fail("reentrant callback destroy failed");
        }
        if (!wait_for_surface_finalization(surface)) {
            winghostty_host_deinitialize(host);
            return fail("reentrant callback surface finalization did not complete");
        }
    }

    if (!read_process_heap_usage(&after)) {
        winghostty_host_deinitialize(host);
        return fail("reentrant callback heap measurement failed after");
    }
    if (after.busy_blocks > before.busy_blocks + 64 ||
        after.busy_bytes > before.busy_bytes + (2 * 1024 * 1024)) {
        winghostty_host_deinitialize(host);
        return fail("reentrant callback surfaces remained retained");
    }
    if (winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
        return fail("reentrant callback host teardown failed");
    }
    return 0;
}

static int run_deferred_host_ui_thread_contract(test_state *state) {
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;
    state->parent_destroy_wrong_thread = 0;

    for (int cycle = 0; cycle < 64; ++cycle) {
        winghostty_host *host = NULL;
        winghostty_surface *surface = NULL;
        deferred_deinit_stress stress = {0};
        if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
            winghostty_host_create_surface(
                host,
                state->parent,
                &options,
                &surface
            ) != WINGHOSTTY_OK ||
            surface == NULL) {
            if (host != NULL) winghostty_host_deinitialize(host);
            return fail("deferred host teardown setup failed");
        }
        stress.host = host;
        stress.surface = surface;
        HANDLE thread = CreateThread(
            NULL,
            0,
            deferred_deinit_stress_thread,
            &stress,
            0,
            NULL
        );
        if (thread == NULL) {
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            return fail("deferred host teardown worker creation failed");
        }
        for (int i = 0; i < 100 && stress.entered == 0; ++i) {
            Sleep(1);
        }
        if (stress.entered == 0 ||
            winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
            InterlockedExchange(&stress.stop, 1);
            WaitForSingleObject(thread, 10000);
            CloseHandle(thread);
            return fail("deferred host teardown request failed");
        }
        for (int i = 0; i < 1000; ++i) {
            MSG message;
            while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if (winghostty_host_get_ui_thread_id(host) == 0) break;
            Sleep(1);
        }
        InterlockedExchange(&stress.stop, 1);
        if (WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0) {
            CloseHandle(thread);
            return fail("deferred host teardown worker did not finish");
        }
        CloseHandle(thread);
        if (stress.failures != 0 ||
            winghostty_host_get_ui_thread_id(host) != 0 ||
            state->parent_destroy_wrong_thread != 0) {
            return fail("deferred host teardown finalized off the UI thread");
        }
    }
    return 0;
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
        .terminal_cells_result = WINGHOSTTY_INVALID_ARGUMENT,
        .black_snapshot_result = WINGHOSTTY_INVALID_ARGUMENT,
        .black_render_result = WINGHOSTTY_INVALID_ARGUMENT,
        .black_make_current_result = WINGHOSTTY_INVALID_ARGUMENT,
        .black_restore_result = WINGHOSTTY_INVALID_ARGUMENT,
        .ui_call_result = WINGHOSTTY_INVALID_ARGUMENT,
        .thread_id = 0,
        .current_after_make = 0,
        .current_after_other_present = 0,
        .current_after_render = 0,
        .current_after_clear = 0,
    };
    const winghostty_terminal_cell cell = {
        .codepoint = 'A',
        .foreground = 0xFFFFFF,
        .background = 0xCC2211,
        .flags =
            WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
            WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
    };
    const winghostty_terminal_cell black_cells[] = {
        {
            .codepoint = 'B',
            .foreground = 0x000000,
            .background = 0xCC2211,
            .flags =
                WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
                WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
        },
        {
            .codepoint = 'C',
            .foreground = 0xFFFFFF,
            .background = 0x000000,
            .flags =
                WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
                WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
        },
    };
    winghostty_terminal_snapshot marker_snapshot;
    winghostty_terminal_snapshot_init(&marker_snapshot);
    marker_snapshot.columns = 1;
    marker_snapshot.rows = 1;
    marker_snapshot.cells = &cell;
    marker_snapshot.cell_count = 1;
    marker_snapshot.generation = 1;
    call.terminal_cells_result =
        winghostty_surface_set_terminal_snapshot(
            state->surface,
            &marker_snapshot
        );
    winghostty_terminal_snapshot black_snapshot;
    winghostty_terminal_snapshot_init(&black_snapshot);
    black_snapshot.columns = 2;
    black_snapshot.rows = 1;
    black_snapshot.cells = black_cells;
    black_snapshot.cell_count = 2;
    black_snapshot.generation = 2;
    call.black_snapshot_result =
        winghostty_surface_set_terminal_snapshot(
            second,
            &black_snapshot
        );
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
            call.terminal_cells_result == WINGHOSTTY_OK,
            "terminal render-state cell update failed"
        ) ||
        check(
            call.black_snapshot_result == WINGHOSTTY_OK &&
                call.black_render_result == WINGHOSTTY_OK &&
                call.black_make_current_result == WINGHOSTTY_OK &&
                call.black_restore_result == WINGHOSTTY_OK &&
                call.black_foreground_seen &&
                call.black_background_seen,
            "explicit black foreground/background colors were not rendered"
        ) ||
        check(
            call.terminal_pixel[0] == 0xCC &&
                call.terminal_pixel[1] == 0x22 &&
                call.terminal_pixel[2] == 0x11,
            "terminal render-state cell was not pixel-observable"
        ) ||
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
            /*
             * 3, not 2: render_thread now renders each surface twice so the
             * frame is readable from GL_BACK on every ICD. Each render
             * presents once, so surface A is render + render + explicit
             * present and surface B is explicit present + render + render.
             * This tracks the added render; it does not relax the original
             * "presentation count advances" expectation.
             */
            winghostty_surface_get_present_count(state->surface) == 3,
            "presentation count did not advance"
        ) ||
        check(
            winghostty_surface_get_present_count(second) == 3,
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

static int run_vt_render_state_contract(HWND parent) {
    const char *output =
        "\033[2J\033[H$ echo visible\r\n"
        "\033[48;2;204;34;17mvisible\033[0m\r\n";
    vt_snapshot snapshot;
    if (
        check(
            vt_snapshot_from_output(output, &snapshot),
            "libghostty-vt render-state snapshot extraction failed"
        ) ||
        check(
            vt_snapshot_contains(&snapshot, "visible"),
            "libghostty-vt render-state snapshot lost visible output"
        )
    ) {
        return 1;
    }

    for (int reconnect = 0; reconnect < 2; ++reconnect) {
        winghostty_host *host = NULL;
        winghostty_surface *surface = NULL;
        winghostty_surface_options options;
        winghostty_surface_options_init(&options);
        options.visible = 0;
        options.bounds.width = 640;
        options.bounds.height = 240;
        if (
            winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
            winghostty_host_create_surface(
                host,
                parent,
                &options,
                &surface
            ) != WINGHOSTTY_OK ||
            surface == NULL
        ) {
            if (host != NULL) winghostty_host_deinitialize(host);
            vt_snapshot_free(&snapshot);
            return fail("VT render-state surface setup failed");
        }
        winghostty_terminal_snapshot terminal_snapshot;
        winghostty_terminal_snapshot_init(&terminal_snapshot);
        terminal_snapshot.columns = snapshot.columns;
        terminal_snapshot.rows = snapshot.rows;
        terminal_snapshot.cells = snapshot.cells;
        terminal_snapshot.cell_count =
            (uint64_t)snapshot.columns * snapshot.rows;
        terminal_snapshot.generation = (uint64_t)reconnect + 2;
        if (
            winghostty_surface_set_terminal_snapshot(
                surface,
                &terminal_snapshot
            ) != WINGHOSTTY_OK
        ) {
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            vt_snapshot_free(&snapshot);
            return fail("VT render-state feed failed");
        }

        vt_render_call call = {
            .surface = surface,
            .pixel_x = snapshot.visible_column * 8 + 1,
            .pixel_y =
                (snapshot.rows - snapshot.visible_row - 1) * 48 + 1,
            .make_current_result = WINGHOSTTY_INVALID_ARGUMENT,
            .render_result = WINGHOSTTY_INVALID_ARGUMENT,
            .present_result = WINGHOSTTY_INVALID_ARGUMENT,
            .clear_current_result = WINGHOSTTY_INVALID_ARGUMENT,
        };
        HANDLE thread = CreateThread(
            NULL,
            0,
            vt_render_thread,
            &call,
            0,
            NULL
        );
        if (thread == NULL) {
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            vt_snapshot_free(&snapshot);
            return fail("VT render-state thread creation failed");
        }
        WaitForSingleObject(thread, INFINITE);
        CloseHandle(thread);
        if (
            call.make_current_result != WINGHOSTTY_OK ||
            call.render_result != WINGHOSTTY_OK ||
            call.present_result != WINGHOSTTY_OK ||
            call.clear_current_result != WINGHOSTTY_OK
        ) {
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            vt_snapshot_free(&snapshot);
            return fail("VT render-state render/present failed");
        }
        if (
            call.pixel[0] != 0xCC ||
            call.pixel[1] != 0x22 ||
            call.pixel[2] != 0x11
        ) {
            fprintf(
                stderr,
                "VT render-state pixel=%02x %02x %02x %02x\n",
                call.pixel[0],
                call.pixel[1],
                call.pixel[2],
                call.pixel[3]
            );
            winghostty_surface_destroy(surface);
            winghostty_host_deinitialize(host);
            vt_snapshot_free(&snapshot);
            return fail("VT render-state cell was not pixel-observable");
        }
        if (
            winghostty_surface_destroy(surface) != WINGHOSTTY_OK ||
            winghostty_host_deinitialize(host) != WINGHOSTTY_OK
        ) {
            vt_snapshot_free(&snapshot);
            return fail("VT render-state reconnect teardown failed");
        }
    }

    vt_snapshot_free(&snapshot);
    return 0;
}

#define GLYPH_FB_WIDTH 64
#define GLYPH_FB_HEIGHT 32
#define GLYPH_COLUMNS 4
#define GLYPH_CELL_WIDTH (GLYPH_FB_WIDTH / GLYPH_COLUMNS)

typedef struct {
    winghostty_surface *surface;
    HANDLE frame_ready;
    HANDLE next_frame;
    winghostty_result make_current_result;
    winghostty_result clear_current_result;
    winghostty_result render_result[2];
    winghostty_result present_result[2];
    unsigned char frames[2][GLYPH_FB_WIDTH * GLYPH_FB_HEIGHT * 4];
} glyph_render_session;

/*
 * The host binds a single render thread for the process lifetime, so both
 * frames are produced here and the main thread only swaps snapshots between
 * them.
 */
static DWORD WINAPI glyph_render_thread(void *parameter) {
    glyph_render_session *session = (glyph_render_session *)parameter;
    session->make_current_result =
        winghostty_surface_make_current(session->surface);
    if (session->make_current_result != WINGHOSTTY_OK) {
        SetEvent(session->frame_ready);
        SetEvent(session->frame_ready);
        return 0;
    }
    for (int frame = 0; frame < 2; ++frame) {
        if (frame > 0) {
            WaitForSingleObject(session->next_frame, INFINITE);
        }
        session->render_result[frame] =
            winghostty_surface_render(session->surface);
        /*
         * winghostty_surface_render swaps internally, so which buffer holds
         * this frame depends on whether the ICD swaps by flipping (hardware
         * drivers) or by copying (Microsoft's GDI Generic software
         * rasterizer). Rendering the same snapshot twice leaves the frame in
         * the back buffer either way, and the back buffer is a real
         * off-screen surface even for a window that is never shown. The front
         * buffer is not: under GDI Generic it is the window itself, so it is
         * entirely clipped away while the window is invisible and reads back
         * unrelated pixels.
         */
        if (session->render_result[frame] == WINGHOSTTY_OK) {
            session->render_result[frame] =
                winghostty_surface_render(session->surface);
        }
        glReadBuffer(0x0405);
        glReadPixels(
            0,
            0,
            GLYPH_FB_WIDTH,
            GLYPH_FB_HEIGHT,
            0x1908,
            0x1401,
            session->frames[frame]
        );
        session->present_result[frame] =
            winghostty_surface_present(session->surface);
        SetEvent(session->frame_ready);
    }
    session->clear_current_result =
        winghostty_surface_clear_current(session->surface);
    return 0;
}

/*
 * Count pixels inside a cell column that differ from that cell's background.
 * This is the ink measurement: real glyph coverage produces ink, an empty or
 * skipped cell produces none.
 */
static unsigned glyph_cell_ink(
    const unsigned char *pixels,
    int column,
    unsigned char r,
    unsigned char g,
    unsigned char b
) {
    unsigned ink = 0;
    for (int y = 0; y < GLYPH_FB_HEIGHT; ++y) {
        for (int x = column * GLYPH_CELL_WIDTH;
             x < (column + 1) * GLYPH_CELL_WIDTH;
             ++x) {
            const unsigned char *p = pixels + ((size_t)y * GLYPH_FB_WIDTH + x) * 4;
            const int dr = (int)p[0] - (int)r;
            const int dg = (int)p[1] - (int)g;
            const int db = (int)p[2] - (int)b;
            if (dr > 8 || dr < -8 || dg > 8 || dg < -8 || db > 8 || db < -8) {
                ++ink;
            }
        }
    }
    return ink;
}

/* Count pixels that differ between the same cell column of two renders. */
static unsigned glyph_cell_diff(
    const unsigned char *a,
    const unsigned char *b,
    int column
) {
    unsigned changed = 0;
    for (int y = 0; y < GLYPH_FB_HEIGHT; ++y) {
        for (int x = column * GLYPH_CELL_WIDTH;
             x < (column + 1) * GLYPH_CELL_WIDTH;
             ++x) {
            const size_t offset = ((size_t)y * GLYPH_FB_WIDTH + x) * 4;
            if (a[offset] != b[offset] ||
                a[offset + 1] != b[offset + 1] ||
                a[offset + 2] != b[offset + 2]) {
                ++changed;
            }
        }
    }
    return changed;
}

static int glyph_session_ok(const glyph_render_session *session, int frame) {
    return session->make_current_result == WINGHOSTTY_OK &&
        session->render_result[frame] == WINGHOSTTY_OK &&
        session->present_result[frame] == WINGHOSTTY_OK;
}


/*
 * End-to-end proof that the v2 snapshot reaches real rasterized glyph pixels
 * through the existing WGL context: combining marks change the rendered cell,
 * a wide grapheme puts ink in the column it reserves, per-cell backgrounds are
 * painted, and the untouched v1 path still renders.
 */
static int run_glyph_render_contract(HWND parent) {
    winghostty_host *host = NULL;
    winghostty_surface *surface = NULL;
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = GLYPH_FB_WIDTH;
    options.bounds.height = GLYPH_FB_HEIGHT;
    options.theme = WINGHOSTTY_THEME_DARK;
    options.font_scale = 1.0f;

    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
        winghostty_host_create_surface(host, parent, &options, &surface) !=
            WINGHOSTTY_OK ||
        surface == NULL) {
        if (host != NULL) winghostty_host_deinitialize(host);
        return fail("glyph render surface setup failed");
    }

    /*
     * Column 0: "e"
     * Column 1: "e" + U+0301 (same base codepoint, different grapheme)
     * Column 2: U+4E2D, a wide grapheme
     * Column 3: the continuation cell U+4E2D reserves
     */
    static const uint8_t text[] = {
        'e',
        'e', 0xCC, 0x81,
        0xE4, 0xB8, 0xAD,
    };
    const winghostty_terminal_cell cells[GLYPH_COLUMNS] = {
        {
            .codepoint = 'e',
            .foreground = 0xFFFFFF,
            .background = 0xCC2211,
            .flags = WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
                WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
        },
        {
            .codepoint = 'e',
            .foreground = 0xFFFFFF,
            .background = 0xCC2211,
            .flags = WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
                WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
        },
        {
            .codepoint = 0x4E2D,
            .foreground = 0xFFFFFF,
            .background = 0x113355,
            .flags = WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
                WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
        },
        {
            .codepoint = 0,
            .foreground = 0xFFFFFF,
            .background = 0x113355,
            .flags = WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET |
                WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET,
        },
    };
    const winghostty_terminal_glyph glyphs[GLYPH_COLUMNS] = {
        {.offset = 0, .length = 1, .width = WINGHOSTTY_GLYPH_WIDTH_NARROW, .reserved = 0},
        {.offset = 1, .length = 3, .width = WINGHOSTTY_GLYPH_WIDTH_NARROW, .reserved = 0},
        {.offset = 4, .length = 3, .width = WINGHOSTTY_GLYPH_WIDTH_WIDE, .reserved = 0},
        {.offset = 0, .length = 0, .width = WINGHOSTTY_GLYPH_WIDTH_CONTINUATION, .reserved = 0},
    };

    winghostty_terminal_snapshot_v2 snapshot;
    winghostty_terminal_snapshot_v2_init(&snapshot);
    snapshot.columns = GLYPH_COLUMNS;
    snapshot.rows = 1;
    snapshot.cells = cells;
    snapshot.cell_count = GLYPH_COLUMNS;
    snapshot.glyphs = glyphs;
    snapshot.glyph_count = GLYPH_COLUMNS;
    snapshot.text = text;
    snapshot.text_length = sizeof(text);
    snapshot.generation = 1;

    if (winghostty_surface_set_terminal_snapshot_v2(surface, &snapshot) !=
        WINGHOSTTY_OK) {
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return fail("v2 snapshot install failed");
    }

    /* A rejected snapshot must not disturb the installed one. */
    winghostty_terminal_glyph broken[GLYPH_COLUMNS];
    memcpy(broken, glyphs, sizeof(glyphs));
    broken[0].length = (uint16_t)(sizeof(text) + 4);
    winghostty_terminal_snapshot_v2 rejected = snapshot;
    rejected.glyphs = broken;
    rejected.generation = 2;
    if (winghostty_surface_set_terminal_snapshot_v2(surface, &rejected) !=
        WINGHOSTTY_INVALID_ARGUMENT) {
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return fail("out-of-range v2 span was accepted");
    }

    static glyph_render_session session;
    memset(&session, 0, sizeof(session));
    session.surface = surface;
    session.make_current_result = WINGHOSTTY_INVALID_ARGUMENT;
    session.clear_current_result = WINGHOSTTY_INVALID_ARGUMENT;
    session.render_result[0] = WINGHOSTTY_INVALID_ARGUMENT;
    session.render_result[1] = WINGHOSTTY_INVALID_ARGUMENT;
    session.present_result[0] = WINGHOSTTY_INVALID_ARGUMENT;
    session.present_result[1] = WINGHOSTTY_INVALID_ARGUMENT;
    session.frame_ready = CreateEventW(NULL, FALSE, FALSE, NULL);
    session.next_frame = CreateEventW(NULL, FALSE, FALSE, NULL);
    HANDLE render_thread_handle = NULL;
    if (session.frame_ready == NULL || session.next_frame == NULL ||
        (render_thread_handle =
             CreateThread(NULL, 0, glyph_render_thread, &session, 0, NULL)) ==
            NULL) {
        if (session.frame_ready != NULL) CloseHandle(session.frame_ready);
        if (session.next_frame != NULL) CloseHandle(session.next_frame);
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return fail("glyph render thread creation failed");
    }
    WaitForSingleObject(session.frame_ready, INFINITE);
    if (!glyph_session_ok(&session, 0)) {
        SetEvent(session.next_frame);
        WaitForSingleObject(render_thread_handle, INFINITE);
        CloseHandle(render_thread_handle);
        CloseHandle(session.frame_ready);
        CloseHandle(session.next_frame);
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return fail("v2 glyph render failed");
    }

    const unsigned char *v2_pixels = session.frames[0];
    const unsigned base_ink = glyph_cell_ink(v2_pixels, 0, 0xCC, 0x22, 0x11);
    const unsigned combined_ink =
        glyph_cell_ink(v2_pixels, 1, 0xCC, 0x22, 0x11);
    const unsigned wide_lead_ink =
        glyph_cell_ink(v2_pixels, 2, 0x11, 0x33, 0x55);
    const unsigned continuation_ink =
        glyph_cell_ink(v2_pixels, 3, 0x11, 0x33, 0x55);

    fprintf(
        stderr,
        "glyph v2 ink: base=%u combined=%u wide_lead=%u continuation=%u\n",
        base_ink,
        combined_ink,
        wide_lead_ink,
        continuation_ink
    );

    /* Per-cell backgrounds, including the reserved continuation cell. */
    const unsigned char *corner0 =
        v2_pixels + ((size_t)0 * GLYPH_FB_WIDTH + 0) * 4;
    const unsigned char *corner3 =
        v2_pixels + ((size_t)0 * GLYPH_FB_WIDTH + (GLYPH_FB_WIDTH - 1)) * 4;
    int failed = 0;
    if (check(base_ink > 0, "narrow glyph produced no ink")) failed = 1;
    if (check(
            combined_ink != base_ink,
            "combining mark did not change the rendered cell"
        )) {
        failed = 1;
    }
    if (check(wide_lead_ink > 0, "wide glyph lead cell produced no ink")) failed = 1;
    if (check(
            continuation_ink > 0,
            "wide glyph did not extend into the column it reserves"
        )) {
        failed = 1;
    }
    if (check(
            corner0[0] == 0xCC && corner0[1] == 0x22 && corner0[2] == 0x11,
            "per-cell background was not painted for the first cell"
        )) {
        failed = 1;
    }
    if (check(
            corner3[0] == 0x11 && corner3[1] == 0x33 && corner3[2] == 0x55,
            "continuation cell background was not painted"
        )) {
        failed = 1;
    }

    /* v1 regression: the legacy path still renders after a v2 snapshot. */
    winghostty_terminal_snapshot v1;
    winghostty_terminal_snapshot_init(&v1);
    v1.columns = GLYPH_COLUMNS;
    v1.rows = 1;
    v1.cells = cells;
    v1.cell_count = GLYPH_COLUMNS;
    v1.generation = 3;
    if (!failed &&
        winghostty_surface_set_terminal_snapshot(surface, &v1) != WINGHOSTTY_OK) {
        fail("v1 snapshot install after v2 failed");
        failed = 1;
    }

    SetEvent(session.next_frame);
    WaitForSingleObject(session.frame_ready, INFINITE);
    WaitForSingleObject(render_thread_handle, INFINITE);
    CloseHandle(render_thread_handle);
    CloseHandle(session.frame_ready);
    CloseHandle(session.next_frame);

    if (!failed) {
        if (check(
                glyph_session_ok(&session, 1) &&
                    session.clear_current_result == WINGHOSTTY_OK,
                "v1 glyph render failed"
            )) {
            failed = 1;
        }
    }

    if (!failed) {
        const unsigned char *v1_pixels = session.frames[1];
        const unsigned v1_base_ink =
            glyph_cell_ink(v1_pixels, 0, 0xCC, 0x22, 0x11);
        const unsigned v1_continuation_ink =
            glyph_cell_ink(v1_pixels, 3, 0x11, 0x33, 0x55);
        fprintf(
            stderr,
            "glyph v1 ink: base=%u continuation=%u\n",
            v1_base_ink,
            v1_continuation_ink
        );
        if (check(
                v1_base_ink > 0,
                "v1 path stopped rendering cell ink after a v2 snapshot"
            ) ||
            check(
                v1_continuation_ink == 0,
                "v1 path rendered ink for an empty cell"
            ) ||
            check(
                glyph_cell_diff(v2_pixels, v1_pixels, 0) > 0,
                "v2 glyph raster was indistinguishable from the v1 fallback"
            )) {
            failed = 1;
        }
    }

    if (failed) {
        winghostty_surface_destroy(surface);
        winghostty_host_deinitialize(host);
        return 1;
    }

    if (winghostty_surface_destroy(surface) != WINGHOSTTY_OK ||
        winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
        return fail("glyph render teardown failed");
    }
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

static int run_persistent_switch_teardown_contract(HWND parent) {
    winghostty_host *host = NULL;
    winghostty_surface *first = NULL;
    winghostty_surface *second = NULL;
    winghostty_surface_options options;
    persistent_switch_call call = {0};
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;

    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
        winghostty_host_create_surface(
            host,
            parent,
            &options,
            &first
        ) != WINGHOSTTY_OK ||
        winghostty_host_create_surface(
            host,
            parent,
            &options,
            &second
        ) != WINGHOSTTY_OK ||
        first == NULL ||
        second == NULL) {
        if (host != NULL) winghostty_host_deinitialize(host);
        return fail("persistent-switch setup failed");
    }

    call.first = first;
    call.second = second;
    HANDLE thread = CreateThread(
        NULL,
        0,
        persistent_switch_thread,
        &call,
        0,
        NULL
    );
    if (thread == NULL) {
        winghostty_surface_destroy(second);
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(host);
        return fail("persistent-switch worker creation failed");
    }

    for (int i = 0; i < 5000 && call.ready_after_clear == 0; ++i) {
        Sleep(1);
    }
    if (check(
            call.ready_after_clear != 0,
            "persistent-switch worker did not clear second context"
        )) {
        InterlockedExchange(&call.continue_after_destroy, 1);
        WaitForSingleObject(thread, 10000);
        CloseHandle(thread);
        winghostty_surface_destroy(second);
        winghostty_surface_destroy(first);
        winghostty_host_deinitialize(host);
        return 1;
    }

    HWND first_hwnd = winghostty_surface_get_hwnd(first);
    if (check(
            winghostty_surface_destroy(first) == WINGHOSTTY_OK,
            "persistent first-surface teardown waited after switch"
        ) ||
        check(!IsWindow(first_hwnd), "persistent first window survived teardown")) {
        InterlockedExchange(&call.continue_after_destroy, 1);
        WaitForSingleObject(thread, 10000);
        CloseHandle(thread);
        winghostty_surface_destroy(second);
        winghostty_host_deinitialize(host);
        return 1;
    }

    InterlockedExchange(&call.continue_after_destroy, 1);
    const int worker_finished =
        WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0;
    CloseHandle(thread);
    if (check(worker_finished, "persistent-switch worker did not finish") ||
        check(
            call.first_make_current_result == WINGHOSTTY_OK &&
                call.second_make_current_result == WINGHOSTTY_OK &&
                call.second_clear_current_result == WINGHOSTTY_OK &&
                call.second_make_current_again_result == WINGHOSTTY_OK &&
                call.second_clear_current_again_result == WINGHOSTTY_OK,
            "persistent-switch context operations failed"
        ) ||
        check(
            call.current_after_second_make &&
                call.current_after_second_clear &&
                call.current_after_second_make_again &&
                call.current_after_second_clear_again,
            "persistent-switch WGL binding was not restored")) {
        winghostty_surface_destroy(second);
        winghostty_host_deinitialize(host);
        return 1;
    }

    if (winghostty_surface_destroy(second) != WINGHOSTTY_OK ||
        winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
        return fail("persistent-switch final teardown failed");
    }
    return 0;
}

static int run_handle_reuse_contract(HWND parent) {
    winghostty_host *old_host = NULL;
    winghostty_surface *old_surface = NULL;
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;

    if (winghostty_host_initialize(&old_host) != WINGHOSTTY_OK ||
        winghostty_host_create_surface(
            old_host,
            parent,
            &options,
            &old_surface
        ) != WINGHOSTTY_OK ||
        old_surface == NULL) {
        if (old_host) winghostty_host_deinitialize(old_host);
        return fail("stale-handle setup failed");
    }
    if (winghostty_surface_destroy(old_surface) != WINGHOSTTY_OK ||
        winghostty_host_deinitialize(old_host) != WINGHOSTTY_OK) {
        return fail("stale-handle source teardown failed");
    }

    winghostty_host *new_host = NULL;
    winghostty_surface *new_surface = NULL;
    if (winghostty_host_initialize(&new_host) != WINGHOSTTY_OK ||
        winghostty_host_create_surface(
            new_host,
            parent,
            &options,
            &new_surface
        ) != WINGHOSTTY_OK ||
        new_surface == NULL) {
        if (new_host) winghostty_host_deinitialize(new_host);
        return fail("stale-handle replacement setup failed");
    }
    if (check(old_host != new_host, "host handle ID was reused") ||
        check(old_surface != new_surface, "surface handle ID was reused") ||
        check_stale_host(old_host, parent) != 0 ||
        check_stale_surface(old_surface) != 0 ||
        check(
            IsWindow(winghostty_surface_get_hwnd(new_surface)),
            "stale handle affected replacement surface"
        )) {
        winghostty_surface_destroy(new_surface);
        winghostty_host_deinitialize(new_host);
        return 1;
    }

    if (winghostty_surface_destroy(new_surface) != WINGHOSTTY_OK ||
        winghostty_host_deinitialize(new_host) != WINGHOSTTY_OK) {
        return fail("stale-handle replacement teardown failed");
    }
    return 0;
}

static int run_reentrant_parent_deinitialize_contract(test_state *state) {
    winghostty_host *host = NULL;
    winghostty_surface *surface = NULL;
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;

    if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
        winghostty_host_create_surface(
            host,
            state->parent,
            &options,
            &surface
        ) != WINGHOSTTY_OK ||
        surface == NULL) {
        if (host != NULL) winghostty_host_deinitialize(host);
        return fail("reentrant teardown setup failed");
    }

    state->host = host;
    state->surface = surface;
    state->deinit_on_child_destroy = 1;
    state->parent_destroy_notifications = 0;
    state->parent_deinit_result = WINGHOSTTY_INVALID_ARGUMENT;
    HWND child = winghostty_surface_get_hwnd(surface);

    if (check(
            winghostty_surface_destroy(surface) == WINGHOSTTY_OK,
            "parent-proc reentrant surface destroy failed"
        ) ||
        check(
            state->parent_destroy_notifications > 0,
            "parent proc did not observe child destruction"
        ) ||
        check(
            state->parent_deinit_result == WINGHOSTTY_OK,
            "parent-proc host deinitialize did not complete"
        ) ||
        check(!IsWindow(child), "reentrant child window survived teardown") ||
        check_stale_surface(surface) != 0 ||
        check_stale_host(host, state->parent) != 0) {
        state->deinit_on_child_destroy = 0;
        state->host = NULL;
        state->surface = NULL;
        return 1;
    }

    state->deinit_on_child_destroy = 0;
    state->host = NULL;
    state->surface = NULL;
    return 0;
}

static int run_reentrant_parent_deinitialize_heap_contract(
    test_state *state
) {
    winghostty_surface_options options;
    winghostty_surface_options_init(&options);
    options.visible = 0;
    options.bounds.width = 80;
    options.bounds.height = 40;

    process_heap_usage before;
    process_heap_usage after;
    if (!read_process_heap_usage(&before)) {
        return fail("parent reentrant heap measurement failed before");
    }

    for (int cycle = 0; cycle < 1024; ++cycle) {
        winghostty_host *host = NULL;
        winghostty_surface *surface = NULL;
        if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
            winghostty_host_create_surface(
                host,
                state->parent,
                &options,
                &surface
            ) != WINGHOSTTY_OK ||
            surface == NULL) {
            if (host != NULL) winghostty_host_deinitialize(host);
            return fail("parent reentrant heap setup failed");
        }

        state->host = host;
        state->surface = surface;
        state->deinit_on_child_destroy = 1;
        state->parent_destroy_notifications = 0;
        state->parent_deinit_result = WINGHOSTTY_INVALID_ARGUMENT;
        HWND child = winghostty_surface_get_hwnd(surface);
        if (winghostty_surface_destroy(surface) != WINGHOSTTY_OK ||
            state->parent_destroy_notifications == 0 ||
            state->parent_deinit_result != WINGHOSTTY_OK ||
            IsWindow(child) ||
            check_stale_surface(surface) != 0 ||
            check_stale_host(host, state->parent) != 0) {
            state->deinit_on_child_destroy = 0;
            state->host = NULL;
            state->surface = NULL;
            return fail("parent reentrant heap teardown failed");
        }
        state->deinit_on_child_destroy = 0;
        state->host = NULL;
        state->surface = NULL;
    }

    if (!read_process_heap_usage(&after)) {
        return fail("parent reentrant heap measurement failed after");
    }
    if (after.busy_blocks > before.busy_blocks + 64 ||
        after.busy_bytes > before.busy_bytes + (2 * 1024 * 1024)) {
        return fail("parent reentrant surfaces remained retained");
    }
    return 0;
}

static int run_numeric_handle_heap_contract(HWND parent) {
    (void)parent;
    /*
     * Keep this registry contract host-only. Surface cycles also exercise
     * WGL driver allocation, whose process-heap cache is intentionally
     * covered by the bounded 100-cycle renderer contract above.
     */
    for (int i = 0; i < 16; ++i) {
        winghostty_host *host = NULL;
        if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
            winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
            if (host != NULL) winghostty_host_deinitialize(host);
            return fail("numeric-handle heap warmup failed");
        }
    }

    process_heap_usage before;
    process_heap_usage after;
    if (!read_process_heap_usage(&before)) {
        return fail("process heap measurement failed before high-cycle test");
    }

    for (int i = 0; i < 1024; ++i) {
        winghostty_host *host = NULL;
        if (winghostty_host_initialize(&host) != WINGHOSTTY_OK ||
            winghostty_host_deinitialize(host) != WINGHOSTTY_OK) {
            if (host != NULL) winghostty_host_deinitialize(host);
            return fail("numeric-handle high-cycle teardown failed");
        }
    }

    if (!read_process_heap_usage(&after)) {
        return fail("process heap measurement failed after high-cycle test");
    }
    if (check(
            after.busy_blocks <= before.busy_blocks + 16 &&
                after.busy_bytes <= before.busy_bytes + (2 * 1024 * 1024),
            "numeric handle registry/process heap grew across high-cycle teardown"
        )) {
        return 1;
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

    stress.host = host;
    stress.surface = surface;
    stress.parent = parent;
    stress.options = options;
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
        if (check_stale_surface(surface) != 0) return 1;
        if (check(
                winghostty_host_deinitialize(host) == WINGHOSTTY_OK,
                "surface-race host teardown failed"
            )) {
            return 1;
        }
    } else if (check_stale_surface(surface) != 0) {
        return 1;
    }
    return check_stale_host(host, parent);
}

int main(void) {
    if (FAILED(CoInitializeEx(NULL, COINIT_APARTMENTTHREADED))) {
        return fail("COM initialization failed");
    }
    test_state state = {
        .ui_thread = GetCurrentThreadId(),
    };
    state.parent = create_parent();
    if (!state.parent) return fail("parent window creation failed");
    SetWindowLongPtrW(
        state.parent,
        GWLP_USERDATA,
        (LONG_PTR)&state
    );
    ShowWindow(state.parent, SW_SHOW);
    UpdateWindow(state.parent);

    if (run_renderer_contract(&state) != 0) {
        if (state.host) winghostty_host_deinitialize(state.host);
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_vt_render_state_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_glyph_render_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_persistent_teardown_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_persistent_switch_teardown_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_handle_reuse_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_reentrant_parent_deinitialize_contract(&state) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_reentrant_parent_deinitialize_heap_contract(&state) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_numeric_handle_heap_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_clear_admission_stress(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_uia_selection_token_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_reentrant_destroy_heap_contract(state.parent) != 0) {
        DestroyWindow(state.parent);
        return 1;
    }
    if (run_deferred_host_ui_thread_contract(&state) != 0) {
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
    const DWORD user_budget = 4;
    const DWORD gdi_budget = 4;
    DWORD user_peak = user_before;
    DWORD gdi_peak = gdi_before;

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
        drain_messages();
        const DWORD user_now =
            GetGuiResources(GetCurrentProcess(), GR_USEROBJECTS);
        const DWORD gdi_now =
            GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
        if (user_now > user_peak) user_peak = user_now;
        if (gdi_now > gdi_peak) gdi_peak = gdi_now;
        if (user_now > user_before + user_budget ||
            gdi_now > gdi_before + gdi_budget) {
            winghostty_host_deinitialize(cycle_host);
            DestroyWindow(state.parent);
            return fail("per-cycle GUI handle growth exceeded bounded budget");
        }
    }
    if (winghostty_host_deinitialize(cycle_host) != WINGHOSTTY_OK) {
        DestroyWindow(state.parent);
        return fail("cycle host teardown failed");
    }
    if (!wait_for_host_finalization(cycle_host)) {
        DestroyWindow(state.parent);
        return fail("deferred cycle host finalization did not complete");
    }

    const DWORD user_after =
        GetGuiResources(GetCurrentProcess(), GR_USEROBJECTS);
    const DWORD gdi_after =
        GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS);
    if (check(
            user_after <= user_before + user_budget,
            "USER handle growth exceeded bounded budget"
        ) ||
        check(
            gdi_after <= gdi_before + gdi_budget,
            "GDI handle growth exceeded bounded budget"
        )) {
        DestroyWindow(state.parent);
        return 1;
    }

    DestroyWindow(state.parent);
    CoUninitialize();
    printf(
        "Win32 host renderer contract passed: child HWND/HDC/HGLRC, affinity, "
        "presentation, stable handles, teardown, 100 cycles, bounded GUI "
        "growth USER=%lu/%lu GDI=%lu/%lu.\n",
        user_peak - user_before,
        user_budget,
        gdi_peak - gdi_before,
        gdi_budget
    );
    return 0;
}
