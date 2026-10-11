/* PPT Remote – web app for tablets and phones. Talks to the Mac helper over Bluetooth (Web Bluetooth) or HTTP. */
'use strict';

const APP_VERSION = '1.2';

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const store = {
  get(key, def) {
    try {
      const v = localStorage.getItem('pptremote.' + key);
      return v === null ? def : JSON.parse(v);
    } catch { return def; }
  },
  set(key, val) {
    try { localStorage.setItem('pptremote.' + key, JSON.stringify(val)); } catch { /* private mode */ }
  },
};

const prefs = {
  fontSize: store.get('fontSize', 22),
  quality: store.get('quality', 'med'),
  swipe: store.get('swipe', true),
  autoTimer: store.get('autoTimer', true),
};

const QUALITY_NAMES = { low: 'low', med: 'medium', high: 'high' };

// ---------------------------------------------------------------------------
// Transports
// ---------------------------------------------------------------------------

class BleTransport {
  constructor(handlers) {
    this.kind = 'bluetooth';
    this.h = handlers;
    this.device = null;
    this.cmdChar = null;
    this.writeChain = Promise.resolve();
    this.manual = false;
    this.reconnectTimer = null;
    this.assembler = new FrameAssembler((type, bytes) => this.onFrameMessage(type, bytes));
    this.onValue = (e) => {
      Activity.received(e.target.value.byteLength);
      this.assembler.push(e.target.value);
    };
  }

  static available() {
    return !!(navigator.bluetooth && navigator.bluetooth.requestDevice);
  }

  async connect() {
    this.manual = false;
    Activity.log('Bluetooth: choosing device…');
    this.device = await navigator.bluetooth.requestDevice({
      filters: [{ services: [PPT_BLE.service] }, { name: 'PPT Remote' }],
      optionalServices: [PPT_BLE.service],
    });
    Activity.log(`Bluetooth: selected "${this.device.name || 'PPT Remote'}"`);
    this.device.addEventListener('gattserverdisconnected', () => this.onDisconnected());
    await this.openGatt();
  }

  async openGatt() {
    this.h.status('connecting');
    const t = Date.now();
    const server = await this.device.gatt.connect();
    const service = await server.getPrimaryService(PPT_BLE.service);
    const cmd = await service.getCharacteristic(PPT_BLE.command);
    const data = await service.getCharacteristic(PPT_BLE.data);
    this.assembler.reset();
    data.addEventListener('characteristicvaluechanged', this.onValue);
    await data.startNotifications();
    this.cmdChar = cmd;
    Activity.stats.connectedAt = Date.now();
    Activity.log(`Bluetooth: connected in ${Date.now() - t} ms`);
    this.h.status('connected');
    this.h.connected();
  }

  onFrameMessage(type, bytes) {
    if (type === PPT_BLE.TYPE_JSON) {
      let obj;
      try { obj = JSON.parse(new TextDecoder().decode(bytes)); } catch { return; }
      this.h.message(obj);
    } else if (type === PPT_BLE.TYPE_IMAGE) {
      const img = parseImagePayload(bytes);
      if (img) this.h.image(img.header, img.jpeg);
    }
  }

  /** @param {boolean} fast  write without waiting for an acknowledgement (pointer moves) */
  send(text, fast) {
    const bytes = new TextEncoder().encode(text);
    // GATT operations must not overlap, so writes are chained (this also keeps pointer messages in order).
    this.writeChain = this.writeChain
      .then(() => {
        const c = this.cmdChar;
        if (!c || !this.device || !this.device.gatt.connected) {
          if (!fast) Activity.log(`Not sent (not connected): ${text.startsWith('auth') ? 'auth' : text}`, 'error');
          return undefined;
        }
        Activity.sent(bytes.length);
        if (fast && c.writeValueWithoutResponse) return c.writeValueWithoutResponse(bytes);
        return c.writeValueWithResponse ? c.writeValueWithResponse(bytes) : c.writeValue(bytes);
      })
      .catch((err) => Activity.log(`Command "${text.split(' ')[0]}" failed: ${err && err.message}`, 'error'));
    return this.writeChain;
  }

  /** The PIN, supported image formats and quality go together, so the first images are already right. */
  sendAuth(pin) { this.send(`auth ${pin} ${App.formats.join(',')} ${prefs.quality}`); }

  onDisconnected() {
    this.cmdChar = null;
    if (this.manual) {
      this.h.status('disconnected');
      return;
    }
    Activity.stats.reconnects++;
    Activity.log('Bluetooth: connection lost, reconnecting…', 'error');
    this.h.status('reconnecting');
    this.scheduleReconnect(500);
  }

  scheduleReconnect(delay) {
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(async () => {
      if (this.manual || !this.device) return;
      try {
        await this.openGatt();
      } catch (e) {
        Activity.log(`Bluetooth: reconnect failed (${e && e.message}), retrying`, 'error');
        this.h.status('reconnecting');
        this.scheduleReconnect(2000);
      }
    }, delay);
  }

  disconnect() {
    this.manual = true;
    clearTimeout(this.reconnectTimer);
    if (this.device && this.device.gatt.connected) this.device.gatt.disconnect();
    Activity.log('Bluetooth: disconnected');
    this.h.status('disconnected');
  }
}

class HttpTransport {
  constructor(handlers) {
    this.kind = 'network';
    this.h = handlers;
    this.ver = 0;
    this.running = false;
    this.authed = false;
  }

  static async probe() {
    if (!/^https?:$/.test(location.protocol)) return false;
    try {
      const r = await fetch('api/auth', { cache: 'no-store' });
      return r.status === 200 || r.status === 401;
    } catch { return false; }
  }

  headers() { return { 'X-PPT-PIN': App.pin || '' }; }

  async getJSON(url, opts = {}) {
    const r = await fetch(url, { headers: this.headers(), cache: 'no-store', ...opts });
    const text = await r.text();
    Activity.received(text.length, 0);
    return { status: r.status, obj: JSON.parse(text) };
  }

  async connect() {
    this.running = true;
    this.h.status('connecting');
    Activity.log(`Network: connecting to ${location.host}`);
    await this.auth();
    this.loop();
  }

  async auth() {
    try {
      const { obj } = await this.getJSON('api/auth');
      this.authed = !!obj.ok;
      if (this.authed) {
        Activity.stats.connectedAt = Date.now();
        Activity.log('Network: connected');
        this.h.status('connected');
        this.h.connected();
      }
      this.h.message(obj);
    } catch (e) {
      this.h.status('reconnecting');
      throw e;
    }
  }

  sendAuth() { this.auth().catch(() => {}); }

