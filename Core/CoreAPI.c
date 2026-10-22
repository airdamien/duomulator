#include "CoreAPI.h"

// Entry points exported by the pre-linked core objects (see project.yml).
void snes9x_retro_set_environment(retro_environment_t);
void snes9x_retro_set_video_refresh(retro_video_refresh_t);
void snes9x_retro_set_audio_sample(retro_audio_sample_t);
void snes9x_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
void snes9x_retro_set_input_poll(retro_input_poll_t);
void snes9x_retro_set_input_state(retro_input_state_t);
void snes9x_retro_init(void);
void snes9x_retro_deinit(void);
unsigned snes9x_retro_api_version(void);
void snes9x_retro_get_system_info(struct retro_system_info *info);
void snes9x_retro_get_system_av_info(struct retro_system_av_info *info);
void snes9x_retro_set_controller_port_device(unsigned port, unsigned device);
void snes9x_retro_reset(void);
void snes9x_retro_run(void);
size_t snes9x_retro_serialize_size(void);
bool snes9x_retro_serialize(void *data, size_t size);
bool snes9x_retro_unserialize(const void *data, size_t size);
void snes9x_retro_cheat_reset(void);
void snes9x_retro_cheat_set(unsigned index, bool enabled, const char *code);
bool snes9x_retro_load_game(const struct retro_game_info *game);
bool snes9x_retro_load_game_special(unsigned game_type, const struct retro_game_info *info, size_t num_info);
void snes9x_retro_unload_game(void);
unsigned snes9x_retro_get_region(void);
void * snes9x_retro_get_memory_data(unsigned id);
size_t snes9x_retro_get_memory_size(unsigned id);

void fceumm_retro_set_environment(retro_environment_t);
void fceumm_retro_set_video_refresh(retro_video_refresh_t);
void fceumm_retro_set_audio_sample(retro_audio_sample_t);
void fceumm_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
void fceumm_retro_set_input_poll(retro_input_poll_t);
void fceumm_retro_set_input_state(retro_input_state_t);
void fceumm_retro_init(void);
void fceumm_retro_deinit(void);
unsigned fceumm_retro_api_version(void);
void fceumm_retro_get_system_info(struct retro_system_info *info);
void fceumm_retro_get_system_av_info(struct retro_system_av_info *info);
void fceumm_retro_set_controller_port_device(unsigned port, unsigned device);
void fceumm_retro_reset(void);
void fceumm_retro_run(void);
size_t fceumm_retro_serialize_size(void);
bool fceumm_retro_serialize(void *data, size_t size);
bool fceumm_retro_unserialize(const void *data, size_t size);
void fceumm_retro_cheat_reset(void);
void fceumm_retro_cheat_set(unsigned index, bool enabled, const char *code);
bool fceumm_retro_load_game(const struct retro_game_info *game);
bool fceumm_retro_load_game_special(unsigned game_type, const struct retro_game_info *info, size_t num_info);
void fceumm_retro_unload_game(void);
unsigned fceumm_retro_get_region(void);
void * fceumm_retro_get_memory_data(unsigned id);
size_t fceumm_retro_get_memory_size(unsigned id);

const DuoCoreAPI duo_core_snes9x = {
    .set_environment = snes9x_retro_set_environment,
    .set_video_refresh = snes9x_retro_set_video_refresh,
    .set_audio_sample = snes9x_retro_set_audio_sample,
    .set_audio_sample_batch = snes9x_retro_set_audio_sample_batch,
    .set_input_poll = snes9x_retro_set_input_poll,
    .set_input_state = snes9x_retro_set_input_state,
    .init = snes9x_retro_init,
    .deinit = snes9x_retro_deinit,
    .api_version = snes9x_retro_api_version,
    .get_system_info = snes9x_retro_get_system_info,
    .get_system_av_info = snes9x_retro_get_system_av_info,
    .set_controller_port_device = snes9x_retro_set_controller_port_device,
    .reset = snes9x_retro_reset,
    .run = snes9x_retro_run,
    .serialize_size = snes9x_retro_serialize_size,
    .serialize = snes9x_retro_serialize,
    .unserialize = snes9x_retro_unserialize,
    .cheat_reset = snes9x_retro_cheat_reset,
    .cheat_set = snes9x_retro_cheat_set,
    .load_game = snes9x_retro_load_game,
    .load_game_special = snes9x_retro_load_game_special,
    .unload_game = snes9x_retro_unload_game,
    .get_region = snes9x_retro_get_region,
    .get_memory_data = snes9x_retro_get_memory_data,
    .get_memory_size = snes9x_retro_get_memory_size,
};

const DuoCoreAPI duo_core_fceumm = {
    .set_environment = fceumm_retro_set_environment,
    .set_video_refresh = fceumm_retro_set_video_refresh,
    .set_audio_sample = fceumm_retro_set_audio_sample,
    .set_audio_sample_batch = fceumm_retro_set_audio_sample_batch,
    .set_input_poll = fceumm_retro_set_input_poll,
    .set_input_state = fceumm_retro_set_input_state,
    .init = fceumm_retro_init,
    .deinit = fceumm_retro_deinit,
    .api_version = fceumm_retro_api_version,
    .get_system_info = fceumm_retro_get_system_info,
    .get_system_av_info = fceumm_retro_get_system_av_info,
    .set_controller_port_device = fceumm_retro_set_controller_port_device,
    .reset = fceumm_retro_reset,
    .run = fceumm_retro_run,
    .serialize_size = fceumm_retro_serialize_size,
    .serialize = fceumm_retro_serialize,
    .unserialize = fceumm_retro_unserialize,
    .cheat_reset = fceumm_retro_cheat_reset,
    .cheat_set = fceumm_retro_cheat_set,
    .load_game = fceumm_retro_load_game,
    .load_game_special = fceumm_retro_load_game_special,
    .unload_game = fceumm_retro_unload_game,
    .get_region = fceumm_retro_get_region,
    .get_memory_data = fceumm_retro_get_memory_data,
    .get_memory_size = fceumm_retro_get_memory_size,
};
