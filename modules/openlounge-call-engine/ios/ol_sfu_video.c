/* Open Lounge engine: phone -> mediasoup PlainTransport VIDEO leg (Video spec v2, PLAN §14). Own transport per
   PEER_TRANSPORTS ("video"), own SRTP SDES key (AES_CM_128_HMAC_SHA1_80), own SSRCs (never the audio SSRC).
   Send: platform HW encoder (VideoToolbox / MediaCodec) Annex-B access units per simulcast layer -> RFC 6184
   (single NAL + FU-A) -> SRTP -> UDP. Receive: SRTP -> depacketize (single/FU-A/STAP-A) -> Annex-B AU -> sink
   (platform HW decoder). Shared by iOS and Android shims. pjproject has no AV1 codec/packetizer (2.17), so the
   RTP layer here is H.264 only; AV1 is negotiated only when both ends report HW AV1 (none in CI). */
#include <pjsua-lib/pjsua.h>
#include <pjlib-util/base64.h>
#include <string.h>
#include "ol_sfu_video.h"
#define OL_MTU 1100
#define OL_AU_MAX (1 << 21)
/* Callers (VideoToolbox/MediaCodec callback threads, XCTest) may be foreign to pjlib: register before pj_mutex/pjmedia use. */
#define OLV_REG() static __thread pj_thread_desc olv_d_; pj_thread_t *olv_t_; if (!pj_thread_is_registered()) pj_thread_register("olv", olv_d_, &olv_t_)
static pj_pool_t *vpool; static pjmedia_transport *vudp, *vsrtp; static pj_mutex_t *vmx;
static unsigned vssrc[3], vnl; static pj_uint16_t vseq[3]; static int vpt;
static pj_uint8_t *au; static int aulen, auloss, have, auKey; static pj_uint16_t lastseq; static pj_uint32_t rxssrc;
static ol_video_sink_cb sink; static void *sink_user;
static ol_video_keyframe_cb kfcb; static void *kf_user; static pj_mutex_t *txmx; static pj_timestamp last_pli;
static unsigned st_pli_rx, st_pli_tx, st_tx_drop; static volatile unsigned keyreq; static int needKey;
static void send_pli(pj_uint32_t media);
static unsigned st_rx_pkt, st_rx_au, st_rx_key, st_rx_gap, st_tx_pkt, st_tx_au[3], st_tx_key[3];
static pj_sockaddr vrem;
/* Phone-to-phone route (ol_p2p.c): tgcalls 38dcea1 v2 runs video on the same RTP transport as audio
   (InstanceV2Impl.cpp:154/335 audio, :460/:760 video SetRtpTransport(rtpTransport), one transport from :1135) with one
   outgoing H.264 stream (:458, :479), no simulcast. So: top layer only, PT 102, same ICE+SRTP as the P2P audio.
   mode 1 = trying (top layer sent on both routes; P2P rx counted, not shown), 2 = live (P2P only; SFU send stopped). */
static int (*p2p_rtp)(const void *, int), (*p2p_rtcp)(const void *, int); static volatile int p2pmode;
static unsigned st_p2p_rx, st_p2p_tx; static pj_timestamp p2p_last_rx;
static volatile int vdirect; /* phone<->phone single path: no SFU socket at all, video only on the direct ICE link */

static int b64key(const char *b64, char *out30) { int n = 30; pj_str_t s = pj_str((char *)b64);
  return pj_base64_decode(&s, (pj_uint8_t *)out30, &n) == PJ_SUCCESS && n == 30 ? 0 : -1; }
static void au_put(const pj_uint8_t *p, int l, int sc) { if (aulen + l + 4 > OL_AU_MAX) { auloss = 1; return; }
  if (sc) { au[aulen++] = 0; au[aulen++] = 0; au[aulen++] = 0; au[aulen++] = 1; if ((p[0] & 0x1f) == 5) auKey = 1; }
  memcpy(au + aulen, p, l); aulen += l; }
