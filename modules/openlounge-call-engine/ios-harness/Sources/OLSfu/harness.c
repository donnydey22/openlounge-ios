#include <pjsua-lib/pjsua.h>
#include "ol_sfu.h"
#include "olsfu_harness.h"
int ol_harness_init(void) {
  pjsua_config c; pjsua_logging_config l; pjsua_media_config m; pjsua_config_default(&c); pjsua_logging_config_default(&l); pjsua_media_config_default(&m);
  l.console_level = 3; m.clock_rate = 48000; m.no_vad = 1;
  if (pjsua_create() || pjsua_init(&c, &l, &m) || pjsua_start()) return -1;
  return pjsua_set_null_snd_dev() == PJ_SUCCESS ? 0 : -2; }
int ol_harness_start(const char *ip, int port, const char *tx, const char *rx, unsigned ssrc, int txPt, int rxPt) { return ol_sfu_audio_start(ip, port, tx, rx, ssrc, txPt, rxPt, 440); }
void ol_harness_stats(unsigned *rx, unsigned *lost, unsigned *tx, int *level) { ol_sfu_stats(rx, lost, tx); *level = ol_sfu_rx_level(); }
void ol_harness_stop(void) { ol_sfu_stop(); pjsua_destroy(); }
