#ifndef DUOMULATOR_CORE_SHIM_H
#define DUOMULATOR_CORE_SHIM_H

#include <stdbool.h>
#include "libretro.h"

/// libretro's log callback is a C variadic function, which Swift can neither implement nor
/// reference. This fills a `struct retro_log_callback` (the payload of
/// RETRO_ENVIRONMENT_GET_LOG_INTERFACE) with a C printf-style logger that forwards to os_log
/// (subsystem io.kurast.duomulator, category "snes9x"). Always returns true.
bool duo_install_log_interface(void *retro_log_callback_data);

#endif