static void rx_rtp(pj_uint8_t *pkt, int len);
static void on_rtp(pjmedia_tp_cb_param *prm) {
  if (p2pmode == 2) { pj_timestamp now; pj_get_timestamp(&now); /* live on P2P: SFU video only if P2P went quiet > 1 s */
    if (p2p_last_rx.u64 && pj_elapsed_msec(&p2p_last_rx, &now) < 1000) return; }
  rx_rtp((pj_uint8_t *)prm->pkt, (int)prm->size); }
static void rx_rtp(pj_uint8_t *pkt, int len) {
  if (len < 12 || (pkt[1] & 0x7f) >= 72 && (pkt[1] & 0x7f) <= 76) return; /* rtcp-mux */
  int hl = 12 + 4 * (pkt[0] & 0x0f); if (pkt[0] & 0x10) { if (len < hl + 4) return; hl += 4 + 4 * (pkt[hl + 2] << 8 | pkt[hl + 3]); }
  if (pkt[0] & 0x20) len -= pkt[len - 1]; if (hl >= len) return;
  pj_mutex_lock(vmx); st_rx_pkt++;
  pj_uint16_t seq = (pj_uint16_t)(pkt[2] << 8 | pkt[3]); pj_uint32_t ss = (pj_uint32_t)pkt[8] << 24 | pkt[9] << 16 | pkt[10] << 8 | pkt[11];
  if (have && ss == rxssrc && (pj_uint16_t)(lastseq + 1) != seq) { auloss = 1; st_rx_gap++; needKey = 1; }
  if (!have || ss != rxssrc) needKey = 1;
  if (ss != rxssrc) { aulen = 0; auloss = 0; auKey = 0; } /* SFU layer switch: new SSRC never (mediasoup rewrites), but be safe */
  lastseq = seq; have = 1; rxssrc = ss;
  const pj_uint8_t *p = pkt + hl; int l = len - hl, t = p[0] & 0x1f;
  if (t == 28 && l > 2) { if (p[1] & 0x80) { pj_uint8_t h = (p[0] & 0xe0) | (p[1] & 0x1f); au_put(&h, 1, 1); } au_put(p + 2, l - 2, 0); }
  else if (t == 24) { int o = 1; while (o + 2 < l) { int sz = p[o] << 8 | p[o + 1]; o += 2; if (o + sz > l) break; au_put(p + o, sz, 1); o += sz; } }
  else au_put(p, l, 1);
  if (pkt[1] & 0x80) { if (!auloss && aulen && auKey) needKey = 0;
    if (!auloss && aulen) { st_rx_au++; if (auKey) st_rx_key++;
      pj_uint32_t ts = (pj_uint32_t)pkt[4] << 24 | pkt[5] << 16 | pkt[6] << 8 | pkt[7]; if (sink) sink(sink_user, au, aulen, auKey, ts); }
    aulen = 0; auloss = 0; auKey = 0; }
  if (needKey) send_pli(ss); /* until a complete keyframe decodes: start, freeze, gap (rate-limited) */
  pj_mutex_unlock(vmx);
}
/* RFC 4585 PLI to the SFU for the SSRC we receive: on first packet and on any gap (rate-limited 300 ms), so the
   sender's encoder (via mediasoup) produces an IDR now instead of the decoder waiting for the next periodic keyframe. */
static void send_pli(pj_uint32_t media) {
  pj_timestamp now; pj_get_timestamp(&now);
  if (last_pli.u64 && pj_elapsed_msec(&last_pli, &now) < 300) return; last_pli = now;
  pj_uint8_t b[12] = { 0x81, 206, 0, 2 }; unsigned s = vssrc[0];
  b[4] = s >> 24; b[5] = s >> 16; b[6] = s >> 8; b[7] = (pj_uint8_t)s; b[8] = media >> 24; b[9] = media >> 16; b[10] = media >> 8; b[11] = (pj_uint8_t)media;
  if (p2pmode == 2 && p2p_rtcp) { if (p2p_rtcp(b, sizeof b) == 0) st_pli_tx++; return; }
  if (vsrtp && pjmedia_transport_send_rtcp(vsrtp, b, sizeof b) == PJ_SUCCESS) st_pli_tx++; }
