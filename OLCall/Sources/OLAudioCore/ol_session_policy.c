/* ol_session_policy.c - see include/ol_session_policy.h.
 *
 * With CallKit the app never calls setActive itself: CallKit activates the
 * session and delivers provider(_:didActivate:). Without CallKit the app
 * activates the session and every failure is reported verbatim. */
#include "ol_session_policy.h"

#include <string.h>

void ol_session_init(ol_session *s, int callkit, int max_attempts) {
  memset(s, 0, sizeof(*s));
  s->callkit = callkit;
  s->max_attempts = max_attempts > 0 ? max_attempts : 3;
  s->delay_ms = 250;
}

const char *ol_session_state_name(ol_session_state st) {
  static const char *n[] = {"idle", "wait_callkit", "activating", "wait_retry", "wait_interruption", "active", "failed"};
  return (unsigned)st < sizeof(n) / sizeof(n[0]) ? n[st] : "?";
}

/* Transient = another session briefly holds priority, or the IO is busy.
 * A media-services reset ('msrv') needs a full re-setup and is not retried here. */
int ol_session_is_transient(int32_t st) {
  return st == OL_AVS_ERR_INSUFFICIENT_PRIORITY || st == OL_AVS_ERR_CANNOT_INTERRUPT_OTHERS ||
         st == OL_AVS_ERR_IS_BUSY || st == OL_AVS_ERR_CANNOT_START_PLAYING ||
         st == OL_AVS_ERR_CANNOT_START_RECORDING;
}

ol_session_action ol_session_begin(ol_session *s) {
  s->attempts = 0;
  if (s->callkit) {
    s->state = OL_SESS_WAIT_CALLKIT;
    return OL_ACT_NONE;
  }
  s->state = OL_SESS_ACTIVATING;
  s->attempts = 1;
  return OL_ACT_CALL_SET_ACTIVE;
}

static ol_session_action fail(ol_session *s) {
  s->state = OL_SESS_FAILED;
  return OL_ACT_REPORT_FAILURE;
}

ol_session_action ol_session_on_set_active(ol_session *s, int32_t status, int64_t *delay_ms) {
  if (s->state != OL_SESS_ACTIVATING) return OL_ACT_NONE;
  if (status == 0) {
    s->state = OL_SESS_ACTIVE;
    return OL_ACT_ENABLE_AUDIO;
  }
  if (s->first_status == 0) s->first_status = status;
  s->last_status = status;
  if (status == OL_AVS_ERR_INSUFFICIENT_PRIORITY) {
    /* a phone/FaceTime call or Siri holds the route: wait for its interruption to end */
    s->state = OL_SESS_WAIT_INTERRUPTION;
    if (delay_ms) *delay_ms = 0;
    return OL_ACT_NONE;
  }
  if (ol_session_is_transient(status) && s->attempts < s->max_attempts) {
    s->state = OL_SESS_WAIT_RETRY;
    if (delay_ms) *delay_ms = s->delay_ms;
    s->delay_ms *= 2;
    return OL_ACT_SCHEDULE_RETRY;
  }
  return fail(s);
}

ol_session_action ol_session_on_timer(ol_session *s) {
  if (s->state != OL_SESS_WAIT_RETRY) return OL_ACT_NONE;
  s->state = OL_SESS_ACTIVATING;
  s->attempts++;
  return OL_ACT_CALL_SET_ACTIVE;
}

ol_session_action ol_session_on_callkit_activate(ol_session *s) {
  if (s->state == OL_SESS_ACTIVE) return OL_ACT_NONE;
  s->state = OL_SESS_ACTIVE;
  return OL_ACT_ENABLE_AUDIO;
}

ol_session_action ol_session_on_callkit_deactivate(ol_session *s) {
  if (s->state != OL_SESS_ACTIVE) return OL_ACT_NONE;
  s->state = s->callkit ? OL_SESS_WAIT_CALLKIT : OL_SESS_IDLE;
  return OL_ACT_DISABLE_AUDIO;
}

ol_session_action ol_session_on_interruption(ol_session *s, int began, int should_resume) {
  (void)should_resume;
  if (began) {
    if (s->state == OL_SESS_ACTIVE) {
      s->state = s->callkit ? OL_SESS_WAIT_CALLKIT : OL_SESS_WAIT_INTERRUPTION;
      return OL_ACT_DISABLE_AUDIO;
    }
    return OL_ACT_NONE;
  }
  if (s->state == OL_SESS_WAIT_INTERRUPTION) {
    if (s->attempts >= s->max_attempts) return fail(s);
    s->state = OL_SESS_ACTIVATING;
    s->attempts++;
    return OL_ACT_CALL_SET_ACTIVE;
  }
  return OL_ACT_NONE;
}

ol_session_action ol_session_on_timeout(ol_session *s) {
  if (s->state == OL_SESS_WAIT_CALLKIT || s->state == OL_SESS_WAIT_INTERRUPTION || s->state == OL_SESS_WAIT_RETRY) {
    if (s->last_status == 0) s->last_status = -1; /* timeout: no native status available */
    return fail(s);
  }
  return OL_ACT_NONE;
}
