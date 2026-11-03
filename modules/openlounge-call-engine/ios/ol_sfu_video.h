// Phone -> mediasoup PlainTransport video leg (no SIP/ICE). See ol_sfu_video.c.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*ol_video_sink_cb)(void *user, const unsigned char *annexb, int len, int key, unsigned ts90k);
void ol_sfu_video_set_sink(ol_video_sink_cb cb, void *user);
int ol_sfu_video_start(const char *ip, int port, const char *tx_key_b64, const char *rx_key_b64, const unsigned *ssrcs, int nlayers, int pt);
int ol_sfu_video_send(int layer, const unsigned char *annexb, int len, unsigned ts90k, int key);
int ol_sfu_video_stats(unsigned *rx_pkt, unsigned *rx_au, unsigned *rx_key, unsigned *rx_gap, unsigned *tx_pkt, unsigned *tx_au, unsigned *tx_key);
void ol_sfu_video_stop(void);
#ifdef __cplusplus
}
#endif
