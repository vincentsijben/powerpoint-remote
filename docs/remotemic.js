'use strict';
/* global App, Activity, $, toast, store */

/**
 * The remote's own microphone (iPad / phone) for lecture recordings.
 *
 * While the Mac records, this device records your voice in "segments" (a new one after a pause, or when the
 * system stopped the microphone, e.g. a locked screen). Everything is stored on the device first and sent
 * to the Mac over Bluetooth when the link is quiet; after Stop the rest is sent at full speed. Pieces are
 * only deleted once the Mac has saved the video, so a dropped connection loses nothing.
 */
const AudioStore = {
  db: null,

  open() {
    if (this.db) return Promise.resolve(this.db);
    return new Promise((resolve) => {
      if (!window.indexedDB) return resolve(null);
      const req = indexedDB.open('pptremote-audio', 1);
      req.onupgradeneeded = () => {
        req.result.createObjectStore('chunks');
        req.result.createObjectStore('segs');
      };
      req.onsuccess = () => { this.db = req.result; resolve(this.db); };
      req.onerror = () => resolve(null);
    });
  },

  async tx(storeName, mode, fn) {
    const db = await this.open();
    if (!db) return undefined;
    return new Promise((resolve) => {
      const t = db.transaction(storeName, mode);
      const st = t.objectStore(storeName);
      const out = fn(st);
      t.oncomplete = () => resolve(out && 'result' in out ? out.result : undefined);
      t.onerror = () => resolve(undefined);
    });
  },

  putChunk(rec, seg, idx, blob) { return this.tx('chunks', 'readwrite', (st) => st.put(blob, `${rec}:${seg}:${idx}`)); },
  putSeg(meta) { return this.tx('segs', 'readwrite', (st) => st.put(meta, `${meta.rec}:${meta.seg}`)); },
  allSegs() { return this.tx('segs', 'readonly', (st) => st.getAll()); },
  getChunk(rec, seg, idx) { return this.tx('chunks', 'readonly', (st) => st.get(`${rec}:${seg}:${idx}`)); },

  async deleteSeg(meta) {
    await this.tx('chunks', 'readwrite', (st) => {
      for (let i = 0; i < meta.count; i++) st.delete(`${meta.rec}:${meta.seg}:${i}`);
    });
    await this.tx('segs', 'readwrite', (st) => st.delete(`${meta.rec}:${meta.seg}`));
  },
};

