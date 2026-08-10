//! Kokoro TTS — long-lived PyTorch ROCm worker (scripts/kokoro_rocm_worker.py).
#define _POSIX_C_SOURCE 200809L
#include "tts_host.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* hexgrad/Kokoro-82M English voices (same order as sherpa kokoro-en-v0_19). */
static const char* k_voices[] = {
    "af",          /* 0 */
    "af_bella",    /* 1 */
    "af_nicole",   /* 2 */
    "af_sarah",    /* 3 */
    "af_sky",      /* 4 */
    "am_adam",     /* 5 */
    "am_michael",  /* 6 */
    "bf_emma",     /* 7 */
    "bf_isabella", /* 8 */
    "bm_george",   /* 9 */
    "bm_lewis",    /* 10 */
};
static const int k_num_voices = 11;

struct Ff4Tts {
    pid_t pid;
    int to_worker;   /* parent write → worker stdin */
    int from_worker; /* parent read  ← worker stdout */
    char info[192];
    int ok;
};

static int file_exists(const char* path) {
    return path && path[0] && access(path, F_OK) == 0;
}

static int read_line(int fd, char* buf, size_t cap, int timeout_ms) {
    size_t n = 0;
    while (n + 1 < cap) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int pr = poll(&pfd, 1, timeout_ms);
        if (pr < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (pr == 0) return -2; /* timeout */
        char c;
        ssize_t r = read(fd, &c, 1);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1; /* EOF */
        if (c == '\n') break;
        if (c != '\r') buf[n++] = c;
    }
    buf[n] = 0;
    return (int)n;
}

static int write_all(int fd, const char* s, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        s += (size_t)w;
        n -= (size_t)w;
    }
    return 0;
}

Ff4Tts* ff4_tts_create(const char* model_dir) {
    (void)model_dir;
    Ff4Tts* t = (Ff4Tts*)calloc(1, sizeof(Ff4Tts));
    if (!t) return NULL;
    t->to_worker = -1;
    t->from_worker = -1;
    t->pid = -1;
    snprintf(t->info, sizeof(t->info), "kokoro worker not started");

    const char* py = ".venv-tts/bin/python";
    const char* worker = "scripts/kokoro_rocm_worker.py";
    if (!file_exists(py)) {
        fprintf(stderr, "ff4_tts: missing %s — run scripts/setup_kokoro_rocm.sh\n", py);
        free(t);
        return NULL;
    }
    if (!file_exists(worker)) {
        fprintf(stderr, "ff4_tts: missing %s\n", worker);
        free(t);
        return NULL;
    }

    int in_pipe[2];  /* parent writes, child reads stdin */
    int out_pipe[2]; /* child writes stdout, parent reads */
    if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0) {
        fprintf(stderr, "ff4_tts: pipe failed: %s\n", strerror(errno));
        free(t);
        return NULL;
    }

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "ff4_tts: fork failed: %s\n", strerror(errno));
        close(in_pipe[0]);
        close(in_pipe[1]);
        close(out_pipe[0]);
        close(out_pipe[1]);
        free(t);
        return NULL;
    }

    if (pid == 0) {
        /* Child: stdin ← in_pipe[0], stdout → out_pipe[1] */
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        close(in_pipe[0]);
        close(in_pipe[1]);
        close(out_pipe[0]);
        close(out_pipe[1]);
        /* Leave stderr for MIOpen / load logs. */
        execl(py, py, "-u", worker, (char*)NULL);
        fprintf(stderr, "ff4_tts: exec failed: %s\n", strerror(errno));
        _exit(127);
    }

    /* Parent */
    close(in_pipe[0]);
    close(out_pipe[1]);
    t->pid = pid;
    t->to_worker = in_pipe[1];
    t->from_worker = out_pipe[0];

    /* Wait for READY (model load + warmup can take a while). */
    char line[512];
    for (;;) {
        int n = read_line(t->from_worker, line, sizeof(line), 180000);
        if (n < 0) {
            fprintf(stderr, "ff4_tts: worker died before READY (code %d)\n", n);
            ff4_tts_destroy(t);
            return NULL;
        }
        if (strncmp(line, "READY ", 6) == 0) {
            snprintf(t->info, sizeof(t->info), "kokoro-82M warm CPU (%s)", line + 6);
            t->ok = 1;
            fprintf(stderr, "ff4_tts: %s\n", t->info);
            return t;
        }
        /* Ignore stray lines (shouldn't happen on stdout). */
        fprintf(stderr, "ff4_tts: worker: %s\n", line);
    }
}

