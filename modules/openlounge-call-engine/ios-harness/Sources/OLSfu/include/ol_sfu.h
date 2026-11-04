// Phone -> mediasoup PlainTransport audio leg (no SIP/ICE). See ol_sfu.c.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int ol_sfu_audio_start(const char *ip, int port, const char *tx_key_b64, const char *rx_key_b64, unsigned ssrc, int tx_pt, int rx_pt, int test_tone_hz);
int ol_sfu_rx_level(void);
int ol_sfu_diag(int *rb0, int *rb1, unsigned *jb_disc, unsigned *jb_lost, unsigned *jb_empty, unsigned *jb_avg_ms, unsigned *rx_discard);
int ol_sfu_stats(unsigned *rx_pkt, unsigned *rx_lost, unsigned *tx_pkt);
int ol_sfu_local_port(void);
void ol_sfu_stop(void);
int ol_sfu_set_mute(int muted);
#ifdef __cplusplus
}
#endif
