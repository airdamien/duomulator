#ifndef DUOMULATOR_CORE_SHIM_H
#define DUOMULATOR_CORE_SHIM_H

#include <stdbool.h>
#include "libretro.h"

/// libretro's log callback is a C variadic function, which Swift can neither implement nor
/// reference. This fills a `struct retro_log_callback` (the payload of
/// RETRO_ENVIRONMENT_GET_LOG_INTERFACE) with a C printf-style logger that forwards to os_log
/// (subsystem io.kurast.duomulator, category "core"). Always returns true.
bool duo_install_log_interface(void *retro_log_callback_data);

/// RETRO_ENVIRONMENT_GET_GAME_INFO_EXT (66). The vendored snes9x libretro.h predates it, so it
/// is defined here. FCEUmm only uses in-memory ROM data offered this way; without it, it
/// re-reads `retro_game_info.path` from disk, which fails for ROMs extracted from a zip.
#define DUO_ENVIRONMENT_GET_GAME_INFO_EXT 66

/// Describes the game being loaded for GET_GAME_INFO_EXT. Strings are copied; `data` is not
/// and must stay valid until `duo_clear_game_info_ext`. `archive_path`/`archive_file` are NULL
/// unless the ROM came out of an archive. Call before retro_load_game, clear right after.
void duo_set_game_info_ext(const char *full_path, const char *archive_path,
                           const char *archive_file, const void *data, size_t size);
void duo_clear_game_info_ext(void);

/// Answers GET_GAME_INFO_EXT: stores a pointer to the current description (or fails when no
/// game is being loaded).
bool duo_get_game_info_ext(void *data);

#endif
