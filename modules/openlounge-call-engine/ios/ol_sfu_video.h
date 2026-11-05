// Phone -> mediasoup PlainTransport video leg (no SIP/ICE). See ol_sfu_video.c.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*ol_video_sink_cb)(void *user, const unsigned char *annexb, int len, int key, unsigned ts90k);
void ol_sfu_video_set_sink(ol_video_sink_cb cb, void *user);
int ol_sfu_video_start(const char *ip, int port, const char *tx_key_b64, const char *rx_key_b64, const unsigned *ssrcs, int nlayers, int pt);
int ol_sfu_video_start_direct(const unsigned *ssrcs, int nlayers, int pt);
int ol_sfu_video_send(int layer, const unsigned char *annexb, int len, unsigned ts90k, int key);
int ol_sfu_video_stats(unsigned *rx_pkt, unsigned *rx_au, unsigned *rx_key, unsigned *rx_gap, unsigned *tx_pkt, unsigned *tx_au, unsigned *tx_key);
void ol_sfu_video_stop(void);
/* Keyframe request from the SFU (RTCP PLI/FIR) for simulcast layer `layer`: platform forces an IDR on that encoder. */
typedef void (*ol_video_keyframe_cb)(void *user, int layer);
void ol_sfu_video_set_keyframe_cb(ol_video_keyframe_cb cb, void *user);
unsigned ol_sfu_video_take_keyreq(void);
void ol_sfu_video_fb_stats(unsigned *pli_rx, unsigned *pli_tx, unsigned *tx_drop);
/* Phone-to-phone route (bundled with the P2P audio transport, tgcalls v2). */
void ol_sfu_video_p2p_route(int (*rtp)(const void *, int), int (*rtcp)(const void *, int));
void ol_sfu_video_p2p_rx(void *pkt, int len);
void ol_sfu_video_p2p_rtcp(void *pkt, int len);
int ol_sfu_video_p2p_live(int on);
void ol_sfu_video_p2p_stats(unsigned *rx, unsigned *tx);
#ifdef __cplusplus
}
#endif
