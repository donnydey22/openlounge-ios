/*
 * Open Lounge audio core - portable C11, no platform headers.
 *
 * Shared by:
 *   - Android: android/cpp/OlAudioDeviceModule.cpp (webrtc::AudioDeviceModule
 *     injected into tgcalls via Descriptor.createAudioDeviceModule), with
 *     AAudio (default) and OpenSL ES (alternate) backends.
 *   - iOS: ios/OLAudioSessionController.swift drives ol_session_* for the
 *     AVAudioSession / RTCAudioSession activation policy.
 * Unit-tested on the build host (audio/tests, regress/).
 *
 * ERROR CODES - NO INVENTED MAPPING.
 *   Every native status is stored verbatim as int32 together with the domain
 *   that produced it (OL_DOMAIN_*). The core never translates one domain's
 *   code into another's. In particular:
 *     420003  = PJMEDIA_EAUD_INIT in the retired PJSIP stack
 *               (pj-openlounge-android 8cb35eb NativeCallMedia.kt:111-112;
 *               420000 PJMEDIA_AUDIODEV_ERRNO_START + 3). Domain OL_DOMAIN_PJSIP.
 *     4200003 = value reported by the owner for the Note 10+ openSound failure.
 *               Not present in any OL repository or git history (searched
 *               2026-11-06). Kept only as a fixture label; never produced or
 *               matched by code.
 *   Under the new engine a Samsung failure will surface as an AAudio
 *   aaudio_result_t (OL_DOMAIN_AAUDIO) or an OpenSL SLresult
 *   (OL_DOMAIN_OPENSLES) and must be re-observed on the device.
 */
#ifndef OL_AUDIO_H
#define OL_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  OL_DOMAIN_NONE = 0,
  OL_DOMAIN_AAUDIO = 1,     /* aaudio_result_t */
  OL_DOMAIN_OPENSLES = 2,   /* SLresult */
  OL_DOMAIN_PJSIP = 3,      /* pj_status_t (legacy fixtures only) */
  OL_DOMAIN_AVAUDIOSESSION = 4, /* NSError.code / OSStatus (FourCC) */
  OL_DOMAIN_CORE = 5        /* olcall core (e.g. resampler unsupported ratio) */
} ol_domain;

const char *ol_domain_name(ol_domain d);

typedef enum { OL_DIR_CAPTURE = 0, OL_DIR_PLAYOUT = 1 } ol_direction;

/* One open attempt as observed. */
typedef struct {
  int backend_index;   /* 0 = default backend, 1 = alternate backend */
  const char *backend; /* backend name ("aaudio", "opensles", ...) */
  int requested_rate;  /* 0 = backend/device default */
  int actual_rate;     /* rate the stream really opened at (0 on failure) */
  ol_domain domain;
  int32_t native_status; /* verbatim backend status; 0 = OK */
  int cleanup_called;  /* close() invoked after this attempt failed */
  int64_t t_start_ns, t_end_ns;
} ol_attempt;

/* Backend vtable implemented by aaudio_backend.c / opensl_backend.c / tests. */
typedef struct ol_backend {
  const char *name;
  ol_domain domain;
  /* Open one direction. requested_rate 0 = native default. On success write
   * the actual rate and return 0; on failure return the native status
   * (non-zero) and leave the backend in a state where close() is safe. */
  int32_t (*open)(void *ctx, ol_direction dir, int requested_rate, int channels, int *actual_rate);
  int32_t (*start)(void *ctx, ol_direction dir);
  /* Must be idempotent and safe on a partially opened stream. */
  void (*close)(void *ctx, ol_direction dir);
  void *ctx;
} ol_backend;

#define OL_MAX_ATTEMPTS 4
#define OL_ALT_RATE 16000

typedef struct {
  int engine_rate;          /* rate WebRTC's ADM runs at (48000) */
  int channels;             /* 1 */
  int64_t retry_backoff_ms; /* delay before the alternate attempt (default 120) */
  /* injectable clock/sleep for tests and replays */
  int64_t (*now_ns)(void *);
  void (*sleep_ms)(void *, int64_t);
  void *clock_ctx;
} ol_open_config;

typedef struct {
  int ok;
  int backend_index;     /* backend that succeeded (-1 none) */
  const char *backend;
  int device_rate;       /* actual device rate */
  int engine_rate;
  int needs_resample;    /* device_rate != engine_rate */
  int n_attempts;
  ol_attempt attempts[OL_MAX_ATTEMPTS];
  /* the FIRST failure, preserved verbatim even when a retry succeeds */
  ol_domain first_error_domain;
  int32_t first_error_status;
  /* the LAST failure (what to surface when everything failed) */
  ol_domain last_error_domain;
  int32_t last_error_status;
} ol_open_report;

/*
 * Strategy (owner requirement "default open, then 16 kHz alternate-backend
 * retry with cleanup + resample to engine rate, real native status"):
 *   1. default backend, device default rate
 *   2. on failure: close() that direction on the default backend (cleanup),
 *      wait retry_backoff_ms (Samsung HALs need the device released),
 *   3. alternate backend at 16000 Hz,
 *   4. on success, needs_resample = (device_rate != engine_rate).
 * Each attempt's native status is recorded verbatim. Returns report->ok.
 */