/* PLI (PSFB fmt 1) / FIR (PSFB fmt 4) from mediasoup (consumer join, layer switch, loss) -> force an IDR on that layer. */
static void on_rtcp(void *u, void *p, pj_ssize_t n) { (void)u; const pj_uint8_t *b = (const pj_uint8_t *)p; int o = 0;
  while (o + 4 <= n) { int len = 4 * ((b[o + 2] << 8 | b[o + 3]) + 1); if (o + len > n) break;
    int pt = b[o + 1], fmt = b[o] & 0x1f;
    if (pt == 206 && (fmt == 1 || fmt == 4) && len >= 12) {
      pj_uint32_t m = fmt == 1 ? ((pj_uint32_t)b[o + 8] << 24 | b[o + 9] << 16 | b[o + 10] << 8 | b[o + 11])
                               : (len >= 20 ? ((pj_uint32_t)b[o + 12] << 24 | b[o + 13] << 16 | b[o + 14] << 8 | b[o + 15]) : 0);
      for (unsigned i = 0; i < vnl; i++) if (vssrc[i] == m || m == 0) { st_pli_rx++; keyreq |= 1u << i; if (kfcb) kfcb(kf_user, (int)i); } }
    o += len; } }

void ol_sfu_video_set_sink(ol_video_sink_cb cb, void *user) { OLV_REG(); sink = cb; sink_user = user; }

