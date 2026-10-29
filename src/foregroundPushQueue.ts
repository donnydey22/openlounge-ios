import type { ForegroundPushData } from './pushPayload';

/**
 * Preserves foreground FCM updates during a WebView/lifecycle transition. FCM's collapse contract is retained per
 * tag: a later update for the same conversation/room supersedes its predecessor, while independent tags are kept.
 */
export class ForegroundPushQueue {
  private readonly updates = new Map<string, ForegroundPushData>();
  private sequence = 0;

  enqueue(data: ForegroundPushData) {
    const key = data.tag ? `tag:${data.tag}` : `untagged:${++this.sequence}`;
    // Delete first so a replacement retains its true latest ordering when the queue is flushed.
    this.updates.delete(key);
    this.updates.set(key, data);
    while (this.updates.size > 20) this.updates.delete(this.updates.keys().next().value as string);
  }

  drain(): ForegroundPushData[] {
    const pending = [...this.updates.values()];
    this.updates.clear();
    return pending;
  }
}
