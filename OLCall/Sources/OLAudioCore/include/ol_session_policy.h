/* ol_session_policy.h - AVAudioSession activation policy for Open Lounge calls.
 *
 * A platform-free state machine. OLCallAudioDevice (Swift) is the only caller:
 * it performs the actions this policy returns (setActive, enable/disable the
 * call's audio device) and feeds back the results. Every failure keeps the
 * verbatim NSError code so the call log shows exactly what iOS reported.
 */
#ifndef OL_SESSION_POLICY_H
#define OL_SESSION_POLICY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OL_FOURCC(a, b, c, d) ((int32_t)(((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d)))
/* AVAudioSessionErrorCode values (AVFAudio, FourCC) */
#define OL_AVS_ERR_INSUFFICIENT_PRIORITY OL_FOURCC('!', 'p', 'r', 'i')
#define OL_AVS_ERR_CANNOT_INTERRUPT_OTHERS OL_FOURCC('!', 'i', 'n', 't')
#define OL_AVS_ERR_IS_BUSY OL_FOURCC('!', 'a', 'c', 't')
#define OL_AVS_ERR_CANNOT_START_PLAYING OL_FOURCC('!', 'p', 'l', 'a')
#define OL_AVS_ERR_CANNOT_START_RECORDING OL_FOURCC('!', 'r', 'e', 'c')
#define OL_AVS_ERR_MEDIA_SERVICES_FAILED OL_FOURCC('m', 's', 'r', 'v')

typedef enum {
  OL_SESS_IDLE = 0,
  OL_SESS_WAIT_CALLKIT,      /* CallKit owns activation: wait for didActivate */
  OL_SESS_ACTIVATING,        /* the app calls setActive(true) itself */
  OL_SESS_WAIT_RETRY,        /* transient failure, retry scheduled */
  OL_SESS_WAIT_INTERRUPTION, /* blocked by a higher-priority session */
  OL_SESS_ACTIVE,
  OL_SESS_FAILED
} ol_session_state;

typedef enum {
  OL_ACT_NONE = 0,
  OL_ACT_CALL_SET_ACTIVE, /* call setActive(true) now */
  OL_ACT_SCHEDULE_RETRY,  /* call ol_session_on_timer after delay_ms */
  OL_ACT_ENABLE_AUDIO,    /* session is active: start the call's audio device */
  OL_ACT_DISABLE_AUDIO,   /* session lost: pause the call's audio device */
  OL_ACT_REPORT_FAILURE   /* give up; last_status holds the verbatim code */
} ol_session_action;

typedef struct {
  ol_session_state state;
  int callkit;          /* activation owned by CallKit (provider didActivate) */
  int attempts;
  int max_attempts;     /* setActive attempts (default 3) */
  int64_t delay_ms;     /* next retry delay */
  int32_t first_status; /* first setActive failure, verbatim */
  int32_t last_status;
} ol_session;

void ol_session_init(ol_session *s, int callkit, int max_attempts);
ol_session_action ol_session_begin(ol_session *s);
/* result of setActive(true): 0 = success, else NSError.code verbatim */
ol_session_action ol_session_on_set_active(ol_session *s, int32_t status, int64_t *delay_ms);
ol_session_action ol_session_on_timer(ol_session *s);
ol_session_action ol_session_on_callkit_activate(ol_session *s);
ol_session_action ol_session_on_callkit_deactivate(ol_session *s);
/* AVAudioSessionInterruptionNotification: began=1/ended=0, should_resume */
ol_session_action ol_session_on_interruption(ol_session *s, int began, int should_resume);
/* deadline passed while waiting (CallKit / interruption / retry) */
ol_session_action ol_session_on_timeout(ol_session *s);
const char *ol_session_state_name(ol_session_state st);
int ol_session_is_transient(int32_t status);

#ifdef __cplusplus
}
#endif
#endif
