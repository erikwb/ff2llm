//! FF4 sound host — ports InitSound / PlaySong / PlayGameSfx from
//! everything8215/ff4 sound/sound.asm onto blargg snes_spc.
#include "host.h"

#include "snes_spc/spc.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Headerless LoROM file offsets (bank $04 sound region). */
#define OFF_SPC_DATA 0x20683u /* $048683 — IPL upload blocks */
#define OFF_SOUND_DATA 0x24000u /* $04C000 — SoundData */

/* Standard SNES APU IPL ROM (64 bytes). */
static const unsigned char ipl_rom[64] = {
    0xCD, 0xEF, 0xBD, 0xE8, 0x00, 0xC6, 0x1D, 0xD0, 0xFC, 0x8F, 0xAA, 0xF4, 0x8F, 0xBB, 0xF5, 0x78,
    0xCC, 0xF4, 0xD0, 0xFB, 0x2F, 0x19, 0xEB, 0xF4, 0xD0, 0xFC, 0x7E, 0xF4, 0xD0, 0x0B, 0xE4, 0xF5,
    0xCB, 0xF4, 0xD7, 0x00, 0xFC, 0xD0, 0xF3, 0xAB, 0x01, 0x10, 0xEF, 0x7E, 0xF4, 0x10, 0xEB, 0xBA,
    0xF6, 0xDA, 0x00, 0xBA, 0xF4, 0xC4, 0xF4, 0xDD, 0x5D, 0xD0, 0xDB, 0x1F, 0x00, 0x00, 0xC0, 0xFF,
};

struct Ff4Audio {
    SNES_SPC* spc;
    SPC_Filter* filter;
    const uint8_t* rom;
    size_t rom_len;
    uint8_t current_song; /* $1e05 */
    uint8_t xfer; /* $1e08 transfer counter */
    /* Sample tracking (mirrors $1e40+) */
    uint16_t sample_id[16]; /* $1e40 — loaded sample ids (0 = empty) */
    uint16_t sample_spc_off[16]; /* $1e60 — SPC RAM offset of sample */
    uint16_t sample_size[16]; /* $1e80 — size in bytes */
    int booted;
    int16_t* mix_tmp;
    int mix_tmp_cap;
};

/* ---- APU port helpers: run the SPC while waiting for handshake ---- */

static void apu_write(Ff4Audio* a, int port, int data) {
    spc_write_port(a->spc, 0, port, data & 0xFF);
}

static int apu_read(Ff4Audio* a, int port) {
    return spc_read_port(a->spc, 0, port) & 0xFF;
}

/** Run APU for `pairs` stereo sample pairs, discarding output. */
static void apu_run_pairs(Ff4Audio* a, int pairs) {
    if (pairs <= 0) return;
    if (pairs > a->mix_tmp_cap / 2) {
        int need = pairs * 2;
        int16_t* p = (int16_t*)realloc(a->mix_tmp, (size_t)need * sizeof(int16_t));
        if (!p) return;
        a->mix_tmp = p;
        a->mix_tmp_cap = need;
    }
    spc_play(a->spc, pairs * 2, a->mix_tmp);
}

static int apu_wait_port0(Ff4Audio* a, int expect, int max_iters) {
    int i;
    for (i = 0; i < max_iters; i++) {
        if (apu_read(a, 0) == (expect & 0xFF)) return 1;
        apu_run_pairs(a, 8); /* ~0.25 ms */
    }
    return 0;
}

static int apu_wait_port01(Ff4Audio* a, int lo, int hi, int max_iters) {
    int i;
    for (i = 0; i < max_iters; i++) {
        if (apu_read(a, 0) == (lo & 0xFF) && apu_read(a, 1) == (hi & 0xFF)) return 1;
        apu_run_pairs(a, 8);
    }
    return 0;
}

/* ---- ROM accessors ---- */

static int rom_ok(const Ff4Audio* a, uint32_t off, uint32_t n) {
    return a->rom && (size_t)off + n <= a->rom_len;
}