  async loop() {
    let failures = 0;
    while (this.running) {
      if (!this.authed) { await sleep(400); continue; }
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 25000);
      try {
        const { status, obj } = await this.getJSON(`api/state?ver=${this.ver}`, { signal: ctrl.signal });
        clearTimeout(t);
        if (status === 401) {
          this.authed = false;
          this.h.message(obj);
          continue;
        }
        if (failures > 0) {
          Activity.log('Network: connection restored');
          this.h.status('connected');
        }
        failures = 0;
        this.ver = obj.ver;
        this.h.message(obj);
      } catch (e) {
        clearTimeout(t);
        if (!this.running) break;
        failures++;
        if (failures === 2) {
          Activity.stats.reconnects++;
          Activity.log('Network: Mac not reachable, retrying…', 'error');
        }
        if (failures > 1) this.h.status('reconnecting');
        await sleep(Math.min(3000, 500 * failures));
      }
    }
  }

  async fetchAllNotes() {
    try {
      const { status, obj } = await this.getJSON('api/state?all=1');
      if (status === 200) this.h.message(obj);
    } catch { /* next poll will retry */ }
  }

  async fetchDeck() {
    try {
      const { status, obj } = await this.getJSON(`api/deck?fmt=${App.formats.join(',')}`);
      if (status === 200) this.h.message(obj);
    } catch (e) {
      Activity.log(`Network: could not get slide list (${e.message})`, 'error');
    }
  }

  /** @returns {Promise<{header: object, bytes: Uint8Array}|null>} */
  async fetchImage(slide) {
    const url = `api/slide?n=${slide}&w=1600&q=0.6&fmt=${App.formats.join(',')}&pin=${encodeURIComponent(App.pin)}`;
    const r = await fetch(url, { cache: 'no-store' });
    if (!r.ok) return null;
    const bytes = new Uint8Array(await r.arrayBuffer());
    Activity.received(bytes.length, 0);
    const fmt = (r.headers.get('Content-Type') || 'image/jpeg').split('/')[1];
    return {
      header: { slide, deck: App.deck, key: r.headers.get('X-Slide-Key') || '', fmt, w: 1600, q: 'net', enc: Number(r.headers.get('X-Encode-Ms')) || 0 },
      bytes,
    };
  }

  send(text) {
    const i = text.indexOf(' ');
    const c = i < 0 ? text : text.slice(0, i);
    const n = i < 0 ? '' : text.slice(i + 1);
    if (!Hub.commands.has(c)) return Promise.resolve();
    const q = `c=${encodeURIComponent(c)}${n ? `&n=${encodeURIComponent(n)}` : ''}`;
    Activity.sent(q.length);
    // One at a time, so pointer strokes arrive in order.
    this.chain = (this.chain || Promise.resolve())
      .then(() => fetch(`api/cmd?${q}`, { method: 'POST', headers: this.headers(), cache: 'no-store' }))
      .catch((e) => Activity.log(`Command "${c}" failed: ${e.message}`, 'error'));
    return this.chain;
  }

  disconnect() {
    this.running = false;
    Activity.log('Network: disconnected');
    this.h.status('disconnected');
  }
}

const Hub = {
  commands: new Set(['next', 'prev', 'first', 'last', 'goto', 'start', 'starthere', 'end', 'black', 'reload',
    'use', 'media', 'lz', 'pd', 'pm', 'pu', 'ink']),
};

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

