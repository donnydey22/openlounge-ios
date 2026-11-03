/* Open Lounge engine: phone -> mediasoup PlainTransport audio leg (PLAN §13). No SIP, no ICE: pjmedia UDP transport
   (rtcp-mux) + SRTP SDES (AES_CM_128_HMAC_SHA1_80, keys from signaling a=crypto / plain:create) + pjmedia_stream
   (Opus, adaptive jbuf progressive discard + PLC) on the pjsua conference bridge. Shared by iOS and Android shims. */
#include <pjsua-lib/pjsua.h>
#include <pjmedia-codec/opus.h>
#include <pjlib-util/base64.h>
#include "ol_sfu.h"

static pj_pool_t *pool; static pjmedia_transport *udp, *srtp; static pjmedia_stream *stream; static pjsua_conf_port_id slot = -1, tone_slot = -1;
static pjmedia_port *tone; static int rcvbuf_before, rcvbuf_after;

static int b64key(const char *b64, char *out30) { int n = 30; pj_str_t s = pj_str((char *)b64);
  return pj_base64_decode(&s, (pj_uint8_t *)out30, &n) == PJ_SUCCESS && n == 30 ? 0 : -1; }

int ol_sfu_audio_start(const char *ip, int port, const char *tx_b64, const char *rx_b64, unsigned ssrc, int tx_pt, int rx_pt, int test_tone_hz) {
  pjmedia_endpt *ep = pjsua_get_pjmedia_endpt(); if (!ep) return -1;
  ol_sfu_stop();
  pool = pjsua_pool_create("olsfu", 4000, 4000);
  pj_str_t any = pj_str("0.0.0.0");
  { /* udp_create3 needs an explicit port (binds RTP + RTP+1); probe an even port */
    int base = 42000 + (int)(pj_rand() % 4000) * 2, ok = 0;
    for (int i = 0; i < 64 && !ok; i++) ok = pjmedia_transport_udp_create3(ep, pj_AF_INET(), "olsfu", &any, base + 2 * i, 0, &udp) == PJ_SUCCESS;
    if (!ok) return -2; }
  { /* Bursty senders (WS relay / browser timers) overflow the small default UDP rcvbuf (macOS/iOS ~42-200KB) -> kernel drops
       before pjmedia sees them. Raise to 1 MB on RTP socket and record what the kernel granted. */
    pjmedia_transport_info ti; pjmedia_transport_info_init(&ti); pjmedia_transport_get_info(udp, &ti);
    int v = 0; int l = sizeof v; pj_sock_getsockopt(ti.sock_info.rtp_sock, pj_SOL_SOCKET(), pj_SO_RCVBUF(), &v, &l); rcvbuf_before = v;
    v = 1 << 20; pj_sock_setsockopt(ti.sock_info.rtp_sock, pj_SOL_SOCKET(), pj_SO_RCVBUF(), &v, sizeof v);
    v = 0; l = sizeof v; pj_sock_getsockopt(ti.sock_info.rtp_sock, pj_SOL_SOCKET(), pj_SO_RCVBUF(), &v, &l); rcvbuf_after = v; }
  pjmedia_srtp_setting ss; pjmedia_srtp_setting_default(&ss); ss.use = PJMEDIA_SRTP_MANDATORY; ss.close_member_tp = PJ_TRUE;
  if (pjmedia_transport_srtp_create(ep, udp, &ss, &srtp) != PJ_SUCCESS) return -3;
  static char txk[30], rxk[30]; if (b64key(tx_b64, txk) || b64key(rx_b64, rxk)) return -4;
  pjmedia_srtp_crypto tx, rx; pj_bzero(&tx, sizeof tx); pj_bzero(&rx, sizeof rx);
  tx.name = rx.name = pj_str("AES_CM_128_HMAC_SHA1_80"); tx.key = pj_str(txk); tx.key.slen = 30; rx.key = pj_str(rxk); rx.key.slen = 30;
  if (pjmedia_transport_srtp_start(srtp, &tx, &rx) != PJ_SUCCESS) return -5;
  pjmedia_stream_info si; pj_bzero(&si, sizeof si);
  si.type = PJMEDIA_TYPE_AUDIO; si.proto = PJMEDIA_TP_PROTO_RTP_SAVP; si.dir = PJMEDIA_DIR_ENCODING_DECODING; si.rtcp_mux = PJ_TRUE;
  const pjmedia_codec_info *ci; unsigned cnt = 1; pj_str_t opus = pj_str("opus/48000");
  if (pjmedia_codec_mgr_find_codecs_by_id(pjmedia_endpt_get_codec_mgr(ep), &opus, &cnt, &ci, NULL) != PJ_SUCCESS || !cnt) return -6;
  si.fmt = *ci; si.tx_pt = tx_pt; si.rx_pt = rx_pt; si.ssrc = ssrc;
  si.param = PJ_POOL_ALLOC_T(pool, pjmedia_codec_param); pjmedia_codec_mgr_get_default_param(pjmedia_endpt_get_codec_mgr(ep), ci, si.param);
  { /* OPUS_PIN: one fixed Opus profile on every leg (matches media-sfu plain.mjs): 48 kHz mono, 20 ms, inband FEC on,
       expected loss 20 % (FEC kicks in under loss), VBR, PLC on. fmtp pinned both ways. */
    pjmedia_codec_opus_config oc; if (pjmedia_codec_opus_get_config(&oc) == PJ_SUCCESS) { oc.sample_rate = 48000; oc.channel_cnt = 1;
      oc.frm_ptime = 20; oc.packet_loss = 20; oc.cbr = PJ_FALSE; oc.bit_rate = 32000; pjmedia_codec_opus_set_default_param(&oc, si.param); }
    si.param->setting.plc = 1; si.param->setting.vad = 0; si.param->setting.frm_per_pkt = 1;
    static const char *k[] = { "useinbandfec", "minptime", "stereo", "maxplaybackrate" }, *v[] = { "1", "10", "0", "48000" };
    pjmedia_codec_fmtp *f[2] = { &si.param->setting.enc_fmtp, &si.param->setting.dec_fmtp };
    for (int j = 0; j < 2; j++) { f[j]->cnt = 0; for (int i = 0; i < 4; i++) { f[j]->param[i].name = pj_str((char *)k[i]); f[j]->param[i].val = pj_str((char *)v[i]); f[j]->cnt++; } } }
  si.jb_init = -1; si.jb_min_pre = 1; si.jb_max_pre = 16; si.jb_max = 50; si.jb_discard_algo = PJMEDIA_JB_DISCARD_PROGRESSIVE;
  pj_str_t rip = pj_str((char *)ip); if (pj_sockaddr_init(pj_AF_INET(), &si.rem_addr, &rip, (pj_uint16_t)port) != PJ_SUCCESS) return -7;
  si.rem_rtcp = si.rem_addr;
  if (pjmedia_stream_create(ep, pool, &si, srtp, NULL, &stream) != PJ_SUCCESS) return -8;
  /* No SDP negotiation here: start the UDP member directly (sets udp->started, arms reads); SRTP is already keyed. */
  if (pjmedia_transport_media_start(udp, pool, NULL, NULL, 0) != PJ_SUCCESS) return -11;
  if (pjmedia_stream_start(stream) != PJ_SUCCESS) return -9;
  pjmedia_port *sp; pjmedia_stream_get_port(stream, &sp);
  if (pjsua_conf_add_port(pool, sp, &slot) != PJ_SUCCESS) return -10;
  if (test_tone_hz > 0) { /* CI harness: inject a tone instead of the mic */
    pjmedia_tonegen_create(pool, 48000, 1, 960, 16, PJMEDIA_TONEGEN_LOOP, &tone);
    pjmedia_tone_desc d; pj_bzero(&d, sizeof d); d.freq1 = (short)test_tone_hz; d.on_msec = 30000; d.off_msec = 0; d.volume = 16000;
    pjmedia_tonegen_play(tone, 1, &d, PJMEDIA_TONEGEN_LOOP); pjsua_conf_add_port(pool, tone, &tone_slot); pjsua_conf_connect(tone_slot, slot);
    pjsua_conf_connect(slot, 0); /* keep the stream port read so rx level is measured */
  } else { pjsua_conf_connect(0, slot); pjsua_conf_connect(slot, 0); }
  return 0;
}
/* Received level 0..255 (pjsua conf rx level of the stream port) and stream stats for the matrix. */
int ol_sfu_rx_level(void) { unsigned tx = 0, rx = 0; if (slot < 0) return -1; pjsua_conf_get_signal_level(slot, &tx, &rx); return (int)rx; }
int ol_sfu_stats(unsigned *rx_pkt, unsigned *rx_lost, unsigned *tx_pkt) { pjmedia_rtcp_stat st; if (!stream || pjmedia_stream_get_stat(stream, &st) != PJ_SUCCESS) return -1;
  *rx_pkt = st.rx.pkt; *rx_lost = st.rx.loss; *tx_pkt = st.tx.pkt; return 0; }