static uint8_t rb(const Ff4Audio* a, uint32_t off) {
    if (!rom_ok(a, off, 1)) return 0;
    return a->rom[off];
}

static uint16_t rw(const Ff4Audio* a, uint32_t off) {
    if (!rom_ok(a, off, 2)) return 0;
    return (uint16_t)(a->rom[off] | (a->rom[off + 1] << 8));
}

static uint32_t rfar(const Ff4Audio* a, uint32_t off) {
    if (!rom_ok(a, off, 3)) return 0;
    return (uint32_t)a->rom[off] | ((uint32_t)a->rom[off + 1] << 8) | ((uint32_t)a->rom[off + 2] << 16);
}

/** SoundData-relative far pointer → absolute file offset. */
static uint32_t sd_abs(uint32_t rel) {
    return OFF_SOUND_DATA + rel;
}

static uint32_t table_rel(const Ff4Audio* a, int which) {
    /* 0=SongScriptPtrs 1=BRRSamplePtrs 2=SongSamples 3=SampleLoop 4=SampleFreq */
    return rfar(a, OFF_SOUND_DATA + (uint32_t)which * 3);
}

/* ---- IPL boot (InitSound) ---- */

static int boot_spc(Ff4Audio* a) {
    uint32_t pos = OFF_SPC_DATA;
    uint8_t port0;

    spc_init_rom(a->spc, ipl_rom);
    spc_reset(a->spc);

    /* Wait for IPL ready $BBAA on ports 0-1 */
    if (!apu_wait_port01(a, 0xAA, 0xBB, 200000)) return -1;

    /* First block: InitSound writes length/dest then $CC handshake */
    {
        uint16_t len = rw(a, pos);
        uint16_t dest = rw(a, pos + 2);
        uint32_t data = pos + 4;
        uint16_t i;

        apu_write(a, 2, dest & 0xFF);
        apu_write(a, 3, (dest >> 8) & 0xFF);
        apu_write(a, 1, 0x01);
        apu_write(a, 0, 0xCC);
        if (!apu_wait_port0(a, 0xCC, 200000)) return -2;

        port0 = 0;
        for (i = 0; i < len; i++) {
            apu_write(a, 1, rb(a, data + i));
            apu_write(a, 0, port0);
            if (!apu_wait_port0(a, port0, 50000)) return -3;
            port0++;
        }
        pos = data + len;
        /* InitSound: three INC $08 after each block (sound.asm @8067 tail) */
        port0 = (uint8_t)(port0 + 3);
    }

    /* Remaining blocks until length 0 */
    for (;;) {
        uint16_t len = rw(a, pos);
        uint16_t dest = rw(a, pos + 2);
        uint32_t data = pos + 4;
        uint16_t i;

        if (len == 0) {
            /* Entry point: write dest, port1=0, signal with port0 */
            apu_write(a, 2, dest & 0xFF);
            apu_write(a, 3, (dest >> 8) & 0xFF);
            apu_write(a, 1, 0x00);
            apu_write(a, 0, port0);
            if (!apu_wait_port0(a, port0, 200000)) return -4;
            apu_write(a, 0, 0);
            break;
        }

        apu_write(a, 2, dest & 0xFF);
        apu_write(a, 3, (dest >> 8) & 0xFF);
        apu_write(a, 1, 0x01);
        apu_write(a, 0, port0);
        if (!apu_wait_port0(a, port0, 200000)) return -5;
        port0 = 0;

        for (i = 0; i < len; i++) {
            apu_write(a, 1, rb(a, data + i));
            apu_write(a, 0, port0);
            if (!apu_wait_port0(a, port0, 50000)) return -6;
            port0++;
        }
        pos = data + len;
        port0 = (uint8_t)(port0 + 3);
    }

    /* Let the SPC program start */
    apu_run_pairs(a, 1024);
    a->booted = 1;
    a->current_song = 0xFF;
    memset(a->sample_id, 0, sizeof(a->sample_id));
    memset(a->sample_spc_off, 0, sizeof(a->sample_spc_off));
    memset(a->sample_size, 0, sizeof(a->sample_size));
    a->sample_spc_off[0] = 0x3000; /* InitSound stx $60 with #$3000 — first sample slot base */
    return 0;
}

