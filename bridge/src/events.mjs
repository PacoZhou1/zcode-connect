import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { iso } from './util.mjs';

export class EventJournal extends EventEmitter {
  constructor(limit = 2000) { super(); this.epoch = randomUUID(); this.sequence = 0; this.limit = limit; this.entries = []; }
  publish(type, data = {}, sessionId) {
    const event = { id: `${this.epoch}:${++this.sequence}`, type, timestamp: iso(), ...(sessionId ? { sessionId } : {}), data };
    this.entries.push(event);
    if (this.entries.length > this.limit) this.entries.shift();
    this.emit('event', event); return event;
  }
  replay(after) {
    if (!after) return { events: [], resync: false };
    const index = this.entries.findIndex(event => event.id === after);
    return index < 0 ? { events: [], resync: true } : { events: this.entries.slice(index + 1), resync: false };
  }
}
