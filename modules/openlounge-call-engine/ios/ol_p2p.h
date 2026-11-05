// Phone-to-phone P2P audio leg: pjnath ICE (host/srflx/relay candidates), plain RTP (NO encryption), SDP over call:p2p.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
/* ev: 1 = local SDP ready (send it to the peer as call:p2p {sdp}), 2 = ICE nominated + media running,
       3 = failed (caller keeps / falls back to the SFU leg). text = SDP for ev 1, reason otherwise. */
typedef void (*ol_p2p_cb)(int ev, const char *text, void *user);
typedef struct {
  int offerer;               /* caller = ICE controlling, sends the offer */
  const char *stun;          /* "host:port", our coturn */
  const char *turn;          /* "host:port", our coturn relay fallback */
  const char *turn_user, *turn_pass;
  int turn_tcp;              /* 1 = TURN over TCP (UDP-blocked networks) */
  int relay_only;            /* 1 = no host/srflx candidates (tgcalls !enableP2P) */
  int test_tone_hz;          /* CI harness: tone instead of mic */
} ol_p2p_cfg;
int ol_p2p_begin(const ol_p2p_cfg *cfg, ol_p2p_cb cb, void *user);
int ol_p2p_remote(const char *sdp);   /* callee: the offer; caller: the answer */
int ol_p2p_restart(void);             /* network changed: tear down, regather, new offer (offerer) */
int ol_p2p_rx_level(void);
int ol_p2p_stats(unsigned *rx_pkt, unsigned *rx_lost, unsigned *tx_pkt);
int ol_p2p_set_mute(int muted);
int ol_p2p_activate(int on);         /* 1 = put this leg on mic/speaker (after it is connected both ways) */
int ol_p2p_video_live(int on);       /* 1 = video onto the direct leg (after both ways proven), 0 = server route */
void ol_p2p_video_stats(unsigned *rx, unsigned *tx); /* H.264 packets on the direct leg */
void ol_p2p_stop(void);
#ifdef __cplusplus
}
#endif