/* ---- PlaySong — interrupt $01 protocol (ff4-spc.asm @1432 / sound.asm @816f) ---- */

/**
 * Wait until SPC ACKs by writing `expect` to F4 (CPU reads APUIO0).
 * SNES APU ports are one-way each direction — CPU write ≠ CPU read.
 */
static int xfer_wait_ack(Ff4Audio* a, uint8_t expect) {
    int guard = 50000;
    while (apu_read(a, 0) != expect && --guard)
        apu_run_pairs(a, 8);
    return guard > 0;
}

/** Bump transfer counter; skip 0 (0 ends a transfer phase on the SPC). */
static uint8_t xfer_next_skip0(uint8_t port0) {
    port0++;
    if (port0 == 0) port0 = 1;
    return port0;
}

/**
 * PlaySong host (sound.asm @816f) for a cold load (no samples cached):
 *
 *  1. Script bytes → $2000, F6 + F4 counter (starts as IRQ $01). F4=0 ends.
 *  2. F5=$11, F4=0 → full BRR upload at $3000, 3 bytes/step on F5/F6/F7.
 *  3. DIR pairs at $1F00 (start, loop) for each song sample until first 0.
 *     First pair is written with F4=0 — that also ends the BRR phase.
 *  4. Freq mults at $FF40 (1 byte on F6) until first 0 sample.
 *     First mult uses F4=0 — that also ends the pointer phase.
 *  5. Final F4 handshake then F4=0; SPC wires channel script ptrs and runs.
 */
