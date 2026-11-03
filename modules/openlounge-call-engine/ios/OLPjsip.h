// C shim so Swift never imports pjproject headers directly.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int ol_pjsip_start(int jb_min_pre, int jb_max_pre, int jb_max); // SRTP SDES mandatory account, no snd dev
int ol_pjsip_open_sound(void);                                    // only from CallKit didActivate
void ol_pjsip_close_sound(void);
void ol_pjsip_teardown(void);                                     // hangup all + release sound
int ol_pjsip_video_quickhd(void);                                 // H.264 1080p 2.5 Mbps start burst
int ol_pjsip_video_steady(void);                                  // H.264 720p 1.2 Mbps
// Video spec v2 leg (ol_sfu_video.c): own transport/SRTP key, 3 simulcast SSRCs, Annex-B AU per layer from VideoToolbox
int ol_sfu_video_send(int layer, const unsigned char *annexb, int len, unsigned ts90k, int key);
#ifdef __cplusplus
}
#endif