int ol_sfu_video_start(const char *ip, int port, const char *tx_b64, const char *rx_b64, const unsigned *ssrcs, int nlayers, int pt) { OLV_REG();
  pjmedia_endpt *ep = pjsua_get_pjmedia_endpt(); if (!ep) return -1; if (nlayers < 1 || nlayers > 3) return -12;
  ol_sfu_video_stop();
  vpool = pjsua_pool_create("olsfuv", 4000, 4000); pj_mutex_create_simple(vpool, "olv", &vmx); pj_mutex_create_simple(vpool, "olvt", &txmx); last_pli.u64 = 0; keyreq = 0; needKey = 1; st_pli_rx = st_pli_tx = st_tx_drop = 0;
  au = (pj_uint8_t *)pj_pool_alloc(vpool, OL_AU_MAX);
  pj_str_t any = pj_str("0.0.0.0");
  { int base = 46000 + (int)(pj_rand() % 4000) * 2, ok = 0;
    for (int i = 0; i < 64 && !ok; i++) ok = pjmedia_transport_udp_create3(ep, pj_AF_INET(), "olsfuv", &any, base + 2 * i, 0, &vudp) == PJ_SUCCESS;
    if (!ok) return -2; }
  { pjmedia_transport_info ti; pjmedia_transport_info_init(&ti); pjmedia_transport_get_info(vudp, &ti);
    int v = 4 << 20; pj_sock_setsockopt(ti.sock_info.rtp_sock, pj_SOL_SOCKET(), pj_SO_RCVBUF(), &v, sizeof v);
    v = 4 << 20; pj_sock_setsockopt(ti.sock_info.rtp_sock, pj_SOL_SOCKET(), pj_SO_SNDBUF(), &v, sizeof v); }
  pjmedia_srtp_setting ss; pjmedia_srtp_setting_default(&ss); ss.use = PJMEDIA_SRTP_MANDATORY; ss.close_member_tp = PJ_TRUE;
  if (pjmedia_transport_srtp_create(ep, vudp, &ss, &vsrtp) != PJ_SUCCESS) return -3;
  static char txk[30], rxk[30]; if (b64key(tx_b64, txk) || b64key(rx_b64, rxk)) return -4;
  pjmedia_srtp_crypto tx, rx; pj_bzero(&tx, sizeof tx); pj_bzero(&rx, sizeof rx);
  tx.name = rx.name = pj_str("AES_CM_128_HMAC_SHA1_80"); tx.key = pj_str(txk); tx.key.slen = 30; rx.key = pj_str(rxk); rx.key.slen = 30;
  if (pjmedia_transport_srtp_start(vsrtp, &tx, &rx) != PJ_SUCCESS) return -5;
  pj_str_t rip = pj_str((char *)ip); if (pj_sockaddr_init(pj_AF_INET(), &vrem, &rip, (pj_uint16_t)port) != PJ_SUCCESS) return -7;
  pjmedia_transport_attach_param ap; pj_bzero(&ap, sizeof ap);
  ap.user_data = NULL; pj_memcpy(&ap.rem_addr, &vrem, sizeof vrem); pj_memcpy(&ap.rem_rtcp, &vrem, sizeof vrem); ap.addr_len = pj_sockaddr_get_len(&vrem);
  ap.rtp_cb2 = &on_rtp; ap.rtcp_cb = &on_rtcp;
  if (pjmedia_transport_attach2(vsrtp, &ap) != PJ_SUCCESS) return -8;
  if (pjmedia_transport_media_start(vudp, vpool, NULL, NULL, 0) != PJ_SUCCESS) return -11;
  vnl = (unsigned)nlayers; vpt = pt; for (int i = 0; i < nlayers; i++) { vssrc[i] = ssrcs[i]; vseq[i] = (pj_uint16_t)(ssrcs[i] & 0xffff); }
  st_rx_pkt = st_rx_au = st_rx_key = st_rx_gap = st_tx_pkt = 0; memset(st_tx_au, 0, sizeof st_tx_au); memset(st_tx_key, 0, sizeof st_tx_key);
  have = 0; aulen = 0; auloss = 0; auKey = 0; rxssrc = 0;
  /* mediasoup PlainTransport is comedia: it learns our address from our first packet. A receive-only leg (no local
     encoder yet) would never latch, so send an empty RTCP RR (SRTCP) right away to open the SFU->phone path. */
  { pj_uint8_t rr[8] = { 0x80, 201, 0, 1 }; unsigned s = vssrc[0]; rr[4] = s >> 24; rr[5] = s >> 16; rr[6] = s >> 8; rr[7] = (pj_uint8_t)s;
    pjmedia_transport_send_rtcp(vsrtp, rr, sizeof rr); }
  return 0;
}
/* Phone <-> phone: the one path is the direct ICE link (ol_p2p.c). No UDP/SRTP/SFU transport is created. */
int ol_sfu_video_start_direct(const unsigned *ssrcs, int nlayers, int pt) { OLV_REG();
  if (nlayers < 1 || nlayers > 3) return -12;
  ol_sfu_video_stop();
  vpool = pjsua_pool_create("olsfuv", 4000, 4000); if (!vpool) return -1;
  pj_mutex_create_simple(vpool, "olv", &vmx); pj_mutex_create_simple(vpool, "olvt", &txmx); last_pli.u64 = 0; keyreq = 0; needKey = 1; st_pli_rx = st_pli_tx = st_tx_drop = 0;
  au = (pj_uint8_t *)pj_pool_alloc(vpool, OL_AU_MAX);
  vnl = (unsigned)nlayers; vpt = pt; for (int i = 0; i < nlayers; i++) { vssrc[i] = ssrcs[i]; vseq[i] = (pj_uint16_t)(ssrcs[i] & 0xffff); }
  st_rx_pkt = st_rx_au = st_rx_key = st_rx_gap = st_tx_pkt = 0; memset(st_tx_au, 0, sizeof st_tx_au); memset(st_tx_key, 0, sizeof st_tx_key);
  have = 0; aulen = 0; auloss = 0; auKey = 0; rxssrc = 0; vdirect = 1;
  return 0;
}
static int vpkt(int layer, pj_uint32_t ts, int marker, const pj_uint8_t *pl, int pll, const pj_uint8_t *pre, int prel) {
  pj_uint8_t o[1500]; unsigned s = vssrc[layer];
  o[0] = 0x80; o[1] = (pj_uint8_t)((marker ? 0x80 : 0) | vpt); o[2] = vseq[layer] >> 8; o[3] = (pj_uint8_t)vseq[layer]; o[4] = ts >> 24; o[5] = ts >> 16; o[6] = ts >> 8; o[7] = (pj_uint8_t)ts;
  o[8] = s >> 24; o[9] = s >> 16; o[10] = s >> 8; o[11] = (pj_uint8_t)s;
  memcpy(o + 12, pre, prel); memcpy(o + 12 + prel, pl, pll); vseq[layer]++; st_tx_pkt++;
  if (p2pmode && p2p_rtp && layer == (int)vnl - 1 && p2p_rtp(o, 12 + prel + pll) == 0) st_p2p_tx++;
  if (p2pmode == 2 || vdirect) return 0; /* server video route dropped / never exists on the direct path */
  /* Non-blocking UDP: a keyframe burst can fill the socket buffer (EAGAIN/ENOBUFS). Retry briefly instead of dropping the rest of the AU. */
  for (int t = 0; t < 50; t++) { pj_status_t st = pjmedia_transport_send_rtp(vsrtp, o, 12 + prel + pll); if (st == PJ_SUCCESS) return 0; pj_thread_sleep(1); }
  st_tx_drop++; return 0;
}
/* One Annex-B access unit from the layer's HW encoder (SPS/PPS prepended on keyframes) at a 90 kHz timestamp. */
static int send_locked(int layer, const unsigned char *a, int len, unsigned ts90k, int key);
/* The 3 layer encoders call back on different threads: libsrtp contexts and per-layer seq are not thread-safe, so serialize. */
int ol_sfu_video_send(int layer, const unsigned char *a, int len, unsigned ts90k, int key) { OLV_REG();
  if ((!vsrtp && !vdirect) || !txmx || layer < 0 || layer >= (int)vnl) return -1;
  pj_mutex_lock(txmx); int r = send_locked(layer, a, len, ts90k, key); pj_mutex_unlock(txmx); return r; }
