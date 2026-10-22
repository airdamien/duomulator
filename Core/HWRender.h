#ifndef DUOMULATOR_HW_RENDER_H
#define DUOMULATOR_HW_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// libretro hardware rendering (RETRO_ENVIRONMENT_SET_HW_RENDER) for cores that draw with
/// OpenGL ES (Mupen64Plus' GLideN64). The core renders into an offscreen framebuffer on an
/// EAGL context owned here; each finished frame is read back into RGB565 so it flows through
/// the same FrameBuffer / Metal path as software-rendered cores.
///
/// Threading: the context is current on one thread at a time. Call `duo_hw_make_current`
/// on the thread about to run the core (load, emulation loop, tests).

/// RETRO_ENVIRONMENT_SET_HW_RENDER (14): accepts OpenGL ES 2/3 requests, fills in the
/// framebuffer and proc-address callbacks, and remembers the core's reset/destroy hooks.
bool duo_hw_set_render(void *retro_hw_render_callback_data);

/// Whether the loaded core asked for hardware rendering.
bool duo_hw_requested(void);

/// Creates the context and a `width` x `height` framebuffer, makes it current and calls the
/// core's context_reset. Call after retro_load_game when `duo_hw_requested()`.
bool duo_hw_start(int width, int height);

void duo_hw_make_current(void);
void duo_hw_release_current(void);

/// Copies the last frame (`width` x `height`, bottom-left origin) into `rgb565`, top row
/// first, `pitch` bytes per row. The context must be current.
bool duo_hw_read_frame(int width, int height, void *rgb565, size_t pitch);

/// Calls the core's context_destroy (if it was started) and tears everything down; also
/// forgets the request, ready for the next game.
void duo_hw_stop(void);

#endif
