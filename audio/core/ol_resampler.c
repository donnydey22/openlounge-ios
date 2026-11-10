/* Integer-ratio polyphase resampler (Blackman-windowed sinc FIR).
 * Covers the conversions the ADM needs: 16000<->48000 (x3), 8000<->48000
 * (x6), 24000<->48000 (x2), 16000<->32000 ... Non-integer ratios (e.g.
 * 44100<->48000) return -1: the ADM then refuses the stream rather than
 * silently degrading (see docs/AUDIO.md). */
#include "ol_audio.h"

#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

int ol_resampler_init(ol_resampler *rs, int in_rate, int out_rate) {
  memset(rs, 0, sizeof(*rs));
  if (in_rate <= 0 || out_rate <= 0) return -1;
  rs->in_rate = in_rate;
  rs->out_rate = out_rate;
  if (out_rate % in_rate == 0) {
    rs->up = out_rate / in_rate;
    rs->down = 1;
  } else if (in_rate % out_rate == 0) {
    rs->up = 1;
    rs->down = in_rate / out_rate;
  } else {
    return -1;
  }
  int r = rs->up > rs->down ? rs->up : rs->down;
  if (r > OL_RS_MAX_RATIO) return -1;
  rs->taps = OL_RS_TAPS_PER_PHASE * r;
  if (r == 1) { /* identity */
    rs->taps = 1;
    rs->coef[0] = 1.0f;
    return 0;
  }
  /* low-pass at 0.45 x the lower Nyquist, designed at the higher rate */
  double fc = 0.45 / r; /* cycles/sample at high rate */
  double mid = (rs->taps - 1) / 2.0;
  double sum = 0;
  for (int i = 0; i < rs->taps; i++) {
    double x = i - mid;
    double s = x == 0 ? 2 * fc : sin(2 * M_PI * fc * x) / (M_PI * x);
    double w = 0.42 - 0.5 * cos(2 * M_PI * i / (rs->taps - 1)) + 0.08 * cos(4 * M_PI * i / (rs->taps - 1));
    rs->coef[i] = (float)(s * w);
    sum += s * w;
  }
  for (int i = 0; i < rs->taps; i++) rs->coef[i] = (float)(rs->coef[i] / sum);
  return 0;
}

static int16_t sat16(float v) {
  if (v > 32767.f) return 32767;
  if (v < -32768.f) return -32768;
  return (int16_t)lrintf(v);
}

/* history holds the last (taps-1) samples at the HIGH rate domain for
 * decimation, or at the low rate for interpolation (polyphase). */
int ol_resampler_process(ol_resampler *rs, const int16_t *in, int n_in, int16_t *out) {
  if (rs->taps == 1) {
    memcpy(out, in, (size_t)n_in * sizeof(int16_t));
    return n_in;
  }
  int n_out = 0;
  if (rs->up > 1) {
    /* interpolation: each input sample yields `up` outputs; polyphase over
     * the low-rate history (taps/up samples per phase). */
    const int L = rs->up, P = rs->taps / L;
    for (int i = 0; i < n_in; i++) {
      /* shift history (length P) */
      memmove(rs->hist, rs->hist + 1, (size_t)(P - 1) * sizeof(float));
      rs->hist[P - 1] = in[i];
      for (int ph = 0; ph < L; ph++) {
        float acc = 0;
        for (int k = 0; k < P; k++) acc += rs->hist[P - 1 - k] * rs->coef[k * L + ph];
        out[n_out++] = sat16(acc * (float)L);
      }
    }
  } else {
    /* decimation: filter at input rate, keep every `down`-th sample */
    const int M = rs->down, T = rs->taps;
    for (int i = 0; i < n_in; i++) {
      memmove(rs->hist, rs->hist + 1, (size_t)(T - 1) * sizeof(float));
      rs->hist[T - 1] = in[i];
      if (rs->phase == 0) {
        float acc = 0;
        for (int k = 0; k < T; k++) acc += rs->hist[T - 1 - k] * rs->coef[k];
        out[n_out++] = sat16(acc);
      }
      rs->phase = (rs->phase + 1) % M;
    }
  }
  return n_out;
}