static int send_locked(int layer, const unsigned char *a, int len, unsigned ts90k, int key) {
  int cnt = 0; const pj_uint8_t *nal[256]; int scpos[257];
  for (int i = 0; i + 3 <= len && cnt < 256; ) {
    int sc = (a[i] == 0 && a[i + 1] == 0) ? (a[i + 2] == 1 ? 3 : (i + 4 <= len && a[i + 2] == 0 && a[i + 3] == 1 ? 4 : 0)) : 0;
    if (sc) { scpos[cnt] = i; nal[cnt++] = a + i + sc; i += sc; } else i++; }
  if (!cnt) return -2; scpos[cnt] = len;
  for (int k = 0; k < cnt; k++) {
    const pj_uint8_t *p = nal[k]; int l = (int)(a + scpos[k + 1] - p), last = k == cnt - 1; if (l <= 0) continue;
    if (l <= OL_MTU) { if (vpkt(layer, ts90k, last, p, l, NULL, 0)) return -100; continue; }
    pj_uint8_t hdr = p[0]; const pj_uint8_t *q = p + 1; int rem = l - 1, first = 1;
    while (rem > 0) { int ch = rem > OL_MTU ? OL_MTU : rem; pj_uint8_t fu[2] = { (pj_uint8_t)((hdr & 0xe0) | 28), (pj_uint8_t)((hdr & 0x1f) | (first ? 0x80 : 0) | (ch == rem ? 0x40 : 0)) };
      if (vpkt(layer, ts90k, last && ch == rem, q, ch, fu, 2)) return -100; q += ch; rem -= ch; first = 0; }
  }
  st_tx_au[layer]++; if (key) st_tx_key[layer]++;
  return 0;
}
int ol_sfu_video_stats(unsigned *rx_pkt, unsigned *rx_au, unsigned *rx_key, unsigned *rx_gap, unsigned *tx_pkt, unsigned *tx_au, unsigned *tx_key) { OLV_REG();
  *rx_pkt = st_rx_pkt; *rx_au = st_rx_au; *rx_key = st_rx_key; *rx_gap = st_rx_gap; *tx_pkt = st_tx_pkt;
  for (int i = 0; i < 3; i++) { tx_au[i] = st_tx_au[i]; tx_key[i] = st_tx_key[i]; } return 0; }
