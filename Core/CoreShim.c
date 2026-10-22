#include "CoreShim.h"

#include <dispatch/dispatch.h>
#include <os/log.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static os_log_t duo_core_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.kurast.duomulator", "core"); });
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

// MARK: - GET_GAME_INFO_EXT

/// Layout-identical to libretro's `struct retro_game_info_ext` (libretro.h, API v1).
typedef struct {
    const char *full_path;
    const char *archive_path;
    const char *archive_file;
    const char *dir;
    const char *name;
    const char *ext;
    const char *meta;
    const void *data;
    size_t size;
    bool file_in_archive;
    bool persistent_data;
} duo_game_info_ext;

static duo_game_info_ext game_info_ext;
static bool game_info_ext_valid;
/// Owned copies of the strings above.
static char *ext_strings[6];

static char *duo_strdup(const char *s) { return s ? strdup(s) : NULL; }

void duo_clear_game_info_ext(void) {
    for (size_t i = 0; i < sizeof(ext_strings) / sizeof(ext_strings[0]); i++) {
        free(ext_strings[i]);
        ext_strings[i] = NULL;
    }
    memset(&game_info_ext, 0, sizeof(game_info_ext));
    game_info_ext_valid = false;
}

void duo_set_game_info_ext(const char *full_path, const char *archive_path,
                           const char *archive_file, const void *data, size_t size) {
    duo_clear_game_info_ext();

    // dir / name / ext split of full_path, e.g. "/a/b/Game.nes" -> "/a/b", "Game", "nes".
    const char *slash = strrchr(full_path, '/');
    const char *file = slash ? slash + 1 : full_path;
    const char *dot = strrchr(file, '.');
    size_t dir_len = slash ? (size_t)(slash - full_path) : 0;
    size_t name_len = dot ? (size_t)(dot - file) : strlen(file);

    ext_strings[0] = duo_strdup(full_path);
    ext_strings[1] = duo_strdup(archive_path);
    ext_strings[2] = duo_strdup(archive_file);
    ext_strings[3] = strndup(full_path, dir_len);
    ext_strings[4] = strndup(file, name_len);
    ext_strings[5] = strdup(dot ? dot + 1 : "");

    game_info_ext.full_path = ext_strings[0];
    game_info_ext.archive_path = ext_strings[1];
    game_info_ext.archive_file = ext_strings[2];
    game_info_ext.dir = ext_strings[3];
    game_info_ext.name = ext_strings[4];
    game_info_ext.ext = ext_strings[5];
    game_info_ext.data = data;
    game_info_ext.size = size;
    game_info_ext.file_in_archive = archive_path != NULL;
    // The buffer is freed after loading, so cores must take a copy.
    game_info_ext.persistent_data = false;
    game_info_ext_valid = true;
}

bool duo_get_game_info_ext(void *data) {
    if (!data || !game_info_ext_valid) return false;
    *(const duo_game_info_ext **)data = &game_info_ext;
    return true;
}
