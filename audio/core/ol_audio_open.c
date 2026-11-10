#include "ol_audio.h"

#include <stdio.h>
#include <string.h>

const char *ol_domain_name(ol_domain d) {
  switch (d) {
    case OL_DOMAIN_AAUDIO: return "aaudio";
    case OL_DOMAIN_OPENSLES: return "opensles";
    case OL_DOMAIN_PJSIP: return "pjsip";
    case OL_DOMAIN_AVAUDIOSESSION: return "avaudiosession";
    case OL_DOMAIN_CORE: return "core";
    default: return "none";
  }
}

static int64_t now_or_zero(const ol_open_config *cfg) {
  return cfg->now_ns ? cfg->now_ns(cfg->clock_ctx) : 0;
}

static int try_one(const ol_open_config *cfg, ol_direction dir, const ol_backend *b, int index,
                   int rate, ol_open_report *r) {
  if (r->n_attempts >= OL_MAX_ATTEMPTS) return 0;
  ol_attempt *a = &r->attempts[r->n_attempts++];
  memset(a, 0, sizeof(*a));
  a->backend_index = index;
  a->backend = b->name;
  a->requested_rate = rate;
  a->domain = b->domain;
  a->t_start_ns = now_or_zero(cfg);
  int actual = 0;
  int32_t st = b->open(b->ctx, dir, rate, cfg->channels, &actual);
  if (st == 0 && b->start) st = b->start(b->ctx, dir);
  a->t_end_ns = now_or_zero(cfg);
  a->native_status = st;
  if (st == 0) {
    a->actual_rate = actual;
    return 1;
  }
  /* cleanup: release whatever the failed attempt grabbed before retrying */
  b->close(b->ctx, dir);
  a->cleanup_called = 1;
  if (r->first_error_domain == OL_DOMAIN_NONE) {
    r->first_error_domain = b->domain;
    r->first_error_status = st;
  }
  r->last_error_domain = b->domain;
  r->last_error_status = st;
  return 0;
}

int ol_open_with_fallback(const ol_open_config *cfg, ol_direction dir, const ol_backend *def,
                          const ol_backend *alt, ol_open_report *r) {
  memset(r, 0, sizeof(*r));
  r->backend_index = -1;
  r->engine_rate = cfg->engine_rate;
  const ol_backend *chosen = NULL;
  if (try_one(cfg, dir, def, 0, 0, r)) {
    chosen = def;
    r->backend_index = 0;
  } else if (alt) {
    int64_t backoff = cfg->retry_backoff_ms > 0 ? cfg->retry_backoff_ms : 120;
    if (cfg->sleep_ms) cfg->sleep_ms(cfg->clock_ctx, backoff);
    if (try_one(cfg, dir, alt, 1, OL_ALT_RATE, r)) {
      chosen = alt;
      r->backend_index = 1;
    }
  }
  if (!chosen) return 0;
  r->ok = 1;
  r->backend = chosen->name;
  r->device_rate = r->attempts[r->n_attempts - 1].actual_rate;
  r->needs_resample = r->device_rate != cfg->engine_rate;
  if (r->needs_resample) {
    ol_resampler probe;
    if (ol_resampler_init(&probe, r->device_rate, cfg->engine_rate) != 0) {
      /* opened at a rate we cannot convert: treat as failure, release */
      chosen->close(chosen->ctx, dir);
      r->attempts[r->n_attempts - 1].cleanup_called = 1;
      r->ok = 0;
      r->last_error_domain = OL_DOMAIN_CORE;
      r->last_error_status = -1;
      if (r->first_error_domain == OL_DOMAIN_NONE) {
        r->first_error_domain = OL_DOMAIN_CORE;
        r->first_error_status = -1;
      }
      r->backend_index = -1;
      r->backend = NULL;
    }
  }
  return r->ok;
}

int ol_open_report_json(const ol_open_report *r, ol_direction dir, char *buf, size_t cap) {
  int n = snprintf(buf, cap,
                   "{\"dir\":\"%s\",\"ok\":%d,\"backend\":\"%s\",\"deviceRate\":%d,\"engineRate\":%d,"
                   "\"resample\":%d,\"firstError\":{\"domain\":\"%s\",\"status\":%d},"
                   "\"lastError\":{\"domain\":\"%s\",\"status\":%d},\"attempts\":[",
                   dir == OL_DIR_CAPTURE ? "capture" : "playout", r->ok, r->backend ? r->backend : "",
                   r->device_rate, r->engine_rate, r->needs_resample, ol_domain_name(r->first_error_domain),
                   (int)r->first_error_status, ol_domain_name(r->last_error_domain), (int)r->last_error_status);
  for (int i = 0; i < r->n_attempts && n > 0 && (size_t)n < cap; i++) {
    const ol_attempt *a = &r->attempts[i];
    n += snprintf(buf + n, cap - (size_t)n,
                  "%s{\"backend\":\"%s\",\"reqRate\":%d,\"rate\":%d,\"domain\":\"%s\",\"status\":%d,\"cleanup\":%d,\"ms\":%lld}",
                  i ? "," : "", a->backend, a->requested_rate, a->actual_rate, ol_domain_name(a->domain),
                  (int)a->native_status, a->cleanup_called, (long long)((a->t_end_ns - a->t_start_ns) / 1000000));
  }
  if (n > 0 && (size_t)n < cap) n += snprintf(buf + n, cap - (size_t)n, "]}");
  return n;
}
