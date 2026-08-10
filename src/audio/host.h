//! FF4 S-CPU sound host (InitSound / PlaySong / PlaySfx) driving blargg snes_spc.
//! Protocol and tables from everything8215/ff4 sound/sound.asm.
#ifndef FF4_AUDIO_HOST_H
#define FF4_AUDIO_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Ff4Audio Ff4Audio;

/** Create APU host. `rom` is headerless LoROM image (1 MiB). Does not take ownership. */
Ff4Audio* ff4_audio_create(const uint8_t* rom, size_t rom_len);

void ff4_audio_destroy(Ff4Audio* a);

/** Boot SPC program (InitSound). Returns 0 on success. */
int ff4_audio_init(Ff4Audio* a);

/** Play song id (0..69). Same as ExecSound cmd $01. */
void ff4_audio_play_song(Ff4Audio* a, uint8_t song_id);

/** Play game SFX id (door open $45, hit $2a, etc.). ExecSound cmd $02. */
void ff4_audio_play_sfx(Ff4Audio* a, uint8_t sfx_id);

/**
 * Play system SFX ($10..$1E). ExecSound: port0 = id (sound.asm PlaySystemSfx).
 * Battle/menu: $11 cursor (field), $12 error, $13 confirm/cancel, $14 cursor move.
 */
void ff4_audio_play_system_sfx(Ff4Audio* a, uint8_t sfx_id);

/** Stop / mute (optional). */
void ff4_audio_stop(Ff4Audio* a);

/**
 * Render `count` stereo samples (must be even: L,R pairs) into `out`.
 * Advances the emulated APU.
 */
void ff4_audio_render(Ff4Audio* a, int16_t* out, int count);

/** Currently playing song (0xFF if none). */
uint8_t ff4_audio_current_song(const Ff4Audio* a);

/**
 * Save current APU state as a .spc file (0x10200 bytes) into `out`.
 * Used to hand songs to libgme after ROM transfer.
 */
int ff4_audio_save_spc(Ff4Audio* a, void* out /* 0x10200 bytes */);

#ifdef __cplusplus
}
#endif

#endif
