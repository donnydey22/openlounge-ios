/* Open Lounge phone-to-phone P2P audio (iOS + Android shims share this file, like ol_sfu.c).
   Connectivity follows Telegram tgcalls v2/NativeNetworkingImpl.cpp (TelegramMessenger/tgcalls @ 38dcea1):
   - :576-606  one allocator with host + STUN(srflx) + TURN(relay) candidates; :596-601 relay-only when P2P is off
   - :610-626  TURN servers from config (here: our coturn on the droplet)
   - :635-637  keep gathering / regather when networks change -> here ol_p2p_restart() on an OS network-change event
   ICE = pjnath via pjmedia_transport_ice; NO encryption: plain RTP straight on the ICE transport (Donny: no encryption).
   Same Opus pin as ol_sfu.c. If ICE fails, ev 3 tells the app to keep the SFU leg (existing path). */
#include <pjsua-lib/pjsua.h>
#include <pjmedia-codec/opus.h>
#include <string.h>
#include <stdlib.h>
#include "ol_p2p.h"
#include "ol_sfu_video.h"

static pj_pool_t *pool; static pjmedia_transport *ice, *srtp; static pjmedia_stream *stream;
static pjsua_conf_port_id slot = -1, tone_slot = -1; static pjmedia_port *tone;
static pjmedia_sdp_session *local_sdp, *remote_sdp; static int gathered, started, live; /* live = wired to mic/speaker (only after the switch) */
static ol_p2p_cfg cfg; static char s_stun[128], s_turn[128], s_tu[128], s_tp[256];
static ol_p2p_cb cb; static void *cb_user;

/* Bundle demux (tgcalls v2: audio and video share one RTP transport, InstanceV2Impl.cpp:154/:460 + :1135). A thin
   pjmedia transport between the audio stream and plain-RTP-over-ICE: PT 102 (H.264) goes to the video path, everything else
   to the Opus stream; RTCP goes to both (PLI/FIR for video, SR/RR for audio). */
#define OL_P2P_VIDEO_PT 102
typedef struct { pjmedia_transport base; void *ud; void (*rtp_cb2)(pjmedia_tp_cb_param *); void (*rtp_cb)(void *, void *, pj_ssize_t);
  void (*rtcp_cb)(void *, void *, pj_ssize_t); } ol_dmx;
static ol_dmx dmx; static pjmedia_transport *srtp_tp(void);
static void dmx_rtp(pjmedia_tp_cb_param *p) { const pj_uint8_t *b = (const pj_uint8_t *)p->pkt;
  if (p->size >= 12 && (b[1] & 0x7f) == OL_P2P_VIDEO_PT) { ol_sfu_video_p2p_rx(p->pkt, (int)p->size); return; }
  if (dmx.rtp_cb2) { pjmedia_tp_cb_param q = *p; q.user_data = dmx.ud; dmx.rtp_cb2(&q); } else if (dmx.rtp_cb) dmx.rtp_cb(dmx.ud, p->pkt, p->size); }
static void dmx_rtcp(void *u, void *pkt, pj_ssize_t n) { (void)u; ol_sfu_video_p2p_rtcp(pkt, (int)n); if (dmx.rtcp_cb) dmx.rtcp_cb(dmx.ud, pkt, n); }
static pj_status_t d_info(pjmedia_transport *t, pjmedia_transport_info *i) { (void)t; return pjmedia_transport_get_info(srtp_tp(), i); }
static pj_status_t d_attach2(pjmedia_transport *t, pjmedia_transport_attach_param *a) { (void)t;
  dmx.ud = a->user_data; dmx.rtp_cb2 = a->rtp_cb2; dmx.rtp_cb = a->rtp_cb; dmx.rtcp_cb = a->rtcp_cb;
  pjmedia_transport_attach_param s = *a; s.user_data = &dmx; s.rtp_cb = NULL; s.rtp_cb2 = &dmx_rtp; s.rtcp_cb = &dmx_rtcp;
  return pjmedia_transport_attach2(srtp_tp(), &s); }
static pj_status_t d_attach(pjmedia_transport *t, void *ud, const pj_sockaddr_t *ra, const pj_sockaddr_t *rc, unsigned al,
  void (*rtp)(void *, void *, pj_ssize_t), void (*rtcp)(void *, void *, pj_ssize_t)) {
  pjmedia_transport_attach_param a; pj_bzero(&a, sizeof a); a.user_data = ud; pj_memcpy(&a.rem_addr, ra, al); pj_memcpy(&a.rem_rtcp, rc, al);
  a.addr_len = al; a.rtp_cb = rtp; a.rtcp_cb = rtcp; return d_attach2(t, &a); }