void ff4_tts_destroy(Ff4Tts* tts) {
    if (!tts) return;
    if (tts->to_worker >= 0) {
        if (tts->ok) {
            const char* q = "QUIT\n";
            (void)write_all(tts->to_worker, q, strlen(q));
        }
        close(tts->to_worker);
        tts->to_worker = -1;
    }
    if (tts->from_worker >= 0) {
        close(tts->from_worker);
        tts->from_worker = -1;
    }
    if (tts->pid > 0) {
        int status = 0;
        /* Give it a moment, then kill. */
        for (int i = 0; i < 50; i++) {
            pid_t r = waitpid(tts->pid, &status, WNOHANG);
            if (r == tts->pid || (r < 0 && errno == ECHILD)) break;
            struct timespec ts = { .tv_sec = 0, .tv_nsec = 20 * 1000 * 1000 };
            nanosleep(&ts, NULL);
        }
        if (waitpid(tts->pid, &status, WNOHANG) == 0) {
            kill(tts->pid, SIGTERM);
            waitpid(tts->pid, &status, 0);
        }
        tts->pid = -1;
    }
    free(tts);
}

int ff4_tts_ok(const Ff4Tts* tts) {
    return tts && tts->ok;
}

int ff4_tts_num_speakers(const Ff4Tts* tts) {
    (void)tts;
    return k_num_voices;
}

int ff4_tts_sample_rate(const Ff4Tts* tts) {
    (void)tts;
    return 24000;
}

const char* ff4_tts_info(const Ff4Tts* tts) {
    if (!tts) return "not loaded";
    return tts->info;
}

int ff4_tts_synthesize(
    Ff4Tts* tts,
    const char* text,
    int sid,
    float speed,
    const char* out_wav)
{
    char cmd[8192];
    char line[1024];
    const char* voice;
    size_t i, j;
    char clean[4096];

    if (!tts || !tts->ok || !text || !text[0] || !out_wav || !out_wav[0]) return -1;
    if (sid < 0) sid = 0;
    if (sid >= k_num_voices) sid %= k_num_voices;
    voice = k_voices[sid];
    if (speed < 0.5f) speed = 0.5f;
    if (speed > 2.0f) speed = 2.0f;

    /* Sanitize text: printable ASCII + spaces; no newlines (protocol). */
    j = 0;
    for (i = 0; text[i] && j + 1 < sizeof(clean); i++) {
        unsigned char c = (unsigned char)text[i];
        if (c == '\n' || c == '\r' || c == '\t') {
            clean[j++] = ' ';
        } else if (c >= 32 && c < 127) {
            clean[j++] = (char)c;
        }
    }
    while (j > 0 && clean[j - 1] == ' ') j--;
    clean[j] = 0;
    if (j == 0) return -1;

    /* Paths must not contain spaces for this simple protocol. */
    if (strchr(out_wav, ' ') || strchr(voice, ' ')) {
        fprintf(stderr, "ff4_tts: path/voice must not contain spaces\n");
        return -1;
    }

    int n = snprintf(cmd, sizeof(cmd), "SYNTH %s %.3f %s %s\n", voice, speed, out_wav, clean);
    if (n <= 0 || (size_t)n >= sizeof(cmd)) {
        fprintf(stderr, "ff4_tts: command too long\n");
        return -1;
    }
    if (write_all(tts->to_worker, cmd, (size_t)n) != 0) {
        fprintf(stderr, "ff4_tts: write to worker failed\n");
        tts->ok = 0;
        return -1;
    }

    /* Synthesis can be a few seconds; allow headroom. */
    int rl = read_line(tts->from_worker, line, sizeof(line), 120000);
    if (rl < 0) {
        fprintf(stderr, "ff4_tts: no response from worker (%d)\n", rl);
        tts->ok = 0;
        return -1;
    }
    if (strncmp(line, "OK ", 3) == 0) {
        if (!file_exists(out_wav)) {
            fprintf(stderr, "ff4_tts: worker OK but missing %s\n", out_wav);
            return -1;
        }
        return 0;
    }
    fprintf(stderr, "ff4_tts: %s\n", line);
    return -1;
}
