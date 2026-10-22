#include "CoreShim.h"

#include <dispatch/dispatch.h>
#include <os/log.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static os_log_t duo_core_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.kurast.duomulator", "snes9x"); });
    return log;
}

static void duo_retro_log(enum retro_log_level level, const char *fmt, ...) {
    if (fmt == NULL) return;

    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    // Cores terminate their lines with '\n'; os_log adds its own record boundaries.
    size_t length = strlen(message);
    while (length > 0 && (message[length - 1] == '\n' || message[length - 1] == '\r')) {
        message[--length] = '\0';
    }

    os_log_type_t type;
    switch (level) {
        case RETRO_LOG_DEBUG: type = OS_LOG_TYPE_DEBUG; break;
        case RETRO_LOG_INFO:  type = OS_LOG_TYPE_INFO; break;
        case RETRO_LOG_WARN:  type = OS_LOG_TYPE_DEFAULT; break;
        default:              type = OS_LOG_TYPE_ERROR; break;
    }
    os_log_with_type(duo_core_log(), type, "%{public}s", message);
}

bool duo_install_log_interface(void *retro_log_callback_data) {
    struct retro_log_callback *callback = (struct retro_log_callback *)retro_log_callback_data;
    callback->log = duo_retro_log;
    return true;
}