const RemoteMic = {
  supported: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder
    && MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported('audio/webm;codecs=opus')),
  enabled: false,
  stream: null,
  recorder: null,
  starting: false,
  needsTap: false, // the system stopped the microphone; starting it again needs a tap
  message: '',
  segs: new Map(), // "rec:seg" → segment
  pumping: false,
  packetSize: 500,

  init() {
    this.enabled = this.supported && store.get('remoteMic', false);
    this.devPrefix = store.get('micDev', 0) || (1 + Math.floor(Math.random() * 400000));
    store.set('micDev', this.devPrefix);
    this.segCounter = store.get('micSeg', 0);
    this.restore();
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') this.sync();
    });
  },

  /** Segments left over from an earlier session (e.g. the page was reloaded): send them when the Mac wants them. */
  async restore() {
    const metas = (await AudioStore.allSegs()) || [];
    for (const m of metas) {
      const key = `${m.rec}:${m.seg}`;
      if (this.segs.has(key)) continue;
      const chunks = [];
      for (let i = 0; i < m.count; i++) {
        const b = await AudioStore.getChunk(m.rec, m.seg, i);
        if (b) chunks.push(b);
      }
      const size = chunks.reduce((n, b) => n + b.size, 0);
      this.segs.set(key, { ...m, chunks, size, ended: true, begun: true, have: 0, sent: 0, lastAckAt: 0, restored: true });
    }
    if (metas.length) Activity.log(`Microphone: ${metas.length} stored piece(s) from an earlier recording`);
    Rec.render();
  },

  setEnabled(on) {
    this.enabled = on && this.supported;
    store.set('remoteMic', this.enabled);
    if (this.enabled) {
      // Ask for the permission now (this is a tap), not in the middle of the lecture.
      navigator.mediaDevices.getUserMedia({ audio: true }).then((s) => {
        s.getTracks().forEach((t) => t.stop());
        this.message = '';
        this.sync();
      }).catch((e) => {
        this.message = `Microphone not allowed (${e.name})`;
        this.enabled = false;
        store.set('remoteMic', false);
        Rec.render();
      });
    } else {
      this.stopSegment();
    }
    Rec.render();
  },

  /** Follows the Mac's recording: record while it records, send the rest when it saves. */
  sync() {
    const r = Rec.info();
    const bt = App.transport && App.transport.kind === 'bluetooth';
    const recording = !!(r && r.st === 'rec');
    if (this.enabled && bt && recording && !this.recorder && !this.starting && document.visibilityState === 'visible') {
      this.startSegment(r.id);
    }
    if (!recording && this.recorder) this.stopSegment();
    if (r && r.st === 'off' && this.lastSt === 'saving') this.cleanup();
    this.lastSt = r ? r.st : this.lastSt;
    if (bt) this.pump();
    Rec.render();
  },

  async startSegment(rec, fromTap) {
    this.starting = true;
    try {
      const live = this.stream && this.stream.getAudioTracks().some((t) => t.readyState === 'live');
      if (!live) {
        // Without the system's voice processing the microphone records the full range (much more natural);
        // the Mac evens out the level. "Reduce background noise" turns the processing back on.
        const clean = store.get('micClean', false);
        this.stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: clean, noiseSuppression: clean, autoGainControl: clean, channelCount: 1, sampleRate: 48000 },
        });
        const st = this.stream.getAudioTracks()[0].getSettings ? this.stream.getAudioTracks()[0].getSettings() : {};
        Activity.log(`Microphone: ${st.sampleRate || '?'} Hz, voice processing ${clean ? 'on' : 'off'}`);
      }
    } catch (e) {
      this.starting = false;
      this.needsTap = true;
      this.message = fromTap ? `Microphone not available (${e.name})` : 'Tap “Resume microphone” to record your voice here';
      Activity.log(`Microphone: could not start (${e.name})`, 'error');
      Rec.render();
      return;
    }
    const r = Rec.info();
    if (!r || r.st !== 'rec' || !this.enabled) {
      this.starting = false;
      this.releaseStream();
      return;
    }
    this.needsTap = false;
    this.message = '';
    this.segCounter += 1;
    store.set('micSeg', this.segCounter);
    const seg = (this.devPrefix * 1000 + (this.segCounter % 1000)) >>> 0;
    const s = { rec, seg, chunks: [], count: 0, size: 0, ended: false, begun: false, have: 0, sent: 0, lastAckAt: 0, at: Date.now() };
    this.segs.set(`${rec}:${seg}`, s);
    const mr = new MediaRecorder(this.stream, { mimeType: 'audio/webm;codecs=opus', audioBitsPerSecond: 64000 });
    mr.addEventListener('start', async () => {
      s.begun = await App.transport.send(`ma begin ${rec} ${seg}`);
      AudioStore.putSeg(this.meta(s));
      Activity.log(`Microphone: recording (piece ${this.segCounter})`);
      this.pump();
    });
    mr.addEventListener('dataavailable', (e) => {
      if (!e.data || !e.data.size) return;
      AudioStore.putChunk(rec, seg, s.chunks.length, e.data);
      s.chunks.push(e.data);
      s.count = s.chunks.length;
      s.size += e.data.size;
      AudioStore.putSeg(this.meta(s));
      this.pump();
    });
    mr.addEventListener('stop', () => {
      s.ended = true;
      AudioStore.putSeg(this.meta(s));
      if (App.transport) App.transport.send(`ma end ${rec} ${seg} ${s.size}`);
      Activity.log(`Microphone: piece ${this.segCounter} done, ${(s.size / 1024).toFixed(0)} KB`);
      if (this.recorder === mr) this.recorder = null;
      const still = Rec.info();
      if (still && still.st === 'rec' && this.enabled) {
        // The system took the microphone away (screen locked, other app): start again when possible.
        this.needsTap = true;
        this.message = 'The microphone stopped (screen locked?). The MacBook microphone covers the gap.';
        if (document.visibilityState === 'visible') setTimeout(() => this.sync(), 300);
      } else {
        this.releaseStream();
      }
      this.pump();
      Rec.render();
    });
    this.stream.getAudioTracks().forEach((t) => {
      t.onended = () => { if (mr.state !== 'inactive') mr.stop(); };
    });
    this.recorder = mr;
    mr.start(1000);
    this.starting = false;
    Rec.render();
  },

  stopSegment() {
    if (this.recorder && this.recorder.state !== 'inactive') this.recorder.stop();
  },

  releaseStream() {
    if (this.stream) this.stream.getTracks().forEach((t) => t.stop());
    this.stream = null;
  },

  meta(s) { return { rec: s.rec, seg: s.seg, count: s.count, size: s.size, ended: s.ended, at: s.at }; },

  /** The Mac saved the video: forget what it has. */
  async cleanup() {
    for (const [key, s] of this.segs) {
      if (s.complete || s.dead) {
        if (s.complete) await AudioStore.deleteSeg(this.meta(s));
        if (s.complete) this.segs.delete(key);
      }
    }
    Rec.render();
  },

  async deleteAll() {
    for (const s of this.segs.values()) await AudioStore.deleteSeg(this.meta(s));
    this.segs.clear();
    Rec.render();
  },

  onAck(m) {
    const s = this.segs.get(`${m.rec}:${m.seg}`);
    if (!s) return;
    s.lastAckAt = Date.now();
    if (m.have < 0) {
      if (!s.dead) Activity.log(`Microphone: the Mac doesn't need piece ${m.seg % 1000} any more`);
      s.dead = true;
      return;
    }
    if (m.gap || m.have > s.sent) s.sent = m.have;
    s.have = Math.max(s.have, m.have);
    if (m.gap) s.have = m.have;
    if (s.ended && s.have >= s.size) s.complete = true;
    this.pump();
  },

  /** Bytes from the stored pieces. */
  async read(s, offset, n) {
    let pos = 0;
    const out = new Uint8Array(n);
    let filled = 0;
    for (let i = 0; i < s.chunks.length && filled < n; i++) {
      const b = s.chunks[i];
      if (pos + b.size <= offset) { pos += b.size; continue; }
      if (!s.cache || s.cache.i !== i) s.cache = { i, bytes: new Uint8Array(await b.arrayBuffer()) };
      const from = Math.max(0, offset + filled - pos);
      const take = Math.min(b.size - from, n - filled);
      out.set(s.cache.bytes.subarray(from, from + take), filled);
      filled += take;
      pos += b.size;
    }
    return out.subarray(0, filled);
  },

  pending() {
    let n = 0;
    for (const s of this.segs.values()) if (!s.dead) n += Math.max(0, s.size - s.have);
    return n;
  },

  /** Sends what the Mac doesn't have yet. While recording only in quiet moments, so slides and the pen stay quick. */
  async pump() {
    if (this.pumping) return;
    this.pumping = true;
    try {
      for (;;) {
        const t = App.transport;
        if (!t || t.kind !== 'bluetooth' || !t.cmdChar) break;
        const r = Rec.info();
        const list = [...this.segs.values()].filter((s) => s.begun && !s.dead && s.rec === (r && r.id) && s.have < s.size);
        if (!list.length) break;
        const s = list.sort((a, b) => a.at - b.at)[0];
        const rushing = r && (r.st === 'saving' || r.rw);
        if (!rushing && (App.inflight.size || Date.now() - (App.lastPointerAt || 0) < 700)) { await sleep(150); continue; }
        if (s.sent - s.have > 16384 || s.sent >= s.size) {
          // Waiting for the Mac to confirm; ask again if it went quiet.
          if (Date.now() - s.lastAckAt > 2500) {
            s.sent = s.have;
            s.lastAckAt = Date.now();
            t.send(`ma ask ${s.rec} ${s.seg}`, true);
          }
          await sleep(100);
          if (s.sent >= s.size && s.ended && s.have >= s.size) s.complete = true;
          continue;
        }
        const bytes = await this.read(s, s.sent, this.packetSize - 13);
        if (!bytes.length) { await sleep(200); continue; }
        const pkt = new Uint8Array(13 + bytes.length);
        const dv = new DataView(pkt.buffer);
        pkt[0] = 1;
        dv.setUint32(1, s.rec >>> 0);
        dv.setUint32(5, s.seg >>> 0);
        dv.setUint32(9, s.sent >>> 0);
        pkt.set(bytes, 13);
        const ok = await t.sendBinary(pkt);
        if (!ok) {
          if (this.packetSize > 180) {
            this.packetSize = 180;
            Activity.log('Microphone upload: using smaller Bluetooth packets');
          }
          await sleep(300);
          continue;
        }
        s.sent += bytes.length;
        if (!rushing) await sleep(30);
      }
    } finally {
      this.pumping = false;
    }
  },

  statusText() {
    if (!this.enabled) return '';
    const parts = [];
    if (this.recorder) parts.push('🎙 Recording your voice here');
    else if (this.starting) parts.push('Starting the microphone…');
    if (this.message) parts.push(this.message);
    const total = [...this.segs.values()].reduce((n, s) => n + s.size, 0);
    const pend = this.pending();
    if (total) parts.push(`${(total / 1048576).toFixed(1)} MB recorded${pend ? `, ${(pend / 1024).toFixed(0)} KB still to send` : ', all sent'}`);
    return parts.join('\n');
  },
};