int ol_open_with_fallback(const ol_open_config *cfg, ol_direction dir,
                          const ol_backend *def, const ol_backend *alt,
                          ol_open_report *report);

/* JSON summary (no payloads, safe for logs/breadcrumbs). Returns length. */
int ol_open_report_json(const ol_open_report *r, ol_direction dir, char *buf, size_t cap);

/* ---------------- resampler (integer ratio, windowed-sinc FIR) ---------------- */

#define OL_RS_TAPS_PER_PHASE 16
#define OL_RS_MAX_RATIO 6

typedef struct {
  int in_rate, out_rate;
  int up, down;            /* out/in = up/down, one of them is 1 */
  int taps;                /* total FIR length = taps_per_phase * max(up,down) */
  float coef[OL_RS_TAPS_PER_PHASE * OL_RS_MAX_RATIO];
  float hist[OL_RS_TAPS_PER_PHASE * OL_RS_MAX_RATIO];
  int hist_len;
  int phase;               /* decimation phase carried across calls */
} ol_resampler;

/* Returns 0 or OL_DOMAIN_CORE-level error -1 for unsupported ratio. */
int ol_resampler_init(ol_resampler *rs, int in_rate, int out_rate);
/* Process n_in mono samples; returns number of output samples written
 * (out must hold n_in*up/down + 1). */
int ol_resampler_process(ol_resampler *rs, const int16_t *in, int n_in, int16_t *out);

/* ---------------- iOS session activation policy ---------------- */

#define OL_FOURCC(a, b, c, d) ((int32_t)(((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d)))
/* AVAudioSessionErrorCode values (AVFAudio AVAudioSessionTypes.h, FourCC) */
#define OL_AVS_ERR_INSUFFICIENT_PRIORITY OL_FOURCC('!', 'p', 'r', 'i')
#define OL_AVS_ERR_CANNOT_INTERRUPT_OTHERS OL_FOURCC('!', 'i', 'n', 't')
#define OL_AVS_ERR_IS_BUSY OL_FOURCC('!', 'a', 'c', 't')
#define OL_AVS_ERR_CANNOT_START_PLAYING OL_FOURCC('!', 'p', 'l', 'a')
#define OL_AVS_ERR_CANNOT_START_RECORDING OL_FOURCC('!', 'r', 'e', 'c')
#define OL_AVS_ERR_MEDIA_SERVICES_FAILED OL_FOURCC('m', 's', 'r', 'v')

typedef enum {
  OL_SESS_IDLE = 0,
  OL_SESS_WAIT_CALLKIT,      /* CallKit owns activation: wait for didActivate */
  OL_SESS_ACTIVATING,        /* we call setActive(true) ourselves */
  OL_SESS_WAIT_RETRY,        /* transient failure, retry scheduled */
  OL_SESS_WAIT_INTERRUPTION, /* blocked by a higher-priority session */
  OL_SESS_ACTIVE,
  OL_SESS_FAILED
} ol_session_state;

typedef enum {
  OL_ACT_NONE = 0,
  OL_ACT_CALL_SET_ACTIVE,     /* platform: call setActive(true) now */
  OL_ACT_SCHEDULE_RETRY,      /* platform: call ol_session_on_timer after delay_ms */
  OL_ACT_ENABLE_AUDIO,        /* platform: RTCAudioSession.audioSessionDidActivate + isAudioEnabled=true */
  OL_ACT_DISABLE_AUDIO,       /* platform: isAudioEnabled=false */
  OL_ACT_REPORT_FAILURE       /* platform: end/notify with last_status (verbatim) */
} ol_session_action;

typedef struct {
  ol_session_state state;
  int callkit;          /* activation owned by CallKit (provider didActivate) */
  int attempts;
  int max_attempts;     /* setActive attempts (default 3) */
  int64_t delay_ms;     /* next retry delay */
  int32_t first_status; /* first setActive failure, verbatim */
  int32_t last_status;
} ol_session;

void ol_session_init(ol_session *s, int callkit, int max_attempts);
/* call is starting: returns the first action */
ol_session_action ol_session_begin(ol_session *s);
/* result of setActive(true): 0 = success, else NSError.code verbatim */
ol_session_action ol_session_on_set_active(ol_session *s, int32_t status, int64_t *delay_ms);
ol_session_action ol_session_on_timer(ol_session *s);
/* CallKit provider(_:didActivate:) */
ol_session_action ol_session_on_callkit_activate(ol_session *s);
ol_session_action ol_session_on_callkit_deactivate(ol_session *s);
/* AVAudioSessionInterruptionNotification: began=1/ended=0, should_resume */
ol_session_action ol_session_on_interruption(ol_session *s, int began, int should_resume);
/* deadline passed while waiting (CallKit/interruption) */
ol_session_action ol_session_on_timeout(ol_session *s);
const char *ol_session_state_name(ol_session_state st);
int ol_session_is_transient(int32_t status);

#ifdef __cplusplus
}
#endif
#endif
