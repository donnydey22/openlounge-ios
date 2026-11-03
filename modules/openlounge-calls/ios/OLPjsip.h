// C shim so Swift never imports pjproject headers directly.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int ol_pjsip_start(int jb_min_pre, int jb_max_pre, int jb_max); // SRTP SDES mandatory account, no snd dev
int ol_pjsip_open_sound(void);                                    // only from CallKit didActivate
void ol_pjsip_close_sound(void);
void ol_pjsip_teardown(void);                                     // hangup all + release sound
#ifdef __cplusplus
}
#endif
