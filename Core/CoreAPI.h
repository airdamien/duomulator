#pragma once

#include "libretro.h"

/// The libretro API of one statically linked core. Each core is compiled with its retro_*
/// functions renamed (CoreBuild/<core>-prefix.h); Swift calls through these tables instead.
typedef struct DuoCoreAPI {
    void (* _Nonnull set_environment)(retro_environment_t);
    void (* _Nonnull set_video_refresh)(retro_video_refresh_t);
    void (* _Nonnull set_audio_sample)(retro_audio_sample_t);
    void (* _Nonnull set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (* _Nonnull set_input_poll)(retro_input_poll_t);
    void (* _Nonnull set_input_state)(retro_input_state_t);
    void (* _Nonnull init)(void);
    void (* _Nonnull deinit)(void);
    unsigned (* _Nonnull api_version)(void);
    void (* _Nonnull get_system_info)(struct retro_system_info *info);
    void (* _Nonnull get_system_av_info)(struct retro_system_av_info *info);
    void (* _Nonnull set_controller_port_device)(unsigned port, unsigned device);
    void (* _Nonnull reset)(void);
    void (* _Nonnull run)(void);
    size_t (* _Nonnull serialize_size)(void);
    bool (* _Nonnull serialize)(void *data, size_t size);
    bool (* _Nonnull unserialize)(const void *data, size_t size);
    void (* _Nonnull cheat_reset)(void);
    void (* _Nonnull cheat_set)(unsigned index, bool enabled, const char *code);
    bool (* _Nonnull load_game)(const struct retro_game_info *game);
    bool (* _Nonnull load_game_special)(unsigned game_type, const struct retro_game_info *info, size_t num_info);
    void (* _Nonnull unload_game)(void);
    unsigned (* _Nonnull get_region)(void);
    void * (* _Nonnull get_memory_data)(unsigned id);
    size_t (* _Nonnull get_memory_size)(unsigned id);
} DuoCoreAPI;

extern const DuoCoreAPI duo_core_snes9x;
extern const DuoCoreAPI duo_core_fceumm;
extern const DuoCoreAPI duo_core_melonds;
extern const DuoCoreAPI duo_core_picodrive;
extern const DuoCoreAPI duo_core_fbneo;
extern const DuoCoreAPI duo_core_pcsx;
extern const DuoCoreAPI duo_core_mupen64;
