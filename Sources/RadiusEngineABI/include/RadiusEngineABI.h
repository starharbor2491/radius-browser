// SPDX-License-Identifier: MPL-2.0
#ifndef RADIUS_ENGINE_ABI_H
#define RADIUS_ENGINE_ABI_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void RadiusBootstrapApplication(void);
typedef void (*radius_cef_event_callback)(void *context, int event, const char *json);
typedef int (*radius_cef_popup_callback)(void *context, void *child, const char *url);

enum { RADIUS_CEF_STATE = 1, RADIUS_CEF_FINISHED, RADIUS_CEF_ERROR,
       RADIUS_CEF_CLOSED, RADIUS_CEF_RESULT, RADIUS_CEF_NOTICE };
enum { RADIUS_CEF_LOAD = 1, RADIUS_CEF_RELOAD, RADIUS_CEF_STOP,
       RADIUS_CEF_BACK, RADIUS_CEF_FORWARD, RADIUS_CEF_ZOOM,
       RADIUS_CEF_FIND, RADIUS_CEF_POPUPS };

/// Versioned ABI loaded only from an explicitly installed engine package.
typedef struct radius_cef_api {
    uint32_t version;
    int (*initialize)(const char *package_path, const char *data_path, const char *main_bundle_path);
    const char *(*last_error)(void);
    void *(*create_page)(const char *profile_id, const char *private_window_id);
    void *(*native_view)(void *page);
    void (*set_callbacks)(void *page, void *context, radius_cef_event_callback event, radius_cef_popup_callback popup);
    void (*command)(void *page, int command, const char *text, double value);
    void (*devtools)(void *page, int request_id, const char *method, const char *parameters);
    void (*close_page)(void *page);
    int (*live_pages)(void);
    int (*shutdown)(void);
} radius_cef_api;
typedef const radius_cef_api *(*radius_cef_get_api_function)(void);

#ifdef __cplusplus
}
#endif
#endif