static void play_song_internal(Ff4Audio* a, uint8_t song_id) {
    uint32_t ssp_rel, song_ptr_rel, script_off;
    uint16_t script_len;
    uint32_t i;
    uint8_t port0;
    uint16_t song_samples[16];
    uint16_t spc_off[24];
    uint16_t spc_cursor;
    uint32_t brr_tbl, loop_tbl, freq_tbl;
    int n_slots;

    if (!a->booted) return;
    if (song_id == a->current_song) return;

    ssp_rel = table_rel(a, 0);
    song_ptr_rel = rfar(a, sd_abs(ssp_rel) + (uint32_t)song_id * 3);
    script_off = sd_abs(song_ptr_rel);
    script_len = rw(a, script_off);
    if (script_len == 0 || script_len > 0x8000) return;

    a->current_song = song_id;

    /* --- 1. Song script → SPC $2000 --- */
    {
        uint32_t data = script_off + 2;
        uint16_t left = script_len;
        port0 = 0x01; /* also the interrupt id that enters PlaySong on SPC */
        while (left--) {
            apu_write(a, 2, rb(a, data++)); /* F6 */
            apu_write(a, 0, port0);         /* F4 */
            if (!xfer_wait_ack(a, port0)) return;
            port0 = xfer_next_skip0(port0);
        }
    }

    /* Song sample list: 16 × u16 ids, packed then trailing zeros */
    {
        uint32_t ss_rel = table_rel(a, 2);
        uint32_t base = sd_abs(ss_rel) + (uint32_t)song_id * 32;
        for (i = 0; i < 16; i++)
            song_samples[i] = rw(a, base + i * 2);
    }

    brr_tbl = sd_abs(table_rel(a, 1));
    loop_tbl = sd_abs(table_rel(a, 3));
    freq_tbl = sd_abs(table_rel(a, 4));

    memset(spc_off, 0, sizeof(spc_off));
    memset(a->sample_id, 0, sizeof(a->sample_id));
    memset(a->sample_spc_off, 0, sizeof(a->sample_spc_off));
    memset(a->sample_size, 0, sizeof(a->sample_size));

    /* --- 2. End script + choose BRR mode ($11 = upload all from $3000) --- */
    apu_write(a, 1, 0x11); /* F5 */
    apu_write(a, 0, 0);    /* F4=0 ends script phase */
    if (!xfer_wait_ack(a, 0)) return;
    port0 = 1; /* first BRR triple wakes SPC from post-$11 wait */

    /* Transfer BRR in song-list order (matches sound.asm @83c8) */
    spc_cursor = 0x3000;
    for (i = 0; i < 16; i++) {
        uint16_t sid = song_samples[i];
        uint32_t pref, sample_data, payload;
        uint16_t slen, left;

        if (sid == 0) break;
        if (sid >= 24) continue;
        if (spc_off[sid]) {
            /* already uploaded this id earlier in the list */
            continue;
        }

        pref = rfar(a, brr_tbl + (uint32_t)sid * 3);
        if (pref == 0) continue;
        sample_data = sd_abs(pref);
        slen = rw(a, sample_data);
        if (slen < 3 || slen > 0xA000) continue;

        payload = sample_data + 2;
        spc_off[sid] = spc_cursor;
        a->sample_id[i] = sid;
        a->sample_spc_off[i] = spc_cursor;
        a->sample_size[i] = slen;

        left = slen;
        while (left >= 3) {
            apu_write(a, 1, rb(a, payload));
            apu_write(a, 2, rb(a, payload + 1));
            apu_write(a, 3, rb(a, payload + 2));
            apu_write(a, 0, port0);
            if (!xfer_wait_ack(a, port0)) return;
            port0 = xfer_next_skip0(port0);
            payload += 3;
            left = (uint16_t)(left - 3);
        }
        /* Lengths in ROM are always multiples of 3 (BRR frames). */
        spc_cursor = (uint16_t)(spc_cursor + slen);
    }
    a->sample_spc_off[0] = spc_cursor; /* next free (mirrors $1e60 chain) */

    /*
     * --- 3. Sample DIR pointers ($1F00) ---
     * Do NOT write a bare F4=0 first: the first start-address write with
     * F4=0 is what ends the BRR phase on the SPC (ff4-spc @14FA→14FC).
     */
    port0 = 0;
    n_slots = 0;
    for (i = 0; i < 16; i++) {
        uint16_t sid = song_samples[i];
        uint16_t start = 0, loop_addr = 0;
        uint16_t loop_rel;

        if (sid == 0) break;
        n_slots++;
        if (sid < 24 && spc_off[sid]) {
            loop_rel = rw(a, loop_tbl + (uint32_t)sid * 4 + 2);
            start = spc_off[sid];
            loop_addr = (uint16_t)(start + loop_rel);
        }
        /* start */
        apu_write(a, 2, start & 0xFF);
        apu_write(a, 3, (start >> 8) & 0xFF);
        apu_write(a, 0, port0);
        if (!xfer_wait_ack(a, port0)) return;
        port0++; /* pointer phase does not skip 0 mid-stream (host never wraps) */
        /* loop */
        apu_write(a, 2, loop_addr & 0xFF);
        apu_write(a, 3, (loop_addr >> 8) & 0xFF);
        apu_write(a, 0, port0);
        if (!xfer_wait_ack(a, port0)) return;
        port0++;
    }

    /*
     * --- 4. Frequency multipliers ($FF40) ---
     * First write with F4=0 ends the pointer phase (stz $08 @857c).
     */
    port0 = 0;
    for (i = 0; i < 16; i++) {
        uint16_t sid = song_samples[i];
        uint8_t mult;
        if (sid == 0) break;
        mult = (sid < 24) ? rb(a, freq_tbl + sid) : 0;
        apu_write(a, 2, mult);
        apu_write(a, 3, 0);
        apu_write(a, 0, port0);
        if (!xfer_wait_ack(a, port0)) return;
        port0++;
    }

    /* --- 5. Finish: one more counter then F4=0 (sound.asm @85d0) --- */
    apu_write(a, 0, port0);
    xfer_wait_ack(a, port0);
    apu_write(a, 0, 0);

    /* Give the player a moment to key on channels */
    apu_run_pairs(a, 4096);
    (void)n_slots;
}