static void d_detach(pjmedia_transport *t, void *ud) { (void)t; (void)ud; pjmedia_transport_detach(srtp_tp(), &dmx); dmx.rtp_cb2 = NULL; dmx.rtp_cb = NULL; dmx.rtcp_cb = NULL; }
static pj_status_t d_rtp(pjmedia_transport *t, const void *p, pj_size_t n) { (void)t; return pjmedia_transport_send_rtp(srtp_tp(), p, n); }
static pj_status_t d_rtcp(pjmedia_transport *t, const void *p, pj_size_t n) { (void)t; return pjmedia_transport_send_rtcp(srtp_tp(), p, n); }
static pj_status_t d_rtcp2(pjmedia_transport *t, const pj_sockaddr_t *a, unsigned l, const void *p, pj_size_t n) { (void)t; return pjmedia_transport_send_rtcp2(srtp_tp(), a, l, p, n); }
static pj_status_t d_ok(pjmedia_transport *t) { (void)t; return PJ_SUCCESS; }
static pjmedia_transport_op dmx_op = { &d_info, &d_attach, &d_detach, &d_rtp, &d_rtcp, &d_rtcp2, NULL, NULL, NULL, &d_ok, NULL, &d_ok, &d_attach2 };
static int p2p_vrtp(const void *p, int n) { pjmedia_transport *t = srtp_tp(); return t && pjmedia_transport_send_rtp(t, p, n) == PJ_SUCCESS ? 0 : -1; }
static int p2p_vrtcp(const void *p, int n) { pjmedia_transport *t = srtp_tp(); return t && pjmedia_transport_send_rtcp(t, p, n) == PJ_SUCCESS ? 0 : -1; }

static void emit(int ev, const char *t) { if (cb) cb(ev, t, cb_user); }
static void hostport(const char *hp, pj_str_t *host, int *port) {
  const char *c = strrchr(hp, ':'); *host = pj_str((char *)hp); *port = 3478;
  if (c) { host->slen = c - hp; *port = atoi(c + 1); } }

static void pin_opus(pjmedia_stream_info *si) { /* OPUS_PIN identical to ol_sfu.c */
  pjmedia_codec_opus_config oc; if (pjmedia_codec_opus_get_config(&oc) == PJ_SUCCESS) { oc.sample_rate = 48000; oc.channel_cnt = 1;
    oc.frm_ptime = 20; oc.packet_loss = 20; oc.cbr = PJ_FALSE; oc.bit_rate = 64000; pjmedia_codec_opus_set_default_param(&oc, si->param); }
  si->param->setting.plc = 1; si->param->setting.vad = 0; si->param->setting.frm_per_pkt = 1;
  si->jb_init = -1; si->jb_min_pre = 1; si->jb_max_pre = 16; si->jb_max = 50; si->jb_discard_algo = PJMEDIA_JB_DISCARD_PROGRESSIVE; }

static int make_local_sdp(void) {
  pjmedia_endpt *ep = pjsua_get_pjmedia_endpt(); pjmedia_transport_info ti; pjmedia_transport_info_init(&ti);
  pjmedia_transport_get_info(srtp, &ti);
  pjmedia_sock_info si = ti.sock_info;
  if (pjmedia_endpt_create_sdp(ep, pool, 1, &si, &local_sdp) != PJ_SUCCESS) return -1;
  pjmedia_sdp_attr *mux = pjmedia_sdp_attr_create(pool, "rtcp-mux", NULL); pjmedia_sdp_media_add_attr(local_sdp->media[0], mux);
  return pjmedia_transport_encode_sdp(srtp, pool, local_sdp, remote_sdp, 0) == PJ_SUCCESS ? 0 : -2; }

static void send_local(void) { char buf[8000]; int n = pjmedia_sdp_print(local_sdp, buf, sizeof buf - 1);
  if (n <= 0) { emit(3, "sdp print"); return; } buf[n] = 0; emit(1, buf); }