void ol_sfu_video_stop(void) { OLV_REG();
  if (vsrtp) { pjmedia_transport_detach(vsrtp, NULL); pjmedia_transport_close(vsrtp); vsrtp = NULL; vudp = NULL; }
  if (txmx) { pj_mutex_lock(txmx); pj_mutex_unlock(txmx); pj_mutex_destroy(txmx); txmx = NULL; }
  if (vmx) { pj_mutex_destroy(vmx); vmx = NULL; }
  if (vpool) { pj_pool_release(vpool); vpool = NULL; }
  vnl = 0; vdirect = 0;
}
void ol_sfu_video_set_keyframe_cb(ol_video_keyframe_cb cb, void *user) { OLV_REG(); kfcb = cb; kf_user = user; }
void ol_sfu_video_fb_stats(unsigned *pli_rx, unsigned *pli_tx, unsigned *tx_drop) { *pli_rx = st_pli_rx; *pli_tx = st_pli_tx; *tx_drop = st_tx_drop; }
/* Polling alternative to the callback: layers the SFU asked to refresh since the last call (bitmask). */
unsigned ol_sfu_video_take_keyreq(void) { return __atomic_exchange_n(&keyreq, 0u, __ATOMIC_SEQ_CST); }

/* ---- phone-to-phone route hooks (called by ol_p2p.c) ---- */
void ol_sfu_video_p2p_route(int (*rtp)(const void *, int), int (*rtcp)(const void *, int)) {
  p2pmode = 0; p2p_rtp = rtp; p2p_rtcp = rtcp; st_p2p_rx = st_p2p_tx = 0; p2p_last_rx.u64 = 0; if (rtp) p2pmode = 1; }
/* PT 102 packets demuxed off the P2P audio transport (already SRTP-decrypted). */
void ol_sfu_video_p2p_rx(void *pkt, int len) { OLV_REG(); if (!vmx) return;
  pj_mutex_lock(vmx); st_p2p_rx++; pj_get_timestamp(&p2p_last_rx); pj_mutex_unlock(vmx);
  if (p2pmode == 2) rx_rtp((pj_uint8_t *)pkt, len); }
void ol_sfu_video_p2p_rtcp(void *pkt, int len) { if (vnl) on_rtcp(NULL, pkt, len); }
/* 1 = switch video onto P2P (caller checks both directions first); 0 = back to the server route. */
int ol_sfu_video_p2p_live(int on) { OLV_REG(); if (!p2p_rtp) return -1;
  if (vmx) pj_mutex_lock(vmx); p2pmode = on ? 2 : 1; needKey = 1; last_pli.u64 = 0; if (vmx) pj_mutex_unlock(vmx);
  keyreq |= vnl ? 1u << (vnl - 1) : 0; /* fresh IDR on the new route */ return 0; }
void ol_sfu_video_p2p_stats(unsigned *rx, unsigned *tx) { *rx = st_p2p_rx; *tx = st_p2p_tx; }