const App = {
  transport: null,
  connState: 'disconnected',
  pin: store.get('pin', ''),
  formats: ['jpeg'],
  st: null,
  deck: '',
  deckInfo: null, // { deck, keys, fmt } from the Mac
  notes: {},
  rich: {}, // slide -> formatted paragraphs
  plist: [], // open presentations on the Mac
  media: [], // video/audio on the current slide: { k, name, kind, st, pos, at }
  inkSlides: new Map(), // slide -> strokes drawn from this device (for local display)
  images: new Map(), // slide -> object URL (current deck only)
  imageInfo: new Map(), // slide -> { source: 'store' | 'download', size, fmt }
  failed: new Set(),
  inflight: new Set(),
  requestedAt: new Map(),
  netFetching: 0,
  storeLoading: false,
  storeChecked: '',
  allDoneLogged: false,
  lastImageAt: 0,
  lastShownIndex: -1,
  pinPromptOpen: false,
  authSentAt: 0,
  lastCmd: null, // { cmd, at }
  pendingGoto: null, // { target, until }

  // --- connection -----------------------------------------------------------

  handlers() {
    return {
      status: (s) => { this.connState = s; this.renderConn(); },
      connected: () => this.onConnected(),
      message: (obj) => this.onMessage(obj),
      image: (header, bytes) => this.onImage(header, bytes),
    };
  },

  async connectBluetooth() {
    $('connectError').textContent = '';
    const t = new BleTransport(this.handlers());
    this.useTransport(t);
    try {
      await t.connect();
      store.set('mode', 'bluetooth');
    } catch (e) {
      if (this.transport === t) this.transport = null;
      const cancelled = e && e.name === 'NotFoundError';
      Activity.log(cancelled ? 'Bluetooth: no device chosen' : `Bluetooth: ${e.message || e}`, cancelled ? 'info' : 'error');
      this.showConnect(cancelled ? '' : `Bluetooth: ${e.message || e}`);
    }
  },

  async connectNetwork() {
    $('connectError').textContent = '';
    const t = new HttpTransport(this.handlers());
    this.useTransport(t);
    try {
      await t.connect();
      store.set('mode', 'network');
    } catch (e) {
      if (this.transport === t) this.transport = null;
      t.running = false;
      Activity.log(`Network: ${e.message || e}`, 'error');
      this.showConnect(`Network: ${e.message || e}`);
    }
  },

  useTransport(t) {
    if (this.transport) this.transport.disconnect();
    Activity.resetSession();
    this.transport = t;
    this.resetDeck('');
    this.deckInfo = null;
    this.st = null;
    $('connectView').classList.add('hidden');
    this.render();
  },

  disconnect() {
    if (this.transport) this.transport.disconnect();
    this.transport = null;
    this.st = null;
    this.render();
    this.showConnect('');
  },

  showConnect(err) {
    $('connectError').textContent = err || '';
    $('connectView').classList.remove('hidden');
  },

  async onConnected() {
    keepAwake();
    if (this.transport.kind === 'bluetooth') {
      this.inflight.clear();
      await ImageFormats.detect();
      if (this.pin) {
        this.authSentAt = Date.now();
        this.transport.sendAuth(this.pin);
      }
    }
  },

  send(cmd) {
    if (!this.transport) return;
    this.lastCmd = { cmd, at: Date.now() };
    if (cmd !== 'imgclear' && !cmd.startsWith('img ')) Activity.log(`→ ${cmd}`);
    this.transport.send(cmd);
  },

  goto(slide) {
    // Show the target right away and ignore any in-between slides PowerPoint may report.
    this.pendingGoto = { target: slide, until: Date.now() + 6000 };
    this.send('goto ' + slide);
    this.render();
    this.scheduleImages(true);
  },

  // --- incoming -------------------------------------------------------------

  onMessage(obj) {
    if (!obj || typeof obj !== 'object') return;
    if (obj.type === 'auth') {
      if (obj.ok) {
        if (this.pinPromptOpen || !this.st) Activity.log('PIN accepted');
        this.hidePin();
      } else if (obj.need) {
        if (obj.wrong || !this.pin) {
          if (obj.wrong) Activity.log('Wrong PIN', 'error');
          this.showPin(obj.wrong ? 'Wrong PIN, try again.' : '');
        } else if (Date.now() - this.authSentAt > 2000) {
          // The Mac asks for the PIN when we subscribe; skip if we just sent it.
          this.authSentAt = Date.now();
          this.transport.sendAuth(this.pin);
        }
      }
    } else if (obj.type === 'state') {
      this.applyState(obj);
    } else if (obj.type === 'deck') {
      this.onDeck(obj);
    } else if (obj.type === 'noimage') {
      if (obj.deck === this.deck) {
        Activity.log(`Slide ${obj.slide}: no image available`);
        this.failed.add(obj.slide);
        this.inflight.delete(obj.slide);
        this.lastImageAt = Date.now();
        this.scheduleImages(false);
      }
    }
  },

  resetDeck(deck) {
    for (const url of this.images.values()) URL.revokeObjectURL(url);
    this.images.clear();
    this.imageInfo.clear();
    this.failed.clear();
    this.inflight.clear();
    this.requestedAt.clear();
    this.notes = {};
    this.rich = {};
    this.inkSlides.clear();
    this.deck = deck;
    this.storeChecked = '';
    this.allDoneLogged = false;
    this.lastShownIndex = -1;
    this.pendingGoto = null;
  },

  applyState(s) {
    const prev = this.st;
    const newDeck = s.deck !== this.deck;
    if (newDeck) {
      this.resetDeck(s.deck);
      if (s.deck) {
        Activity.log(`Presentation: "${s.name}", ${s.count} slides`);
        if (this.transport && this.transport.kind === 'network') this.transport.fetchAllNotes();
      }
    } else if (prev && s.pres && s.loading && !prev.loading) {
      Activity.log('Mac is exporting the slides…');
    }
    if (s.notes) for (const [k, v] of Object.entries(s.notes)) this.notes[k] = v;
    if (s.rich) for (const [k, v] of Object.entries(s.rich)) this.rich[k] = v;
    if (s.plist) {
      const before = this.plist.map((x) => x.name).join('|');
      this.plist = s.plist;
      if (before !== s.plist.map((x) => x.name).join('|') && s.plist.length > 1) {
        Activity.log(`Open presentations: ${s.plist.map((x) => x.name).join(', ')}`);
      }
    }
    const now = Date.now();
    this.media = (s.media || []).map((m) => ({ ...m, at: now }));
    if (!s.showing) this.setTool(null, true);
    if (prev && !prev.images && s.images) this.failed.clear();
    if (s.showing && !(prev && prev.showing) && prefs.autoTimer && prev) Timer.restart();

    const indexChanged = !prev || prev.index !== s.index || prev.showing !== s.showing;
    if (indexChanged && s.pres) {
      let note = '';
      if (this.lastCmd && Date.now() - this.lastCmd.at < 5000) note = ` · ${Date.now() - this.lastCmd.at} ms after "${this.lastCmd.cmd}"`;
      Activity.log(`Now on slide ${s.index}/${s.count}${s.showing ? ' (slide show)' : ''}${note}`);
    }
    if (this.pendingGoto && (s.index === this.pendingGoto.target || Date.now() > this.pendingGoto.until || (prev && prev.showing && !s.showing))) {
      this.pendingGoto = null;
    }
    this.st = s;
    if (!s.ink) this.inkSlides.delete(s.index);
    this.render();
    if (newDeck && s.deck) this.requestDeckInfo();
    if (newDeck || indexChanged || (prev && !prev.images && s.images)) this.scheduleImages(true);
  },

  requestDeckInfo() {
    if (this.deckInfo && this.deckInfo.deck === this.deck) {
      this.loadFromStore(false);
      return;
    }
    if (!this.transport) return;
    if (this.transport.kind === 'network') {
      this.transport.fetchDeck();
    } else {
      // The Mac sends this by itself; ask again if it hasn't arrived shortly.
      const deck = this.deck;
      setTimeout(() => {
        if (this.deck === deck && (!this.deckInfo || this.deckInfo.deck !== deck)) this.send('deck');
      }, 2000);
    }
  },

  onDeck(info) {
    const fmtChanged = !this.deckInfo || this.deckInfo.fmt !== info.fmt;
    this.deckInfo = info;
    if (fmtChanged) {
      Activity.log(`Image format: ${info.fmt.toUpperCase()} (this device can show ${this.formats.join(', ').toUpperCase()}; Mac can make ${(info.macFormats || []).join(', ').toUpperCase()})`);
    }
    if (info.deck === this.deck && this.storeChecked !== info.deck && !this.storeLoading) this.loadFromStore(false);
  },

  variant(fmt) {
    return this.transport && this.transport.kind === 'network' ? `${fmt}-net` : `${fmt}-${prefs.quality}`;
  },

  /** Fills `images` with slides already stored on this device. */
  async loadFromStore(strict) {
    const deck = this.deck;
    const info = this.deckInfo;
    if (!info || info.deck !== deck || !this.st) return;
    this.storeLoading = true;
    const t = Date.now();
    const variant = this.variant(info.fmt);
    let hits = 0;
    let bytes = 0;
    let checked = 0;
    for (const i of this.priorityOrder()) {
      if (this.images.has(i)) continue;
      const key = info.keys[i - 1];
      if (!key) continue;
      checked++;
      const rec = await SlideStore.get(key, variant, strict);
      if (this.deck !== deck) { this.storeLoading = false; return; }
      if (!rec) continue;
      this.images.set(i, URL.createObjectURL(new Blob([rec.data], { type: rec.mime })));
      this.imageInfo.set(i, { source: 'store', size: rec.size, fmt: rec.mime.split('/')[1] });
      hits++;
      bytes += rec.size;
      if (hits <= 2) this.renderSlides();
    }
    this.storeLoading = false;
    this.storeChecked = deck;
    Activity.stats.imagesFromStore += hits;
    if (checked) {
      Activity.log(`Found ${hits} of ${checked} slides stored on this device (${fmtBytes(bytes)}, ${Date.now() - t} ms)`);
    }
    this.render();
    this.scheduleImages(true);
  },

  async onImage(header, bytes, viaNetwork) {
    const now = Date.now();
    if (header.deck !== this.deck) return;
    const slide = header.slide;
    const start = viaNetwork ? this.requestedAt.get(slide) || now : Math.max(this.lastImageAt, this.requestedAt.get(slide) || 0);
    const ms = Math.max(1, now - start);
    this.lastImageAt = now;
    const mime = `image/${header.fmt || 'jpeg'}`;
    const old = this.images.get(slide);
    if (old) URL.revokeObjectURL(old);
    this.images.set(slide, URL.createObjectURL(new Blob([bytes], { type: mime })));
    this.imageInfo.set(slide, { source: 'download', size: bytes.length, fmt: header.fmt });
    this.inflight.delete(slide);
    this.requestedAt.delete(slide);

    const s = Activity.stats;
    s.imagesDownloaded++;
    s.imageBytes += bytes.length;
    s.imageMs += ms;
    Activity.log(`Slide ${slide}: ${fmtBytes(bytes.length)} ${String(header.fmt).toUpperCase()} ${header.w || '?'}px in ${(ms / 1000).toFixed(2)} s` +
      ` (${fmtBytes(bytes.length / (ms / 1000))}/s, Mac encode ${header.enc || 0} ms)`);

    SlideStore.put({
      key: header.key, variant: `${header.fmt}-${header.q}`, data: bytes.slice().buffer, mime,
      deck: this.deck, name: this.st ? this.st.name : '', slide,
    });

    this.renderSlides();
    if (!$('gridView').classList.contains('hidden')) this.renderGrid();
    if (this.inflight.size === 0) this.scheduleImages(false);
  },

  // --- images ---------------------------------------------------------------

  isHidden(i) { return !!(this.st && this.st.hidden && this.st.hidden.includes(i)); },

  /** The slide this device shows: the target of a pending jump, otherwise PowerPoint's slide. */
  shownIndex() {
    return this.pendingGoto ? this.pendingGoto.target : this.st ? this.st.index : 0;
  },

  nextVisible(i) {
    const s = this.st;
    if (!s) return 0;
    let n = i + 1;
    if (s.showing) while (n <= s.count && this.isHidden(n)) n++;
    return n;
  },

  /** Current, next, then the rest forward, then backward. */
  priorityOrder() {
    const s = this.st;
    const out = [];
    const add = (i) => { if (i >= 1 && i <= s.count && !out.includes(i)) out.push(i); };
    const cur = Math.max(1, this.shownIndex());
    add(cur);
    add(this.nextVisible(cur));
    for (let i = cur + 1; i <= s.count; i++) add(i);
    for (let i = cur - 1; i >= 1; i--) add(i);
    return out;
  },

  missingSlides() {
    return this.priorityOrder().filter((i) => !this.isHidden(i) && !this.images.has(i) && !this.failed.has(i));
  },

  scheduleImages(reprioritize) {
    const t = this.transport;
    const s = this.st;
    if (!t || !s || !s.images || !this.deck || this.storeLoading || this.storeChecked !== this.deck) return;
    const missing = this.missingSlides();
    if (!missing.length) {
      if (!this.allDoneLogged && s.count) {
        this.allDoneLogged = true;
        Activity.log('All slides of this presentation are on this device');
      }
      return;
    }
    if (t.kind === 'network') {
      this.fetchNetworkImages();
      return;
    }
    if (reprioritize && this.inflight.size) {
      // Only re-order if the slide on screen isn't already on its way.
      if (this.inflight.has(missing[0])) return;
      this.send('imgclear');
      this.inflight.clear();
    }
    if (this.inflight.size) return;
    const batch = missing.slice(0, 3);
    const now = Date.now();
    batch.forEach((i) => { this.inflight.add(i); this.requestedAt.set(i, now); });
    if (this.lastImageAt < now - 1000) this.lastImageAt = now;
    Activity.log(`Requesting slide${batch.length > 1 ? 's' : ''} ${batch.join(', ')} (${missing.length} still missing)`);
    this.send('img ' + batch.join(','));
  },

  async fetchNetworkImages() {
    while (this.netFetching < 2 && this.transport && this.transport.kind === 'network') {
      const next = this.missingSlides().find((i) => !this.inflight.has(i));
      if (!next) return;
      const deck = this.deck;
      this.inflight.add(next);
      this.requestedAt.set(next, Date.now());
      this.netFetching++;
      this.transport.fetchImage(next)
        .then((r) => {
          if (deck !== this.deck) return;
          if (r) this.onImage(r.header, r.bytes, true);
          else { this.failed.add(next); Activity.log(`Slide ${next}: no image available`); }
        })
        .catch((e) => Activity.log(`Slide ${next}: download failed (${e.message})`, 'error'))
        .finally(() => {
          this.inflight.delete(next);
          this.netFetching--;
          if (deck === this.deck) this.scheduleImages(false);
        });
    }
  },

  imageFor(i) {
    if (!this.st || !this.st.images || i < 1 || i > this.st.count || this.isHidden(i)) return null;
    return this.images.get(i) || null;
  },

  // --- rendering ------------------------------------------------------------

  renderConn() {
    const dot = $('connDot');
    const label = $('connLabel');
    const kind = this.transport ? (this.transport.kind === 'bluetooth' ? 'Bluetooth' : 'Network') : '';
    dot.className = 'dot ' + ({ connected: 'ok', connecting: 'warn', reconnecting: 'warn' }[this.connState] || 'off');
    label.textContent = !this.transport ? 'Not connected'
      : this.connState === 'connected' ? kind
        : this.connState === 'connecting' ? 'Connecting…'
          : this.connState === 'reconnecting' ? 'Reconnecting…' : 'Disconnected';
  },

  render() {
    this.renderConn();
    const s = this.st;
    $('deckName').textContent = s && s.name ? s.name : '';
    $('deckCaret').classList.toggle('hidden', !(s && s.pcount > 1));
    $('deckBtn').disabled = !(s && s.pcount >= 1);
    $('slideNum').textContent = s && s.pres && s.count ? `${this.shownIndex()} / ${s.count}` : '–';
    this.renderSlides();
    this.renderNotes();
    this.renderTools();
    this.renderSlideTools();
    this.renderMedia();
    this.renderInk();
    $('sectionName').textContent = this.sectionOf(this.shownIndex()) || '';
  },

  sectionOf(i) {
    const secs = (this.deckInfo && this.deckInfo.deck === this.deck && this.deckInfo.sections) || [];
    const sec = secs.find((x) => i >= x.first && i < x.first + x.count);
    return sec && secs.length > 1 ? sec.name : '';
  },

  setImg(img, msgEl, url, fallbackText, big) {
    if (url) {
      if (img.getAttribute('src') !== url) {
        img.setAttribute('src', url);
        // Restart the short fade-in.
        img.classList.remove('fade');
        void img.offsetWidth;
        img.classList.add('fade');
      }
      msgEl.textContent = '';
    } else {
      img.removeAttribute('src');
      msgEl.textContent = fallbackText;
    }
    msgEl.classList.toggle('big', !!big && !url);
  },

  renderSlides() {
    const s = this.st;
    let msg = '';
    if (!this.transport) msg = 'Not connected';
    else if (!s) msg = 'Waiting for the Mac…';
    else if (!s.ppt) msg = 'PowerPoint is not running on the Mac';
    else if (!s.pres) msg = 'Open a presentation in PowerPoint';
    else if (s.loading && !s.images) msg = 'Loading slides…';
    if (msg) {
      this.setImg($('currentImg'), $('currentMsg'), null, msg);
      this.setImg($('nextImg'), $('nextMsg'), null, '');
      $('blackBadge').classList.add('hidden');
      return;
    }
    const cur = this.shownIndex();
    if (this.isHidden(cur)) this.setImg($('currentImg'), $('currentMsg'), null, `Slide ${cur} (hidden slide)`);
    else this.setImg($('currentImg'), $('currentMsg'), this.imageFor(cur), String(cur || '–'), true);
    const n = this.nextVisible(cur);
    if (n > s.count) this.setImg($('nextImg'), $('nextMsg'), null, s.showing ? 'End of show' : 'Last slide');
    else if (this.isHidden(n)) this.setImg($('nextImg'), $('nextMsg'), null, `Slide ${n} (hidden)`);
    else this.setImg($('nextImg'), $('nextMsg'), this.imageFor(n), String(n), true);
    $('blackBadge').classList.toggle('hidden', !s.black);
  },

  renderNotes() {
    const el = $('notes');
    const s = this.st;
    if (!s || !s.pres) {
      el.textContent = '';
      return;
    }
    const idx = this.shownIndex();
    const text = this.notes[String(idx)];
    const rich = this.rich[String(idx)];
    if (rich && rich.length) {
      el.classList.remove('empty');
      el.replaceChildren(renderRichNotes(rich));
    } else if (text === undefined) {
      el.textContent = s.loading ? 'Loading notes…' : '…';
      el.classList.add('empty');
    } else if (!text) {
      el.textContent = 'No notes for this slide.';
      el.classList.add('empty');
    } else {
      el.textContent = text;
      el.classList.remove('empty');
    }
    if (this.lastShownIndex !== idx) {
      el.scrollTop = 0;
      this.lastShownIndex = idx;
    }
  },

  renderTools() {
    const s = this.st;
    const ok = !!(this.transport && s && s.pres);
    $('startBtn').disabled = !ok || s.showing;
    $('startHereBtn').disabled = !ok || s.showing;
    $('endBtn').disabled = !ok || !s.showing;
    $('blackBtn').disabled = !ok || !s.showing;
    $('blackBtn').classList.toggle('on', ok && s.black);
    $('gridBtn').disabled = !ok;
    $('prevBtn').disabled = !ok;
    $('nextBtn').disabled = !ok;
    $('reloadBtn').disabled = !ok;
  },

  renderGrid() {
    const s = this.st;
    const grid = $('grid');
    grid.innerHTML = '';
    if (!s || !s.pres) return;
    const secs = (this.deckInfo && this.deckInfo.deck === this.deck && this.deckInfo.sections) || [];
    for (let i = 1; i <= s.count; i++) {
      const sec = secs.length > 1 && secs.find((x) => x.first === i);
      if (sec) {
        const h = document.createElement('div');
        h.className = 'gsec';
        h.textContent = sec.name;
        grid.appendChild(h);
      }
      const b = document.createElement('button');
      b.className = 'gcell' + (i === this.shownIndex() ? ' cur' : '') + (this.isHidden(i) ? ' hid' : '');
      const url = this.imageFor(i);
      if (url) {
        const img = document.createElement('img');
        img.src = url;
        img.alt = `Slide ${i}`;
        b.appendChild(img);
      } else {
        const ph = document.createElement('div');
        ph.className = 'ph';
        ph.textContent = String(i);
        b.appendChild(ph);
      }
      const num = document.createElement('span');
      num.className = 'num';
      num.textContent = String(i);
      b.appendChild(num);
      b.addEventListener('click', () => {
        this.goto(i);
        $('gridView').classList.add('hidden');
      });
      grid.appendChild(b);
    }
  },

  // --- presentations ---------------------------------------------------------

  openPresentations() {
    const list = $('presList');
    list.innerHTML = '';
    const s = this.st;
    const add = (label, sub, on, cmd) => {
      const b = document.createElement('button');
      b.className = 'presitem' + (on ? ' on' : '');
      const t = document.createElement('span');
      t.textContent = label;
      b.appendChild(t);
      if (sub) {
        const d = document.createElement('small');
        d.textContent = sub;
        b.appendChild(d);
      }
      b.addEventListener('click', () => {
        this.send(cmd);
        $('presView').classList.add('hidden');
        toast('Switching presentation…');
      });
      list.appendChild(b);
    };
    add('Automatic', 'Follow PowerPoint: the presentation in the slide show or in front', s && s.auto, 'use auto');
    for (const p of this.plist) add(p.name, p.current ? 'Now controlled' : '', s && !s.auto && p.current, `use ${p.id}`);
    $('presView').classList.remove('hidden');
  },

  // --- media -----------------------------------------------------------------

  renderMedia() {
    const box = $('mediaBars');
    const s = this.st;
    const items = s && s.showing ? this.media : [];
    if (box.childElementCount !== items.length || box.dataset.key !== items.map((m) => m.k).join(',')) {
      box.innerHTML = '';
      box.dataset.key = items.map((m) => m.k).join(',');
      for (const m of items) {
        const bar = document.createElement('div');
        bar.className = 'mediabar';
        bar.dataset.k = m.k;
        const mk = (cls, label, title, fn) => {
          const b = document.createElement('button');
          b.className = 'mbtn ' + cls;
          b.textContent = label;
          b.title = title;
          b.addEventListener('click', (e) => { e.stopPropagation(); fn(); });
          bar.appendChild(b);
          return b;
        };
        mk('play', '▶︎', 'Play / pause', () => {
          const cur = this.media.find((x) => x.k === m.k);
          this.send(`media ${cur && cur.st === 'playing' ? 'pause' : 'play'} ${m.k}`);
        });
        mk('', '⟲', 'From the start', () => { this.send(`media seek ${m.k} 0`); this.send(`media play ${m.k}`); });
        mk('', '−10', 'Back 10 seconds', () => this.send(`media rel ${m.k} -10000`));
        mk('', '+10', 'Forward 10 seconds', () => this.send(`media rel ${m.k} 10000`));
        const info = document.createElement('span');
        info.className = 'minfo';
        bar.appendChild(info);
        box.appendChild(bar);
      }
    }
    this.tickMedia();
  },

  /** Updates play buttons and positions (the clock runs locally while playing). */
  tickMedia() {
    for (const bar of $('mediaBars').children) {
      const m = this.media.find((x) => String(x.k) === bar.dataset.k);
      if (!m) continue;
      const pos = m.pos + (m.st === 'playing' ? Date.now() - m.at : 0);
      bar.querySelector('.play').textContent = m.st === 'playing' ? '❚❚' : '▶︎';
      const sec = Math.floor(pos / 1000);
      const label = m.kind === 'sound' ? 'Audio' : 'Video';
      bar.querySelector('.minfo').textContent = `${label} ${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
    }
  },

  // --- laser pointer & pen ---------------------------------------------------

  tool: null, // null | 'laser' | 'pen'
  penColor: '#ff2d2d',

  setTool(tool, silent) {
    if (this.tool === tool) return;
    this.tool = tool;
    $('current').classList.toggle('drawing', !!tool);
    $('laserBtn').classList.toggle('on', tool === 'laser');
    $('penBtn').classList.toggle('on', tool === 'pen');
    $('penColors').classList.toggle('hidden', tool !== 'pen');
    $('laserDot').classList.add('hidden');
    if (!silent) Activity.log(tool ? `Tool: ${tool === 'laser' ? 'laser pointer' : 'pen'}` : 'Tool: off');
  },

  renderSlideTools() {
    const s = this.st;
    const on = !!(this.transport && s && s.showing && !s.black);
    $('slideTools').classList.toggle('hidden', !on);
    const ink = !!(s && (s.ink || (this.inkSlides.get(s.index) || []).length));
    $('eraseBtn').classList.toggle('hidden', !on || !ink);
  },

  /** Area of the slide inside the current-slide box (the image is letterboxed). */
  slideRect() {
    const box = $('current').getBoundingClientRect();
    const img = $('currentImg');
    const aspect = img.naturalWidth && img.getAttribute('src') ? img.naturalWidth / img.naturalHeight : 16 / 9;
    let w = box.width;
    let h = w / aspect;
    if (h > box.height) { h = box.height; w = h * aspect; }
    return { left: box.left + (box.width - w) / 2, top: box.top + (box.height - h) / 2, width: w, height: h, boxLeft: box.left, boxTop: box.top };
  },

  /** Normalised slide coordinates (0…1) for a pointer event, or null outside the slide. */
  toSlide(e, clamp) {
    const r = this.slideRect();
    let x = (e.clientX - r.left) / r.width;
    let y = (e.clientY - r.top) / r.height;
    if (!clamp && (x < -0.02 || x > 1.02 || y < -0.02 || y > 1.02)) return null;
    x = Math.min(1, Math.max(0, x));
    y = Math.min(1, Math.max(0, y));
    return { x, y };
  },

  enc(p) { return `${Math.round(p.x * 10000)},${Math.round(p.y * 10000)}`; },

  pendingPoints: [],
  pendingLaser: null,
  flushTimer: null,
  stroke: null,

  /** Pointer moves are batched (about 25 per second) so Bluetooth isn't flooded. */
  scheduleFlush() {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flushPointer();
    }, 40);
  },

  flushPointer() {
    if (!this.transport) return;
    if (this.pendingLaser) {
      this.transport.send(`lz ${this.enc(this.pendingLaser)}`, true);
      this.pendingLaser = null;
    }
    while (this.pendingPoints.length) {
      const batch = this.pendingPoints.splice(0, 12);
      this.transport.send(`pm ${batch.map((p) => this.enc(p)).join(';')}`, true);
    }
  },

  pointerDown(e) {
    if (!this.tool) return;
    const p = this.toSlide(e, false);
    if (!p) return;
    e.preventDefault();
    $('current').setPointerCapture(e.pointerId);
    if (this.tool === 'laser') {
      this.pendingLaser = p;
      this.showLaser(p);
      this.scheduleFlush();
    } else {
      this.flushPointer();
      this.stroke = { color: this.penColor, points: [p] };
      const list = this.inkSlides.get(this.st.index) || [];
      list.push(this.stroke);
      this.inkSlides.set(this.st.index, list);
      this.transport.send(`pd ${this.penColor} ${this.enc(p)}`, true);
      this.renderInk();
      this.renderSlideTools();
    }
  },

  pointerMove(e) {
    if (!this.tool || !$('current').hasPointerCapture(e.pointerId)) return;
    const p = this.toSlide(e, true);
    e.preventDefault();
    if (this.tool === 'laser') {
      this.pendingLaser = p;
      this.showLaser(p);
    } else if (this.stroke) {
      const last = this.stroke.points[this.stroke.points.length - 1];
      if (Math.abs(last.x - p.x) + Math.abs(last.y - p.y) < 0.002) return;
      this.stroke.points.push(p);
      this.pendingPoints.push(p);
      this.renderInk();
    }
    this.scheduleFlush();
  },

  pointerUp(e) {
    if (!this.tool) return;
    clearTimeout(this.flushTimer);
    this.flushTimer = null;
    this.flushPointer();
    if (this.tool === 'laser') {
      this.transport.send('lz off', true);
      $('laserDot').classList.add('hidden');
    } else if (this.stroke) {
      this.transport.send('pu', true);
      this.stroke = null;
    }
  },

  showLaser(p) {
    const r = this.slideRect();
    const dot = $('laserDot');
    dot.style.left = `${r.left - r.boxLeft + p.x * r.width}px`;
    dot.style.top = `${r.top - r.boxTop + p.y * r.height}px`;
    dot.classList.remove('hidden');
  },

  eraseInk() {
    this.inkSlides.delete(this.st.index);
    this.send('ink clear');
    this.renderInk();
    this.renderSlideTools();
  },

  /** Draws this device's strokes for the shown slide on the canvas over the slide image. */
  renderInk() {
    const canvas = $('inkCanvas');
    const box = $('current');
    const dpr = window.devicePixelRatio || 1;
    const w = Math.round(box.clientWidth * dpr);
    const h = Math.round(box.clientHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, w, h);
    const strokes = (this.st && this.st.showing && this.inkSlides.get(this.st.index)) || [];
    if (!strokes.length) return;
    const r = this.slideRect();
    const ox = (r.left - r.boxLeft) * dpr;
    const oy = (r.top - r.boxTop) * dpr;
    const sw = r.width * dpr;
    const sh = r.height * dpr;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.lineWidth = Math.max(2, sh * 0.007);
    for (const st of strokes) {
      ctx.strokeStyle = st.color;
      ctx.fillStyle = st.color;
      ctx.beginPath();
      st.points.forEach((p, i) => (i ? ctx.lineTo(ox + p.x * sw, oy + p.y * sh) : ctx.moveTo(ox + p.x * sw, oy + p.y * sh)));
      if (st.points.length === 1) {
        ctx.arc(ox + st.points[0].x * sw, oy + st.points[0].y * sh, ctx.lineWidth / 2, 0, Math.PI * 2);
        ctx.fill();
      } else {
        ctx.stroke();
      }
    }
  },

  // --- PIN ------------------------------------------------------------------

  showPin(err) {
    this.pinPromptOpen = true;
    $('pinError').textContent = err || '';
    $('pinInput').value = '';
    $('pinView').classList.remove('hidden');
    setTimeout(() => $('pinInput').focus(), 50);
  },

  hidePin() {
    this.pinPromptOpen = false;
    $('pinView').classList.add('hidden');
  },

  submitPin() {
    const v = $('pinInput').value.replace(/\D/g, '');
    if (v.length !== 4) {
      $('pinError').textContent = 'The PIN has 4 digits.';
      return;
    }
    this.pin = v;
    store.set('pin', v);
    $('pinError').textContent = 'Checking…';
    this.authSentAt = Date.now();
    if (this.transport) this.transport.sendAuth(v);
  },
};

// ---------------------------------------------------------------------------
// Formatted notes
// ---------------------------------------------------------------------------

/** Makes dark text colours readable on the dark notes background. */
function readableColor(hex) {
  const v = parseInt(hex.slice(1), 16);
  let r = (v >> 16) & 255;
  let g = (v >> 8) & 255;
  let b = v & 255;
  const lum = (x, y, z) => (0.2126 * x + 0.7152 * y + 0.0722 * z) / 255;
  for (let i = 0; i < 6 && lum(r, g, b) < 0.45; i++) {
    r = Math.round(r + (255 - r) * 0.35);
    g = Math.round(g + (255 - g) * 0.35);
    b = Math.round(b + (255 - b) * 0.35);
  }
  return `rgb(${r}, ${g}, ${b})`;
}

/** @param {{l?: number, b?: string, n?: string, r: [string, string][]}[]} paras */
function renderRichNotes(paras) {
  const frag = document.createDocumentFragment();
  for (const p of paras) {
    const div = document.createElement('div');
    div.className = 'np';
    div.style.paddingLeft = `${((p.l || 1) - 1) * 1.3 + (p.b ? 1.3 : 0)}em`;
    if (p.b) {
      const bullet = document.createElement('span');
      bullet.className = 'bullet';
      // Symbol-font bullets (Wingdings etc.) don't map to readable characters; use a dot then.
      const ch = (p.n || '').trim();
      bullet.textContent = p.b === '#' ? `${p.n}.` : /^[•◦▪▫■□●○–—\-➢➤►✓✔*]$/.test(ch) ? ch : '•';
      div.appendChild(bullet);
    }
    for (const [text, style] of p.r) {
      const span = document.createElement('span');
      span.textContent = text;
      if (style.includes('b')) span.style.fontWeight = '700';
      if (style.includes('i')) span.style.fontStyle = 'italic';
      if (style.includes('u')) span.style.textDecoration = 'underline';
      const m = style.match(/#[0-9a-f]{6}/i);
      if (m) span.style.color = readableColor(m[0]);
      div.appendChild(span);
    }
    if (!p.r.some(([t]) => t.trim())) div.appendChild(document.createElement('br'));
    frag.appendChild(div);
  }
  return frag;
}

// ---------------------------------------------------------------------------
// Settings: storage and activity
// ---------------------------------------------------------------------------

const Panels = {
  async renderStorage() {
    const el = $('storageInfo');
    const s = await SlideStore.stats();
    let txt = s.count
      ? `${fmtBytes(s.bytes)} used by ${s.count} slide${s.count === 1 ? '' : 's'} from ${s.decks} presentation${s.decks === 1 ? '' : 's'}.`
      : 'No slides stored yet.';
    const st = App.st;
    if (st && st.pres && st.count) {
      const stored = App.imageInfo.size;
      txt += ` Current presentation: ${stored} of ${st.count - (st.hidden || []).length} slides loaded.`;
    }
    if (SlideStore.failed) txt = 'Storage is not available in this browser (private mode?).';
    el.textContent = txt;
    $('clearStoreBtn').disabled = !s.count;
  },

  async clearStorage() {
    const s = await SlideStore.stats();
    if (!confirm(`Delete ${s.count} stored slides (${fmtBytes(s.bytes)}) from this device?\nThey will be downloaded again from the Mac when needed.`)) return;
    await SlideStore.clear();
    Activity.log(`Deleted ${s.count} stored slides (${fmtBytes(s.bytes)})`);
    toast('Stored slides deleted');
    this.renderStorage();
  },

  activityOpen: false,
  lastLogLen: -1,

  openActivity() {
    this.activityOpen = true;
    this.lastLogLen = -1;
    $('activityView').classList.remove('hidden');
    this.renderActivity(true);
  },

  closeActivity() {
    this.activityOpen = false;
    $('activityView').classList.add('hidden');
  },

  async renderActivity(force) {
    if (!this.activityOpen) return;
    const a = Activity.stats;
    const t = App.transport;
    const s = App.st;
    const esc = (x) => String(x).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
    const rows = [];
    const row = (k, v) => rows.push(`<div class="k">${esc(k)}</div><div class="v">${esc(v)}</div>`);

    row('Connection', t
      ? `${t.kind === 'bluetooth' ? 'Bluetooth' : 'Network'} · ${App.connState}${a.connectedAt ? ` · ${fmtDuration(Date.now() - a.connectedAt)}` : ''} · ${a.reconnects} reconnect${a.reconnects === 1 ? '' : 's'}`
      : 'not connected');
    row('Received', `${fmtBytes(a.bytesIn)}${a.framesIn ? ` · ${a.framesIn.toLocaleString()} packets (max ${a.maxFrame} B)` : ''}`);
    row('Sent', `${fmtBytes(a.bytesOut)} · ${a.commandsOut} command${a.commandsOut === 1 ? '' : 's'}`);
    row('Speed now', `${fmtBytes(Activity.speed())}/s`);
    if (s && s.pres) {
      const visible = s.count - (s.hidden || []).length;
      const fromStore = [...App.imageInfo.values()].filter((x) => x.source === 'store').length;
      const downloaded = [...App.imageInfo.values()].filter((x) => x.source === 'download').length;
      row('Slides', `${App.images.size} / ${visible} on this device · ${fromStore} from storage · ${downloaded} downloaded`);
      const missing = App.missingSlides();
      const inflight = [...App.inflight];
      row('Downloading', missing.length
        ? `${inflight.length ? `now: ${inflight.join(', ')}` : 'waiting'} · ${missing.length} to go`
        : App.storeLoading ? 'checking storage…' : 'done');
    }
    if (a.imagesDownloaded) {
      row('Avg. image', `${fmtBytes(a.imageBytes / a.imagesDownloaded)} · ${(a.imageMs / a.imagesDownloaded / 1000).toFixed(2)} s`);
    }
    const fmt = App.deckInfo ? App.deckInfo.fmt.toUpperCase() : '–';
    row('Format', `${fmt}${t && t.kind === 'bluetooth' ? ` · ${QUALITY_NAMES[prefs.quality]} quality` : ''} · this device shows ${App.formats.join(', ').toUpperCase()}`);
    if (force) {
      const st = await SlideStore.stats();
      this.storageLine = `${fmtBytes(st.bytes)} · ${st.count} slides · ${st.decks} presentation${st.decks === 1 ? '' : 's'}`;
    }
    row('Storage', this.storageLine || '…');
    row('App', `v${APP_VERSION}`);
    $('actStats').innerHTML = rows.join('');

    if (Activity.entries.length !== this.lastLogLen || force) {
      const logEl = $('actLog');
      const atBottom = logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 40;
      this.lastLogLen = Activity.entries.length;
      logEl.innerHTML = Activity.entries
        .map((e) => `<div class="${e.kind}"><span class="t">${fmtTime(e.t)}</span> ${esc(e.msg)}</div>`)
        .join('');
      if (atBottom || force) logEl.scrollTop = logEl.scrollHeight;
    }
  },

  async copyLog() {
    const text = `PPT Remote v${APP_VERSION} activity\n${Activity.text()}`;
    try {
      await navigator.clipboard.writeText(text);
      toast('Log copied');
    } catch {
      const ta = document.createElement('textarea');
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      ta.remove();
      toast('Log copied');
    }
  },
};

// ---------------------------------------------------------------------------
// Timer, clock, wake lock, toast
// ---------------------------------------------------------------------------

const Timer = {
  elapsed: 0,
  startedAt: 0,
  get running() { return this.startedAt > 0; },
  now() { return this.elapsed + (this.running ? Date.now() - this.startedAt : 0); },
  toggle() {
    if (this.running) {
      this.elapsed = this.now();
      this.startedAt = 0;
    } else {
      this.startedAt = Date.now();
    }
    this.render();
  },
  restart() {
    this.elapsed = 0;
    this.startedAt = Date.now();
    this.render();
  },
  reset() {
    this.elapsed = 0;
    this.startedAt = 0;
    this.render();
  },
  render() {
    const t = Math.floor(this.now() / 1000);
    const h = Math.floor(t / 3600);
    const m = Math.floor((t % 3600) / 60);
    const sec = t % 60;
    const pad = (x) => String(x).padStart(2, '0');
    $('timer').textContent = (h ? h + ':' : '') + pad(m) + ':' + pad(sec);
    $('timer').classList.toggle('running', this.running);
  },
};

function renderClock() {
  const d = new Date();
  $('clock').textContent = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

let wakeLock = null;
async function keepAwake() {
  try {
    if ('wakeLock' in navigator && !wakeLock) {
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', () => { wakeLock = null; });
    }
  } catch { /* not supported */ }
}

let toastTimer = null;
function toast(text) {
  const el = $('toast');
  el.textContent = text;
  el.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), 1800);
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

function pressNav(btn, cmd) {
  App.pendingGoto = null;
  App.send(cmd);
  btn.classList.add('busy');
  setTimeout(() => btn.classList.remove('busy'), 250);
}

function setFontSize(px) {
  prefs.fontSize = Math.max(14, Math.min(48, px));
  store.set('fontSize', prefs.fontSize);
  document.documentElement.style.setProperty('--notes-size', prefs.fontSize + 'px');
}

function init() {
  // PIN can arrive in the URL from the QR code on the Mac.
  const params = new URLSearchParams(location.search);
  const urlPin = params.get('pin');
  if (urlPin && /^\d{4}$/.test(urlPin)) {
    App.pin = urlPin;
    store.set('pin', urlPin);
    history.replaceState(null, '', location.pathname);
  }

  Activity.log(`PPT Remote v${APP_VERSION} started`);
  ImageFormats.detect().then((list) => {
    App.formats = list;
    Activity.log(`This browser can show: ${list.join(', ').toUpperCase()}`);
  });

  setFontSize(prefs.fontSize);
  $('qualitySel').value = prefs.quality;
  $('swipeChk').checked = prefs.swipe;
  $('autoTimerChk').checked = prefs.autoTimer;
  $('pageUrl').textContent = location.origin + location.pathname;
  $('versionInfo').textContent = `PPT Remote v${APP_VERSION}`;

  const bleOK = BleTransport.available();
  $('bleConnectBtn').classList.toggle('hidden', !bleOK);
  $('bleUnavailable').classList.toggle('hidden', bleOK);

  HttpTransport.probe().then(async (served) => {
    $('netConnectBtn').classList.toggle('hidden', !served);
    $('netHint').classList.toggle('hidden', served || !bleOK);
    if (served && (!bleOK || store.get('mode', '') === 'network')) {
      await ImageFormats.detect();
      App.connectNetwork();
    }
  });

  $('bleConnectBtn').addEventListener('click', () => App.connectBluetooth());
  $('netConnectBtn').addEventListener('click', async () => { await ImageFormats.detect(); App.connectNetwork(); });

  $('prevBtn').addEventListener('click', (e) => pressNav(e.currentTarget, 'prev'));
  $('nextBtn').addEventListener('click', (e) => pressNav(e.currentTarget, 'next'));
  $('startBtn').addEventListener('click', () => { App.send('start'); toast('Starting slide show…'); });
  $('startHereBtn').addEventListener('click', () => { App.send('starthere'); toast('Starting from this slide…'); });
  $('endBtn').addEventListener('click', () => {
    if (confirm('End the slide show?')) App.send('end');
  });
  $('blackBtn').addEventListener('click', () => App.send('black'));
  $('gridBtn').addEventListener('click', () => {
    App.renderGrid();
    $('gridView').classList.remove('hidden');
    const cur = $('grid').querySelector('.cur');
    if (cur) cur.scrollIntoView({ block: 'center' });
  });
  $('gridClose').addEventListener('click', () => $('gridView').classList.add('hidden'));
  $('deckBtn').addEventListener('click', () => App.openPresentations());
  $('presClose').addEventListener('click', () => $('presView').classList.add('hidden'));

  // Laser pointer and pen on the current slide.
  $('laserBtn').addEventListener('click', (e) => { e.stopPropagation(); App.setTool(App.tool === 'laser' ? null : 'laser'); });
  $('penBtn').addEventListener('click', (e) => { e.stopPropagation(); App.setTool(App.tool === 'pen' ? null : 'pen'); });
  $('eraseBtn').addEventListener('click', (e) => { e.stopPropagation(); App.eraseInk(); });
  for (const sw of document.querySelectorAll('.swatch')) {
    sw.addEventListener('click', (e) => {
      e.stopPropagation();
      App.penColor = sw.dataset.color;
      document.querySelectorAll('.swatch').forEach((x) => x.classList.toggle('on', x === sw));
    });
  }
  const cur = $('current');
  const onSlideTools = (e) => e.target.closest('.slidetools, .mediabars');
  cur.addEventListener('pointerdown', (e) => { if (!onSlideTools(e)) App.pointerDown(e); });
  cur.addEventListener('pointermove', (e) => App.pointerMove(e));
  cur.addEventListener('pointerup', (e) => App.pointerUp(e));
  cur.addEventListener('pointercancel', (e) => App.pointerUp(e));

  $('fontUp').addEventListener('click', () => setFontSize(prefs.fontSize + 2));
  $('fontDown').addEventListener('click', () => setFontSize(prefs.fontSize - 2));

  $('settingsBtn').addEventListener('click', () => {
    Panels.renderStorage();
    $('settingsView').classList.remove('hidden');
  });
  $('settingsClose').addEventListener('click', () => $('settingsView').classList.add('hidden'));
  $('connBtn').addEventListener('click', () => {
    if (!App.transport) App.showConnect('');
    else $('settingsBtn').click();
  });
  $('qualitySel').addEventListener('change', (e) => {
    prefs.quality = e.target.value;
    store.set('quality', prefs.quality);
    Activity.log(`Bluetooth image quality: ${QUALITY_NAMES[prefs.quality]}`);
    if (App.transport && App.transport.kind === 'bluetooth') {
      App.send('quality ' + prefs.quality);
      if (App.inflight.size) App.send('imgclear');
      App.resetDeck(App.deck);
      App.send('hello');
      App.loadFromStore(true);
    }
  });
  $('swipeChk').addEventListener('change', (e) => { prefs.swipe = e.target.checked; store.set('swipe', prefs.swipe); });
  $('autoTimerChk').addEventListener('change', (e) => { prefs.autoTimer = e.target.checked; store.set('autoTimer', prefs.autoTimer); });
  $('reloadBtn').addEventListener('click', () => {
    App.send('reload');
    toast('Reloading slides…');
    $('settingsView').classList.add('hidden');
  });
  $('changePinBtn').addEventListener('click', () => {
    $('settingsView').classList.add('hidden');
    App.showPin('');
  });
  $('disconnectBtn').addEventListener('click', () => {
    $('settingsView').classList.add('hidden');
    App.disconnect();
  });
  $('clearStoreBtn').addEventListener('click', () => Panels.clearStorage());
  $('activityBtn').addEventListener('click', () => Panels.openActivity());
  $('activityClose').addEventListener('click', () => Panels.closeActivity());
  $('copyLogBtn').addEventListener('click', () => Panels.copyLog());
  $('clearLogBtn').addEventListener('click', () => {
    Activity.entries = [];
    Panels.renderActivity(true);
  });

  $('pinOk').addEventListener('click', () => App.submitPin());
  $('pinInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') App.submitPin(); });
  $('pinInput').addEventListener('input', (e) => {
    if (e.target.value.replace(/\D/g, '').length === 4) App.submitPin();
  });
  $('pinCancel').addEventListener('click', () => {
    App.hidePin();
    if (!App.st) App.disconnect();
  });

  // Timer: tap = start/pause, long press = reset.
  let holdTimer = null;
  let held = false;
  const timerEl = $('timer');
  timerEl.addEventListener('pointerdown', () => {
    held = false;
    holdTimer = setTimeout(() => { held = true; Timer.reset(); toast('Timer reset'); }, 700);
  });
  const cancelHold = () => clearTimeout(holdTimer);
  timerEl.addEventListener('pointerup', cancelHold);
  timerEl.addEventListener('pointerleave', cancelHold);
  timerEl.addEventListener('click', () => { if (!held) Timer.toggle(); });

  // Swipe on the current slide.
  let touchStart = null;
  $('current').addEventListener('touchstart', (e) => {
    const t = e.changedTouches[0];
    touchStart = { x: t.clientX, y: t.clientY };
  }, { passive: true });
  $('current').addEventListener('touchend', (e) => {
    if (!touchStart || !prefs.swipe || App.tool) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - touchStart.x;
    const dy = t.clientY - touchStart.y;
    touchStart = null;
    if (Math.abs(dx) > 60 && Math.abs(dy) < 60) { App.pendingGoto = null; App.send(dx < 0 ? 'next' : 'prev'); }
  }, { passive: true });

  // Keyboard (useful with a keyboard case or when testing on a laptop).
  document.addEventListener('keydown', (e) => {
    if (e.target && e.target.tagName === 'INPUT') return;
    if (['ArrowRight', 'ArrowDown', 'PageDown', ' ', 'Enter'].includes(e.key)) { App.pendingGoto = null; App.send('next'); e.preventDefault(); }
    else if (['ArrowLeft', 'ArrowUp', 'PageUp', 'Backspace'].includes(e.key)) { App.pendingGoto = null; App.send('prev'); e.preventDefault(); }
    else if (e.key === 'b' || e.key === '.') App.send('black');
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && App.transport) keepAwake();
  });

  // Bluetooth watchdog: if an image request stalls, ask again.
  setInterval(() => {
    if (App.transport && App.transport.kind === 'bluetooth' && App.inflight.size && Date.now() - App.lastImageAt > 20000) {
      Activity.log(`No image received for 20 s, asking again`, 'error');
      App.inflight.clear();
      App.scheduleImages(false);
    }
    if (App.pendingGoto && Date.now() > App.pendingGoto.until) {
      App.pendingGoto = null;
      App.render();
    }
  }, 2000);

  setInterval(() => {
    Timer.render();
    renderClock();
    App.tickMedia();
    if (Panels.activityOpen) Panels.renderActivity(false);
  }, 500);
  window.addEventListener('resize', () => { App.renderSlides(); App.renderInk(); });
  $('currentImg').addEventListener('load', () => App.renderInk());
  Timer.render();
  renderClock();
  App.render();

  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    const hadController = !!navigator.serviceWorker.controller;
    navigator.serviceWorker.register('sw.js').catch(() => {});
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (hadController) {
        Activity.log('A new version of the app was downloaded; it is used after the next reload');
      }
    });
  }
}

init();