static int start_media(void) { /* both SDPs known; ICE checks begin, stream rides plain RTP over ICE */
  pjmedia_endpt *ep = pjsua_get_pjmedia_endpt();
  if (pjmedia_transport_media_start(srtp, pool, local_sdp, remote_sdp, 0) != PJ_SUCCESS) return -1;
  pjmedia_stream_info si; if (pjmedia_stream_info_from_sdp(&si, pool, ep, local_sdp, remote_sdp, 0) != PJ_SUCCESS) return -2;
  pin_opus(&si);
  pj_bzero(&dmx, sizeof dmx); pj_ansi_strxcpy(dmx.base.name, "oldmx", sizeof dmx.base.name); dmx.base.op = &dmx_op; dmx.base.type = PJMEDIA_TRANSPORT_TYPE_USER;
  if (pjmedia_stream_create(ep, pool, &si, &dmx.base, NULL, &stream) != PJ_SUCCESS) return -3;
  ol_sfu_video_p2p_route(&p2p_vrtp, &p2p_vrtcp); /* video rides this same transport (trying mode until switched) */
  if (pjmedia_stream_start(stream) != PJ_SUCCESS) return -4;
  pjmedia_port *sp; pjmedia_stream_get_port(stream, &sp); if (pjsua_conf_add_port(pool, sp, &slot) != PJ_SUCCESS) return -5;
  if (cfg.test_tone_hz > 0) {
    pjmedia_tonegen_create(pool, 48000, 1, 960, 16, PJMEDIA_TONEGEN_LOOP, &tone);
    pjmedia_tone_desc d; pj_bzero(&d, sizeof d); d.freq1 = (short)cfg.test_tone_hz; d.on_msec = 30000; d.volume = 16000;
    pjmedia_tonegen_play(tone, 1, &d, PJMEDIA_TONEGEN_LOOP); pjsua_conf_add_port(pool, tone, &tone_slot); pjsua_conf_connect(tone_slot, slot);
    pjsua_conf_connect(slot, 0);
  } else { pjsua_conf_connect(0, slot); pjsua_conf_connect(slot, 0);
    if (!live) { pjsua_conf_adjust_tx_level(slot, 0.0f); pjsua_conf_adjust_rx_level(slot, 0.0f); } }
  started = 1; return 0; }

/* Switch audio onto this leg (caller drops the SFU leg after). Until then the stream runs (RTP both ways keeps ICE
   and stats alive: VAD off, so silent Opus frames still flow) at level 0, so nothing is heard or sent twice. */
int ol_p2p_activate(int on) { live = on ? 1 : 0; if (slot < 0 || cfg.test_tone_hz > 0) return 0;
  float g = on ? 1.0f : 0.0f; pjsua_conf_adjust_tx_level(slot, g); pjsua_conf_adjust_rx_level(slot, g); return 0; }

static void on_ice_complete(pjmedia_transport *tp, pj_ice_strans_op op, pj_status_t st) {
  (void)tp;
  if (op == PJ_ICE_STRANS_OP_INIT) {
    if (st != PJ_SUCCESS) { emit(3, "gather"); return; }
    gathered = 1;
    if (cfg.offerer) { if (pjmedia_transport_media_create(srtp, pool, 0, NULL, 0) || make_local_sdp()) { emit(3, "offer"); return; } send_local(); }
    else if (remote_sdp) { if (pjmedia_transport_media_create(srtp, pool, 0, remote_sdp, 0) || make_local_sdp()) { emit(3, "answer"); return; }
      send_local(); if (start_media()) emit(3, "media"); }
  } else if (op == PJ_ICE_STRANS_OP_NEGOTIATION) emit(st == PJ_SUCCESS ? 2 : 3, st == PJ_SUCCESS ? "ice" : "ice failed");
}

