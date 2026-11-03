#include "OLPjsip.h"
#include <pjsua-lib/pjsua.h>
static int started = 0;
int ol_pjsip_start(int mn, int mx, int jm) {
  if (started) return 0;
  pjsua_config c; pjsua_media_config m; pjsua_config_default(&c); pjsua_media_config_default(&m);
  m.jb_init = -1; m.jb_min_pre = mn; m.jb_max_pre = mx; m.jb_max = jm;
  m.jb_discard_algo = PJMEDIA_JB_DISCARD_PROGRESSIVE; m.no_vad = 1; m.clock_rate = 48000; m.snd_clock_rate = 48000;
  if (pjsua_create() != PJ_SUCCESS) return -1;
  if (pjsua_init(&c, NULL, &m) != PJ_SUCCESS) return -2;
  if (pjsua_start() != PJ_SUCCESS) return -3;
  pjsua_set_no_snd_dev(); // no audio until CallKit didActivate
  pjsua_acc_config a; pjsua_acc_config_default(&a);
  a.id = pj_str("sip:openlounge@local");
  a.use_srtp = PJMEDIA_SRTP_MANDATORY; a.srtp_secure_signaling = 0;
  a.srtp_opt.keying_count = 1; a.srtp_opt.keying[0] = PJMEDIA_SRTP_KEYING_SDES;
  pjsua_acc_add(&a, PJ_TRUE, NULL);
  started = 1; return 0;
}
int ol_pjsip_open_sound(void) { return started ? pjsua_set_snd_dev(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV, PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV) : -1; }
void ol_pjsip_close_sound(void) { if (started) pjsua_set_no_snd_dev(); }
void ol_pjsip_teardown(void) { if (started) { pjsua_call_hangup_all(); pjsua_set_no_snd_dev(); } }
/* Video (t4464u): H.264 base via VideoToolbox (pjmedia vid_toolbox codec). QuickHD: start at high res/bitrate,
   ol_pjsip_video_steady() drops to steady caps after the burst. pjmedia 2.17 has no AV1 codec; AV1 hw is only
   detected (Swift) and advertised so the SFU picks H.264 unless both ends gain AV1. */
#if PJMEDIA_HAS_VIDEO
static int set_h264(int w, int h, int bps) {
  pj_str_t id = pj_str("H264"); pjmedia_vid_codec_param p;
  if (pjsua_vid_codec_set_priority(&id, 255) != PJ_SUCCESS) return -1;
  if (pjsua_vid_codec_get_param(&id, &p) != PJ_SUCCESS) return -2;
  p.enc_fmt.det.vid.size.w = w; p.enc_fmt.det.vid.size.h = h;
  p.enc_fmt.det.vid.avg_bps = bps; p.enc_fmt.det.vid.max_bps = bps;
  return pjsua_vid_codec_set_param(&id, &p) == PJ_SUCCESS ? 0 : -3;
}
int ol_pjsip_video_quickhd(void) { return started ? set_h264(1920, 1080, 2500000) : -1; }
int ol_pjsip_video_steady(void) { return started ? set_h264(1280, 720, 1200000) : -1; }
#else
int ol_pjsip_video_quickhd(void) { return -9; }
int ol_pjsip_video_steady(void) { return -9; }
#endif