int ol_sfu_local_port(void) { pjmedia_transport_info ti; if (!udp) return -1; pjmedia_transport_info_init(&ti); pjmedia_transport_get_info(udp, &ti); return pj_sockaddr_get_port(&ti.sock_info.rtp_addr_name); }
void ol_sfu_stop(void) {
  if (tone_slot >= 0) { pjsua_conf_remove_port(tone_slot); tone_slot = -1; } if (tone) { pjmedia_port_destroy(tone); tone = NULL; }
  if (slot >= 0) { pjsua_conf_remove_port(slot); slot = -1; }
  if (stream) { pjmedia_stream_destroy(stream); stream = NULL; }
  if (srtp) { pjmedia_transport_close(srtp); srtp = NULL; udp = NULL; }
  if (pool) { pj_pool_release(pool); pool = NULL; }
}
/* Diagnostics for the matrix: kernel rcvbuf before/after, jitter-buffer counters, stream rx discards. */
int ol_sfu_diag(int *rb0, int *rb1, unsigned *jb_disc, unsigned *jb_lost, unsigned *jb_empty, unsigned *jb_avg_ms, unsigned *rx_discard) {
  pjmedia_jb_state j; pjmedia_rtcp_stat st; *rb0 = rcvbuf_before; *rb1 = rcvbuf_after;
  if (!stream || pjmedia_stream_get_stat_jbuf(stream, &j) != PJ_SUCCESS || pjmedia_stream_get_stat(stream, &st) != PJ_SUCCESS) return -1;
  *jb_disc = j.discard; *jb_lost = j.lost; *jb_empty = j.empty; *jb_avg_ms = j.avg_delay; *rx_discard = st.rx.discard; return 0; }
