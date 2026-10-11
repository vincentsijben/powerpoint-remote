/* Behind-the-scenes activity log and transfer statistics (shown in Settings › Activity). */
'use strict';

const Activity = {
  MAX: 500,
  entries: [],
  started: Date.now(),
  stats: {
    bytesIn: 0,
    framesIn: 0,
    maxFrame: 0,
    bytesOut: 0,
    commandsOut: 0,
    imagesDownloaded: 0,
    imageBytes: 0,
    imageMs: 0,
    imagesFromStore: 0,
    reconnects: 0,
    connectedAt: 0,
  },
  samples: [], // [time, bytes] for the current speed

  log(msg, kind = 'info') {
    this.entries.push({ t: Date.now(), msg, kind });
    if (this.entries.length > this.MAX) this.entries.splice(0, this.entries.length - this.MAX);
  },

  received(bytes, frames = 1) {
    this.stats.bytesIn += bytes;
    this.stats.framesIn += frames;
    if (frames === 1 && bytes > this.stats.maxFrame) this.stats.maxFrame = bytes;
    const now = Date.now();
    this.samples.push([now, bytes]);
    while (this.samples.length && now - this.samples[0][0] > 5000) this.samples.shift();
  },

  sent(bytes) {
    this.stats.bytesOut += bytes;
    this.stats.commandsOut++;
  },

  /** Bytes per second over the last 5 seconds. */
  speed() {
    const now = Date.now();
    while (this.samples.length && now - this.samples[0][0] > 5000) this.samples.shift();
    if (!this.samples.length) return 0;
    const span = Math.max(1000, now - this.samples[0][0]);
    return this.samples.reduce((a, s) => a + s[1], 0) / (span / 1000);
  },

  resetSession() {
    for (const k of Object.keys(this.stats)) this.stats[k] = 0;
    this.samples = [];
  },

  text() {
    return this.entries.map((e) => `${fmtTime(e.t)} ${e.kind === 'error' ? '⚠ ' : ''}${e.msg}`).join('\n');
  },
};

function fmtBytes(n) {
  if (n < 1024) return `${Math.round(n)} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(n < 10240 ? 1 : 0)} KB`;
  return `${(n / 1024 / 1024).toFixed(n < 10 * 1024 * 1024 ? 2 : 1)} MB`;
}

function fmtTime(t) {
  const d = new Date(t);
  const p = (x, n = 2) => String(x).padStart(n, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

function fmtDuration(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s} s`;
  if (s < 3600) return `${Math.floor(s / 60)} min ${s % 60} s`;
  return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
}