static int create_transports(void) {
  pjmedia_endpt *ep = pjsua_get_pjmedia_endpt(); if (!ep) return -1;
  pool = pjsua_pool_create("olp2p", 4000, 4000);
  pj_ice_strans_cfg ic; pj_ice_strans_cfg_default(&ic);
  pj_stun_config_init(&ic.stun_cfg, pjsua_get_pool_factory(), 0, pjmedia_endpt_get_ioqueue(ep), pjsip_endpt_get_timer_heap(pjsua_get_pjsip_endpt()));
  ic.af = pj_AF_INET();
  int port;
  if (cfg.relay_only) { ic.stun.max_host_cands = 0; ic.stun_tp_cnt = 0; }               /* tgcalls :596-601 */
  else if (cfg.stun && *cfg.stun) hostport(s_stun, &ic.stun.server, &port), ic.stun.port = (pj_uint16_t)port; /* srflx, :576 */
  if (cfg.turn && *cfg.turn) {                                                             /* relay fallback, :610-626 */
    hostport(s_turn, &ic.turn.server, &port); ic.turn.port = (pj_uint16_t)port;
    ic.turn.conn_type = cfg.turn_tcp ? PJ_TURN_TP_TCP : PJ_TURN_TP_UDP;
    ic.turn.auth_cred.type = PJ_STUN_AUTH_CRED_STATIC;
    ic.turn.auth_cred.data.static_cred.username = pj_str(s_tu);
    ic.turn.auth_cred.data.static_cred.data_type = PJ_STUN_PASSWD_PLAIN;
    ic.turn.auth_cred.data.static_cred.data = pj_str(s_tp);
  }
  pjmedia_ice_cb icb; pj_bzero(&icb, sizeof icb); icb.on_ice_complete = &on_ice_complete;
  if (pjmedia_ice_create3(ep, "olp2p", 1 /* rtcp-mux: one component */, &ic, &icb, 0, NULL, &ice) != PJ_SUCCESS) return -2;
  srtp = ice; /* no SRTP wrapper: media rides the ICE transport as plain RTP */
  return 0; }

int ol_p2p_begin(const ol_p2p_cfg *c, ol_p2p_cb f, void *user) {
  ol_p2p_stop(); cfg = *c; cb = f; cb_user = user;
  #define CP(d, s) do { d[0] = 0; if (s) { strncpy(d, s, sizeof d - 1); d[sizeof d - 1] = 0; } } while (0)
  CP(s_stun, c->stun); CP(s_turn, c->turn); CP(s_tu, c->turn_user); CP(s_tp, c->turn_pass);
  cfg.stun = s_stun; cfg.turn = s_turn; cfg.turn_user = s_tu; cfg.turn_pass = s_tp;
  return create_transports(); }

int ol_p2p_remote(const char *text) {
  if (!pool) return -1; pjmedia_sdp_session *s; size_t n = strlen(text);
  char *b = pj_pool_alloc(pool, n + 1); memcpy(b, text, n + 1);
  if (pjmedia_sdp_parse(pool, b, n, &s) != PJ_SUCCESS) return -2;
  remote_sdp = s;
  if (cfg.offerer) return local_sdp ? start_media() : -3;          /* the answer */
  if (gathered) { if (pjmedia_transport_media_create(srtp, pool, 0, remote_sdp, 0) || make_local_sdp()) return -4;
    send_local(); return start_media(); }
  return 0; /* answered from on_ice_complete once gathering finishes */ }

int ol_p2p_restart(void) { ol_p2p_cfg c = cfg; ol_p2p_cb f = cb; void *u = cb_user; return ol_p2p_begin(&c, f, u); }
int ol_p2p_rx_level(void) { unsigned tx = 0, rx = 0; if (slot < 0) return -1; pjsua_conf_get_signal_level(slot, &tx, &rx); return (int)rx; }
int ol_p2p_stats(unsigned *rp, unsigned *rl, unsigned *tp) { pjmedia_rtcp_stat st; if (!stream || pjmedia_stream_get_stat(stream, &st) != PJ_SUCCESS) return -1;
  *rp = st.rx.pkt; *rl = st.rx.loss; *tp = st.tx.pkt; return 0; }
int ol_p2p_set_mute(int m) { if (slot < 0) return -1; return m ? (int)pjsua_conf_disconnect(0, slot) : (int)pjsua_conf_connect(0, slot); }
static pjmedia_transport *srtp_tp(void) { return srtp; }
int ol_p2p_video_live(int on) { return ol_sfu_video_p2p_live(on); }
void ol_p2p_video_stats(unsigned *rx, unsigned *tx) { ol_sfu_video_p2p_stats(rx, tx); }
void ol_p2p_stop(void) {
  ol_sfu_video_p2p_route(NULL, NULL); /* video back on the server route */
  if (tone_slot >= 0) { pjsua_conf_remove_port(tone_slot); tone_slot = -1; } if (tone) { pjmedia_port_destroy(tone); tone = NULL; }
  if (slot >= 0) { pjsua_conf_remove_port(slot); slot = -1; }
  if (stream) { pjmedia_stream_destroy(stream); stream = NULL; }
  if (srtp) { if (started) pjmedia_transport_media_stop(srtp); pjmedia_transport_close(srtp); srtp = NULL; ice = NULL; }
  if (pool) { pj_pool_release(pool); pool = NULL; }
  local_sdp = remote_sdp = NULL; gathered = started = live = 0; }