/* ---- Public API ---- */

Ff4Audio* ff4_audio_create(const uint8_t* rom, size_t rom_len) {
    Ff4Audio* a;
    if (!rom || rom_len < 0x40000) return NULL;
    a = (Ff4Audio*)calloc(1, sizeof(Ff4Audio));
    if (!a) return NULL;
    a->spc = spc_new();
    a->filter = spc_filter_new();
    if (!a->spc || !a->filter) {
        ff4_audio_destroy(a);
        return NULL;
    }
    a->rom = rom;
    a->rom_len = rom_len;
    a->current_song = 0xFF;
    a->mix_tmp_cap = 4096;
    a->mix_tmp = (int16_t*)malloc((size_t)a->mix_tmp_cap * sizeof(int16_t));
    if (!a->mix_tmp) {
        ff4_audio_destroy(a);
        return NULL;
    }
    return a;
}

void ff4_audio_destroy(Ff4Audio* a) {
    if (!a) return;
    if (a->filter) spc_filter_delete(a->filter);
    if (a->spc) spc_delete(a->spc);
    free(a->mix_tmp);
    free(a);
}

int ff4_audio_init(Ff4Audio* a) {
    if (!a) return -1;
    return boot_spc(a);
}

void ff4_audio_play_song(Ff4Audio* a, uint8_t song_id) {
    if (!a || !a->booted) return;
    if (song_id >= 70) return;
    play_song_internal(a, song_id);
}

void ff4_audio_play_sfx(Ff4Audio* a, uint8_t sfx_id) {
    /* PlayGameSfx: ports = {cmd=$02, id, $80, $FF} then wait port0 */
    if (!a || !a->booted) return;
    apu_write(a, 3, 0xFF);
    apu_write(a, 2, 0x80);
    apu_write(a, 1, sfx_id);
    apu_write(a, 0, 0x02);
    apu_wait_port0(a, 0x02, 100000);
    apu_write(a, 0, 0);
    apu_run_pairs(a, 64);
}

void ff4_audio_play_system_sfx(Ff4Audio* a, uint8_t sfx_id) {
    /* PlaySystemSfx: write id to APUIO0, wait echo, clear (sound.asm @8608). */
    if (!a || !a->booted) return;
    if (sfx_id < 0x10 || sfx_id > 0x1E) return;
    apu_write(a, 0, sfx_id);
    apu_wait_port0(a, sfx_id, 100000);
    apu_write(a, 0, 0);
    apu_run_pairs(a, 64);
}

void ff4_audio_stop(Ff4Audio* a) {
    if (!a || !a->booted) return;
    /* Interrupt-style stop: write zeros */
    apu_write(a, 1, 0);
    apu_write(a, 2, 0);
    apu_write(a, 3, 0);
    apu_write(a, 0, 0);
    a->current_song = 0xFF;
}

void ff4_audio_render(Ff4Audio* a, int16_t* out, int count) {
    if (!a || !out || count < 2) return;
    if (!a->booted) {
        memset(out, 0, (size_t)count * sizeof(int16_t));
        return;
    }
    /* count is total samples (L+R), must be even */
    if (count & 1) count--;
    spc_play(a->spc, count, out);
    if (a->filter) spc_filter_run(a->filter, out, count);
}

uint8_t ff4_audio_current_song(const Ff4Audio* a) {
    return a ? a->current_song : 0xFF;
}

int ff4_audio_save_spc(Ff4Audio* a, void* out) {
    if (!a || !a->spc || !out) return -1;
    spc_init_header(out);
    spc_save_spc(a->spc, out);
    return 0;
}
