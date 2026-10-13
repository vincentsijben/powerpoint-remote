/* PPT Remote – web app for tablets and phones. Talks to the Mac helper over Bluetooth (Web Bluetooth) or HTTP. */
'use strict';

const APP_VERSION = '1.11';

function clearSelection() {
  const sel = window.getSelection && window.getSelection();
  if (sel && sel.rangeCount) sel.removeAllRanges();
}

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
  vibrate: store.get('vibrate', true),
};

const isSmallScreen = () => matchMedia('(max-width: 600px), (max-height: 500px)').matches;
const isPhoneLandscape = () => matchMedia('(orientation: landscape) and (max-height: 500px)').matches;

/** Short vibration (Android; iPhone/iPad browsers don't support it). */
function buzz(pattern) {
  if (prefs.vibrate && navigator.vibrate) {
    try { navigator.vibrate(pattern); } catch { /* ignore */ }
  }
}

/** Commands that must reach the Mac; a failure shows an alert. */
const IMPORTANT = /^(next|prev|first|last|goto|start|starthere|end|black|reload|use|media|snd|wb|ink)\b/;

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
  /**
   * @param {boolean} fast  write without waiting for an acknowledgement (pointer moves)
   * @returns {Promise<boolean>} whether the Mac acknowledged the command
   */
  send(text, fast) {
    const bytes = new TextEncoder().encode(text);
    let delivered = false;
    // GATT operations must not overlap, so writes are chained (this also keeps pointer messages in order).
    this.writeChain = this.writeChain.then(async () => {
      const c = this.cmdChar;
      if (!c || !this.device || !this.device.gatt.connected) {
        if (!fast) Activity.log(`Not sent (not connected): ${text.startsWith('auth') ? 'auth' : text}`, 'error');
        return;
      }
      Activity.sent(bytes.length);
      try {
        if (fast && c.writeValueWithoutResponse) {
          await c.writeValueWithoutResponse(bytes);
        } else {
          const w = c.writeValueWithResponse ? c.writeValueWithResponse(bytes) : c.writeValue(bytes);
          await Promise.race([w, sleep(3000).then(() => { throw new Error('no answer within 3 s'); })]);
        }
        delivered = true;
      } catch (err) {
        Activity.log(`Command "${text.split(' ')[0]}" failed: ${err && err.message}`, 'error');
      }
    });
    return this.writeChain.then(() => delivered);
  }

  /** Binary data (pieces of the microphone recording), without waiting for an acknowledgement. */
  sendBinary(bytes) {
    let delivered = false;
    this.writeChain = this.writeChain.then(async () => {
      const c = this.cmdChar;
      if (!c || !this.device || !this.device.gatt.connected || !c.writeValueWithoutResponse) return;
      try {
        await c.writeValueWithoutResponse(bytes);
        Activity.sent(bytes.length);
        delivered = true;
      } catch (err) {
        Activity.log(`Microphone upload: ${err && err.message}`, 'error');
      }
    });
    return this.writeChain.then(() => delivered);
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
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 4000);
    this.chain = (this.chain || Promise.resolve())
      .then(() => fetch(`api/cmd?${q}`, { method: 'POST', headers: this.headers(), cache: 'no-store', signal: ctrl.signal }))
      .then((r) => r.ok)
      .catch((e) => {
        Activity.log(`Command "${c}" failed: ${e.message}`, 'error');
        return false;
      })
      .finally(() => clearTimeout(timer));
    return this.chain;
  }

  async fetchSounds() {
    try {
      const { status, obj } = await this.getJSON('api/sounds');
      if (status === 200) this.h.message(obj);
    } catch { /* retried when the list changes */ }
  }

  disconnect() {
    this.running = false;
    Activity.log('Network: disconnected');
    this.h.status('disconnected');
  }
}

const Hub = {
  commands: new Set(['next', 'prev', 'first', 'last', 'goto', 'start', 'starthere', 'end', 'black', 'reload',
    'use', 'media', 'lz', 'pd', 'pm', 'pu', 'ink', 'sd', 'sm', 'wb', 'snd', 'sp', 'zm', 'rec']),
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
    const important = IMPORTANT.test(cmd);
    if (!this.transport) {
      if (important) this.deliveryFailed(cmd);
      return;
    }
    this.lastCmd = { cmd, at: Date.now() };
    if (cmd !== 'imgclear' && !cmd.startsWith('img ')) Activity.log(`→ ${cmd}`);
    const p = this.transport.send(cmd);
    if (important && p) p.then((ok) => { if (!ok) this.deliveryFailed(cmd); });
  },

  /** A command did not reach the Mac: show it clearly and vibrate, so the presenter notices. */
  deliveryFailed(cmd) {
    const names = { next: 'Next', prev: 'Previous', goto: 'Go to slide', start: 'Start', starthere: 'Start from here', end: 'End show', black: 'Black screen', snd: 'Sound', media: 'Video', wb: 'Whiteboard' };
    const label = names[cmd.split(' ')[0]] || cmd.split(' ')[0];
    const bar = $('alertBar');
    bar.textContent = `⚠ “${label}” didn’t reach the Mac. Check the connection.`;
    bar.classList.remove('hidden');
    clearTimeout(this.alertTimer);
    this.alertTimer = setTimeout(() => bar.classList.add('hidden'), 4000);
    buzz([90, 60, 90, 60, 90]);
    Activity.log(`Not delivered: ${cmd}`, 'error');
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
    } else if (obj.type === 'sounds') {
      this.onSounds(obj);
    } else if (obj.type === 'mack') {
      RemoteMic.onAck(obj);
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
    if (s.rec) this.recAt = Date.now();
    if (s.rec && prev && prev.rec && prev.rec.st !== s.rec.st) {
      Activity.log(`Recording: ${s.rec.st}${s.rec.st === 'off' && s.rec.file ? ` (saved "${s.rec.file}")` : ''}`);
      if (s.rec.st === 'off' && s.rec.file && prev.rec.st === 'saving') toast(`Recording saved on the Mac: ${s.rec.file}`);
    }
    if (s.inkpdf && s.inkpdf.last && prev && prev.inkpdf && prev.inkpdf.last !== s.inkpdf.last) {
      toast(`Drawings saved on the Mac: ${s.inkpdf.last}`);
      Activity.log(`Drawings saved as PDF: ${s.inkpdf.last}`);
    }
    if (s.rec && s.rec.err && prev && (!prev.rec || prev.rec.err !== s.rec.err)) toast(s.rec.err);
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
    if (prev && prev.index !== s.index && this.spotAt) this.showSpot(null);
    if (this.zoom && ((prev && prev.index !== s.index) || !s.showing || s.wb)) this.setZoom(null, false);
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
    RemoteMic.sync();
    if (!s.ink) this.inkSlides.delete(s.wb ? 'wb' : s.index);
    if (s.skey && s.skey !== this.soundsKey) this.requestSounds(s.skey);
    if (s.wb && !(prev && prev.wb)) Activity.log('Whiteboard on');
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
    const q = this.transport && this.transport.kind === 'network' ? 'net' : prefs.quality;
    return `${fmt}-${q}-${SlideStore.REV}`;
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
    const blob = new Blob([bytes], { type: mime });
    if (!(await canDecode(blob))) {
      this.imageFormatFailed(header.fmt, slide);
      return;
    }
    if (header.deck !== this.deck) return;
    const old = this.images.get(slide);
    if (old) URL.revokeObjectURL(old);
    this.images.set(slide, URL.createObjectURL(blob));
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
      key: header.key, variant: `${header.fmt}-${header.q}-${SlideStore.REV}`, data: bytes.slice().buffer, mime,
      deck: this.deck, name: this.st ? this.st.name : '', slide,
    });

    this.renderSlides();
    if (!$('gridView').classList.contains('hidden')) this.renderGrid();
    if (this.inflight.size === 0) this.scheduleImages(false);
  },

  /** The browser received an image it can't show: stop using that format and fetch the slides again. */
  imageFormatFailed(fmt, slide) {
    this.inflight.delete(slide);
    if (fmt && fmt !== 'jpeg' && !this.formats.includes(fmt)) {
      // Requested before we switched formats: it will be fetched again in the new format.
      this.scheduleImages(false);
      return;
    }
    if (!fmt || fmt === 'jpeg') {
      Activity.log(`Slide ${slide}: this device could not display the image`, 'error');
      this.failed.add(slide);
      this.scheduleImages(false);
      return;
    }
    this.formats = this.formats.filter((f) => f !== fmt);
    Activity.log(`This device can't display the Mac's ${fmt.toUpperCase()} images; switching to ${this.formats[0].toUpperCase()}`, 'error');
    if (this.inflight.size) this.send('imgclear');
    this.resetDeck(this.deck);
    this.deckInfo = null;
    if (this.transport && this.transport.kind === 'bluetooth') {
      this.send(`fmt ${this.formats.join(',')}`);
      this.send('hello');
    } else if (this.transport) {
      this.transport.fetchAllNotes();
      this.transport.fetchDeck();
    }
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
          if (deck !== this.deck) return undefined;
          if (r) return this.onImage(r.header, r.bytes, true); // wait for the decode check before "done"
          this.failed.add(next);
          Activity.log(`Slide ${next}: no image available`);
          return undefined;
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
    Rec.render();
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
    // Redraw ink only when the page or its drawings changed (state updates arrive often while drawing).
    const inkKey = `${this.inkPage()}|${(this.inkSlides.get(this.inkPage()) || []).length}|${s && s.showing}`;
    if (inkKey !== this.inkKey) {
      this.inkKey = inkKey;
      this.requestInk(true);
    }
    $('sectionName').textContent = this.sectionOf(this.shownIndex()) || '';
    $('bigNum').textContent = s && s.pres && s.count ? `${this.shownIndex()} / ${s.count}` : '';
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
    // Unchanged: keep the DOM (and the reader's scroll position) as it is.
    const notesKey = [idx, s.loading, text, rich];
    if (this.notesKey && notesKey.every((v, i) => v === this.notesKey[i])) return;
    this.notesKey = notesKey;
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
    $('soundsBtn').disabled = !this.transport || !this.sounds.length;
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

  // --- laser pointer, pen, shapes & whiteboard --------------------------------

  tool: null, // null | 'laser' | 'pen'
  shape: 'pen', // pen (freehand) | line | arrow | ellipse | rect
  penColor: '#ff2d2d',

  setTool(tool, silent) {
    if (this.tool === tool) return;
    this.tool = tool;
    this.activePointer = null;
    $('current').classList.toggle('drawing', !!tool);
    document.documentElement.classList.toggle('drawmode', !!tool);
    if (tool) clearSelection();
    $('laserBtn').classList.toggle('on', tool === 'laser');
    $('spotBtn').classList.toggle('on', tool === 'spot');
    $('penBtn').classList.toggle('on', tool === 'pen');
    $('penColors').classList.toggle('hidden', tool !== 'pen');
    $('spotSizesBox').classList.toggle('hidden', tool !== 'spot');
    $('zoomBtn').classList.toggle('on', tool === 'zoom');
    $('laserDot').classList.add('hidden');
    if (tool !== 'spot') this.spotOff();
    this.zoomPointers.clear();
    $('zoomRect').classList.add('hidden');
    if (tool === 'zoom') this.send('zm prep');
    this.renderZoomBox();
    // On phones the slide is small: drawing happens on the big, full-screen slide.
    if (tool && isSmallScreen() && !this.big) this.setBig(true, true);
    const names = { laser: 'laser pointer', spot: 'spotlight', zoom: 'zoom', pen: this.shape === 'pen' ? 'pen' : this.shape };
    if (!silent) Activity.log(tool ? `Tool: ${names[tool]}` : 'Tool: off');
  },

  setShape(shape) {
    this.shape = shape;
    document.querySelectorAll('.shape').forEach((x) => x.classList.toggle('on', x.dataset.shape === shape));
  },

  /** Ink is kept per page: a slide number, or 'wb' for the whiteboard. */
  inkPage() {
    return this.st && this.st.wb ? 'wb' : this.st ? this.st.index : 0;
  },

  toggleWhiteboard() {
    const on = !(this.st && this.st.wb);
    this.send(`wb ${on ? 'on' : 'off'}`);
    if (on) this.setTool('pen');
  },

  renderSlideTools() {
    const s = this.st;
    const on = !!(this.transport && s && s.showing && (!s.black || s.wb));
    $('slideTools').classList.toggle('hidden', !on);
    const ink = !!(s && (s.ink || (this.inkSlides.get(this.inkPage()) || []).length));
    $('eraseBtn').classList.toggle('hidden', !on || !ink);
    $('wbBtn').classList.toggle('on', !!(s && s.wb));
    $('zoomBtn').classList.toggle('hidden', !!(s && s.wb));
    this.renderZoomBox();
    $('fsBtn').classList.toggle('on', this.isBig());
    $('current').classList.toggle('wb', !!(s && s.showing && s.wb));
    if (!on && this.tool) this.setTool(null, true);
  },

  // --- big slide (full screen; automatic on phones in landscape) ---------------

  big: false,
  landscapeDismissed: false,

  isBig() {
    return this.big || (isPhoneLandscape() && !this.landscapeDismissed);
  },

  setBig(on, auto) {
    this.big = on;
    if (!on && isPhoneLandscape()) this.landscapeDismissed = true;
    if (!on) this.setTool(null, true);
    // Real full screen (hides the browser bars) where the browser allows it, e.g. Chrome on Android.
    const de = document.documentElement;
    if (on && !document.fullscreenElement && de.requestFullscreen && isSmallScreen()) de.requestFullscreen().catch(() => {});
    if (!on && document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(() => {});
    if (on && auto !== false && isSmallScreen() && !isPhoneLandscape() && !this.rotateHinted) {
      this.rotateHinted = true;
      $('rotateHint').classList.remove('hidden');
      setTimeout(() => $('rotateHint').classList.add('hidden'), 3500);
    }
    this.applyBig();
  },

  applyBig() {
    document.body.classList.toggle('bigslide', this.isBig());
    $('fsBtn').classList.toggle('on', this.isBig());
    const s = this.st;
    $('bigNum').textContent = s && s.pres && s.count ? `${this.shownIndex()} / ${s.count}` : '';
    requestAnimationFrame(() => { this.renderSlides(); this.applyZoomView(); });
  },

  /** Area of the slide inside the current-slide box (the image is letterboxed). */
  /** The slide as shown on this device: when zoomed in, the (bigger) slide of which only a part is visible. */
  slideRect() {
    const r = this.baseRect();
    const z = this.zoomRegion();
    if (!z) return r;
    const s = 1 / z.w;
    return { ...r, left: r.left - z.x * s * r.width, top: r.top - z.y * s * r.height, width: r.width * s, height: r.height * s, base: r };
  },

  /** Where the whole slide is shown inside the slide box (letterboxed). */
  baseRect() {
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
  pendingShapeEnd: null,
  pendingSpot: null,
  flushTimer: null,
  pointerBusy: false,
  stroke: null,

  /** Spotlight radius as a fraction of the slide height. */
  spotSizes: { s: 0.1, m: 0.16, l: 0.25 },
  spotSize: store.get('spotSize', 'm'),
  spotAt: null,

  /** Pointer moves are batched (about 25 per second) so Bluetooth isn't flooded. */
  scheduleFlush() {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      this.flushPointer(false);
    }, 40);
  },

  /**
   * Sends pending pointer updates. Only one batch is on its way at a time: while Bluetooth is busy,
   * points pile up and go together, instead of building a growing queue (which made writing lag).
   * @param {boolean} force  send everything now (pen lifted), keeping the order of messages
   */
  flushPointer(force) {
    const t = this.transport;
    if (!t) return;
    if (this.pointerBusy && !force) return;
    const msgs = [];
    if (this.pendingLaser) msgs.push(`lz ${this.enc(this.pendingLaser)}`);
    if (this.pendingSpot) msgs.push(`sp ${this.enc(this.pendingSpot)} ${Math.round(this.spotSizes[this.spotSize] * 10000)}`);
    if (this.pendingShapeEnd) msgs.push(`sm ${this.enc(this.pendingShapeEnd)}`);
    if (this.pendingZoom) msgs.push(`zm ${this.enc(this.pendingZoom)} ${Math.round(this.pendingZoom.s * 100)}`);
    if (msgs.length || this.pendingPoints.length) this.lastPointerAt = Date.now();
    this.pendingLaser = this.pendingSpot = this.pendingShapeEnd = this.pendingZoom = null;
    let pts = this.pendingPoints;
    this.pendingPoints = [];
    // Slow link: thin out a big backlog so the drawing on the projector catches up.
    if (!force && pts.length > 36) pts = pts.filter((_, i) => i % Math.ceil(pts.length / 24) === 0 || i === pts.length - 1);
    for (let i = 0; i < pts.length; i += 12) msgs.push(`pm ${pts.slice(i, i + 12).map((q) => this.enc(q)).join(';')}`);
    if (!msgs.length) return;
    let last;
    for (const m of msgs) last = t.send(m, true);
    this.pointerBusy = true;
    Promise.resolve(last).finally(() => {
      this.pointerBusy = false;
      if (this.pendingLaser || this.pendingSpot || this.pendingShapeEnd || this.pendingZoom || this.pendingPoints.length) this.scheduleFlush();
    });
  },

  /** All positions of a move, including the in-between ones the browser merged (Apple Pencil: up to 240/s). */
  eventPoints(e) {
    const list = e.getCoalescedEvents ? e.getCoalescedEvents() : [];
    return (list.length ? list : [e]).map((ev) => this.toSlide(ev, true));
  },

  activePointer: null,
  pencilUsed: false,

  /**
   * Palm rejection: once the Apple Pencil (or another stylus) has been used, finger and palm
   * touches no longer draw, and only one pointer draws at a time, so a resting hand can't
   * end or replace the stroke being written.
   */
  ownsPointer(e) {
    return this.activePointer === e.pointerId;
  },

  pointerDown(e) {
    if (!this.tool) return;
    clearSelection();
    if (this.tool === 'zoom') { this.zoomDown(e); return; }
    if (e.pointerType === 'pen') { this.pencilUsed = true; this.pencilAt = Date.now(); }
    else if (this.pencilUsed) return;
    if (this.activePointer !== null) {
      // A stylus wins over a touch that started first (the palm landing just before the tip).
      if (e.pointerType !== 'pen' || this.activePointerType === 'pen') return;
      this.endPointer();
    }
    const p = this.toSlide(e, false);
    if (!p) return;
    e.preventDefault();
    this.activePointer = e.pointerId;
    this.activePointerType = e.pointerType;
    try { $('current').setPointerCapture(e.pointerId); } catch { /* pointer already gone */ }
    if (this.tool === 'laser') {
      this.pendingLaser = p;
      this.showLaser(p);
      this.scheduleFlush();
      return;
    }
    if (this.tool === 'spot') {
      this.pendingSpot = p;
      this.showSpot(p);
      this.scheduleFlush();
      return;
    }
    this.flushPointer(true);
    const kind = this.shape;
    this.stroke = { kind, color: this.penColor, points: kind === 'pen' ? [p] : [p, p], drawn: 0 };
    const page = this.inkPage();
    const list = this.inkSlides.get(page) || [];
    const first = !list.length;
    list.push(this.stroke);
    this.inkSlides.set(page, list);
    if (kind === 'pen') this.transport.send(`pd ${this.penColor} ${this.enc(p)}`, true);
    else this.transport.send(`sd ${kind} ${this.penColor} ${this.enc(p)}`, true);
    this.requestInk(kind !== 'pen');
    if (first) this.renderSlideTools();
  },

  pointerMove(e) {
    if (this.tool === 'zoom') { this.zoomMove(e); return; }
    if (!this.tool || !this.ownsPointer(e)) return;
    e.preventDefault();
    if (e.pointerType === 'pen') this.pencilAt = Date.now();
    const pts = this.eventPoints(e);
    const p = pts[pts.length - 1];
    if (this.tool === 'laser') {
      this.pendingLaser = p;
      this.showLaser(p);
    } else if (this.tool === 'spot') {
      this.pendingSpot = p;
      this.showSpot(p);
    } else if (this.stroke && this.stroke.kind !== 'pen') {
      this.stroke.points[1] = p;
      this.pendingShapeEnd = p;
      this.requestInk(true);
    } else if (this.stroke) {
      for (const q of pts) {
        const last = this.stroke.points[this.stroke.points.length - 1];
        if (Math.abs(last.x - q.x) + Math.abs(last.y - q.y) < 0.0015) continue;
        this.stroke.points.push(q);
        this.pendingPoints.push(q);
      }
      this.requestInk(false);
    }
    this.scheduleFlush();
  },

  pointerUp(e) {
    if (this.tool === 'zoom') { this.zoomUp(e); return; }
    if (!this.tool || !this.ownsPointer(e)) return;
    this.endPointer();
  },

  endPointer() {
    this.activePointer = null;
    clearTimeout(this.flushTimer);
    this.flushTimer = null;
    this.flushPointer(true);
    if (this.tool === 'laser') {
      this.transport.send('lz off', true);
      $('laserDot').classList.add('hidden');
    } else if (this.stroke) {
      this.transport.send('pu', true);
      this.stroke = null;
    }
    // The spotlight stays where it was left, so you can talk about that part of the slide.
  },

  showLaser(p) {
    const r = this.slideRect();
    const dot = $('laserDot');
    dot.style.left = `${r.left - r.boxLeft + p.x * r.width}px`;
    dot.style.top = `${r.top - r.boxTop + p.y * r.height}px`;
    dot.classList.remove('hidden');
  },

  /** Darkens the slide on this device except a circle around the spotlight. */
  showSpot(p) {
    this.spotAt = p;
    const shade = $('spotShade');
    if (!p) {
      shade.classList.add('hidden');
      return;
    }
    const r = this.slideRect();
    const rad = this.spotSizes[this.spotSize] * r.height;
    Object.assign(shade.style, { left: `${r.left - r.boxLeft}px`, top: `${r.top - r.boxTop}px`, width: `${r.width}px`, height: `${r.height}px` });
    shade.style.background = `radial-gradient(circle at ${p.x * r.width}px ${p.y * r.height}px, transparent ${rad * 0.92}px, rgba(0,0,0,.72) ${rad * 1.08}px)`;
    shade.classList.remove('hidden');
  },

  setSpotSize(size) {
    this.spotSize = size;
    store.set('spotSize', size);
    document.querySelectorAll('.spotsize').forEach((x) => x.classList.toggle('on', x.dataset.size === size));
    if (this.spotAt) {
      this.pendingSpot = this.spotAt;
      this.showSpot(this.spotAt);
      this.scheduleFlush();
    }
  },

  spotOff() {
    if (!this.spotAt) return;
    this.showSpot(null);
    this.pendingSpot = null;
    if (this.transport) this.transport.send('sp off', true);
  },

  eraseInk() {
    this.inkSlides.delete(this.inkPage());
    this.send('ink clear');
    this.requestInk(true);
    this.renderSlideTools();
  },

  inkFrame: 0,
  inkFull: false,
  inkKey: '',

  /** Draws on the next animation frame (at most once per frame); `full` redraws every stroke. */
  requestInk(full) {
    if (full) this.inkFull = true;
    if (this.inkFrame) return;
    this.inkFrame = requestAnimationFrame(() => {
      this.inkFrame = 0;
      const fullNow = this.inkFull;
      this.inkFull = false;
      if (fullNow || !this.drawStrokeTail()) this.renderInk();
    });
  },

  /** Canvas transform for the slide area. */
  inkGeometry() {
    const canvas = $('inkCanvas');
    const box = $('current');
    const dpr = window.devicePixelRatio || 1;
    const w = Math.round(box.clientWidth * dpr);
    const h = Math.round(box.clientHeight * dpr);
    const resized = canvas.width !== w || canvas.height !== h;
    if (resized) { canvas.width = w; canvas.height = h; }
    const r = this.slideRect();
    const g = { ctx: canvas.getContext('2d'), dpr, w, h, ox: (r.left - r.boxLeft) * dpr, oy: (r.top - r.boxTop) * dpr, sw: r.width * dpr, sh: r.height * dpr, resized };
    g.X = (p) => g.ox + p.x * g.sw;
    g.Y = (p) => g.oy + p.y * g.sh;
    g.ctx.lineCap = 'round';
    g.ctx.lineJoin = 'round';
    g.ctx.lineWidth = Math.max(2, g.sh * 0.007);
    return g;
  },

  /** Only the new part of the freehand line being drawn: keeps the pencil smooth however much is on the page. */
  drawStrokeTail() {
    const st = this.stroke;
    if (!st || st.kind !== 'pen' || st.drawn === 0) return false;
    const g = this.inkGeometry();
    if (g.resized) return false;
    const pts = st.points;
    if (st.drawn >= pts.length) return true;
    const { ctx } = g;
    this.clipInk(g);
    ctx.strokeStyle = st.color;
    ctx.beginPath();
    ctx.moveTo(g.X(pts[st.drawn - 1]), g.Y(pts[st.drawn - 1]));
    for (let i = st.drawn; i < pts.length; i++) ctx.lineTo(g.X(pts[i]), g.Y(pts[i]));
    ctx.stroke();
    ctx.restore();
    st.drawn = pts.length;
    return true;
  },

  /** Draws this device's strokes for the shown page on the canvas over the slide image. */
  renderInk() {
    const g = this.inkGeometry();
    const { ctx, w, h, X, Y, dpr } = g;
    ctx.clearRect(0, 0, w, h);
    this.clipInk(g);
    const strokes = (this.st && this.st.showing && this.inkSlides.get(this.inkPage())) || [];
    for (const st of strokes) {
      ctx.strokeStyle = st.color;
      ctx.fillStyle = st.color;
      ctx.beginPath();
      const [a, b] = st.points;
      if (st.kind && st.kind !== 'pen' && b) {
        if (st.kind === 'ellipse') {
          ctx.ellipse((X(a) + X(b)) / 2, (Y(a) + Y(b)) / 2, Math.abs(X(b) - X(a)) / 2, Math.abs(Y(b) - Y(a)) / 2, 0, 0, Math.PI * 2);
        } else if (st.kind === 'rect') {
          ctx.rect(Math.min(X(a), X(b)), Math.min(Y(a), Y(b)), Math.abs(X(b) - X(a)), Math.abs(Y(b) - Y(a)));
        } else {
          ctx.moveTo(X(a), Y(a));
          ctx.lineTo(X(b), Y(b));
          if (st.kind === 'arrow' && Math.hypot(X(b) - X(a), Y(b) - Y(a)) > 1) {
            const ang = Math.atan2(Y(b) - Y(a), X(b) - X(a));
            const head = Math.max(ctx.lineWidth * 4, 10 * dpr);
            for (const side of [-1, 1]) {
              const t = ang + Math.PI - side * Math.PI / 7;
              ctx.moveTo(X(b), Y(b));
              ctx.lineTo(X(b) + head * Math.cos(t), Y(b) + head * Math.sin(t));
            }
          }
        }
        ctx.stroke();
      } else if (st.points.length === 1) {
        ctx.arc(X(a), Y(a), ctx.lineWidth / 2, 0, Math.PI * 2);
        ctx.fill();
      } else {
        st.points.forEach((p, i) => (i ? ctx.lineTo(X(p), Y(p)) : ctx.moveTo(X(p), Y(p))));
        ctx.stroke();
      }
      if (st === this.stroke) st.drawn = st.points.length;
    }
    ctx.restore();
  },

  /** Zoomed in: keep drawings inside the visible part of the slide. */
  clipInk(g) {
    g.ctx.save();
    const r = this.slideRect().base;
    if (!r) return;
    g.ctx.beginPath();
    g.ctx.rect((r.left - r.boxLeft) * g.dpr, (r.top - r.boxTop) * g.dpr, r.width * g.dpr, r.height * g.dpr);
    g.ctx.clip();
  },

  // --- zoom (live magnification of part of the slide on the projector) --------

  zoom: null, // { x, y, s }: centre of the visible part (0…1) and magnification
  zoomPointers: new Map(),
  zoomGesture: null,
  pendingZoom: null,

  zoomRegion() {
    if (!this.zoom || !this.st || !this.st.showing || this.st.wb) return null;
    const w = 1 / this.zoom.s;
    return { x: this.zoom.x - w / 2, y: this.zoom.y - w / 2, w };
  },

  /** Sets the zoom (null = whole slide) and tells the Mac unless `send` is false. */
  setZoom(z, send = true) {
    if (z && z.s > 1.02) {
      const s = Math.min(8, Math.max(1, z.s));
      const half = 0.5 / s;
      this.zoom = { s, x: Math.min(1 - half, Math.max(half, z.x)), y: Math.min(1 - half, Math.max(half, z.y)) };
      if (send) { this.pendingZoom = this.zoom; this.scheduleFlush(); }
    } else {
      const was = !!this.zoom;
      this.zoom = null;
      this.pendingZoom = null;
      if (send && was && this.transport) this.transport.send('zm off', true);
    }
    this.applyZoomView();
  },

  /** Shows the same zoomed-in part on this device as on the projector. */
  applyZoomView() {
    const img = $('currentImg');
    const z = this.zoomRegion();
    if (!z) {
      img.style.transform = img.style.clipPath = img.style.webkitClipPath = '';
    } else {
      const b = this.baseRect();
      const s = 1 / z.w;
      const bx = b.left - b.boxLeft;
      const by = b.top - b.boxTop;
      const boxW = img.clientWidth;
      const boxH = img.clientHeight;
      img.style.transformOrigin = '0 0';
      img.style.transform = `translate(${bx * (1 - s) - z.x * s * b.width}px, ${by * (1 - s) - z.y * s * b.height}px) scale(${s})`;
      const l = bx + z.x * b.width;
      const t = by + z.y * b.height;
      const clip = `inset(${t}px ${boxW - l - z.w * b.width}px ${boxH - t - z.w * b.height}px ${l}px)`;
      img.style.clipPath = img.style.webkitClipPath = clip;
    }
    this.requestInk(true);
    if (this.spotAt) this.showSpot(this.spotAt);
    $('laserDot').classList.add('hidden');
    this.renderZoomBox();
  },

  renderZoomBox() {
    const box = $('zoomBox');
    const show = this.tool === 'zoom' || !!this.zoomRegion();
    box.classList.toggle('hidden', !show);
    if (!show) return;
    $('zoomLevel').textContent = this.zoom ? `${this.zoom.s.toFixed(1)}×` : '1×';
    $('zoomReset').classList.toggle('hidden', !this.zoom);
    const st = this.st || {};
    const hint = st.zoomok === false ? 'Allow Screen Recording for PPT Remote on the Mac'
      : st.zoomok === undefined ? 'Update the Mac helper to use zoom' : '';
    $('zoomHint').textContent = hint;
    $('zoomHint').classList.toggle('hidden', !hint || this.tool !== 'zoom');
  },

  zoomBy(f) {
    const z = this.zoom || { x: 0.5, y: 0.5, s: 1 };
    this.setZoom({ ...z, s: z.s * f });
  },

  /** Centre that keeps slide point `u` under screen point `m` at magnification `s`. */
  zoomAnchor(u, m, s) {
    const b = this.baseRect();
    const w = 1 / s;
    return { s, x: u.x - ((m.x - b.left) / b.width) * w + w / 2, y: u.y - ((m.y - b.top) / b.height) * w + w / 2 };
  },

  zoomDown(e) {
    e.preventDefault();
    // Palm rejection: while the Pencil is down only the Pencil counts (a resting hand must not pinch).
    if (e.pointerType === 'pen') {
      this.pencilUsed = true;
      this.zoomPointers.clear();
      this.zoomPenId = e.pointerId;
    } else if (this.zoomPenId != null && this.zoomPointers.has(this.zoomPenId)) {
      return;
    }
    try { $('current').setPointerCapture(e.pointerId); } catch { /* pointer already gone */ }
    this.zoomPointers.set(e.pointerId, { x: e.clientX, y: e.clientY, pen: e.pointerType === 'pen' });
    this.startZoomGesture();
  },

  /** (Re)starts the gesture for the fingers now down: one = pan or drag a box, two = pinch. */
  startZoomGesture() {
    const pts = [...this.zoomPointers.values()];
    $('zoomRect').classList.add('hidden');
    if (!pts.length) { this.zoomGesture = null; return; }
    const m = pts.length > 1 ? { x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2 } : pts[0];
    const u = this.toSlide({ clientX: m.x, clientY: m.y }, true);
    this.zoomGesture = {
      mode: pts.length > 1 ? 'pinch' : this.zoom ? 'pan' : 'box',
      u, m, s0: this.zoom ? this.zoom.s : 1,
      d0: pts.length > 1 ? Math.max(10, Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)) : 0,
      moved: false,
    };
  },

  zoomMove(e) {
    if (!this.zoomPointers.has(e.pointerId)) return;
    e.preventDefault();
    this.zoomPointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const g = this.zoomGesture;
    if (!g) return;
    const pts = [...this.zoomPointers.values()];
    const m = pts.length > 1 ? { x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2 } : pts[0];
    if (Math.hypot(m.x - g.m.x, m.y - g.m.y) > 6) g.moved = true;
    if (g.mode === 'pinch' && pts.length > 1) {
      const d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      const s = Math.min(8, Math.max(1, g.s0 * d / g.d0));
      if (s <= 1.02) this.setZoom(null);
      else this.setZoom(this.zoomAnchor(g.u, m, s));
    } else if (g.mode === 'pan' && this.zoom) {
      this.setZoom(this.zoomAnchor(g.u, m, this.zoom.s));
    } else if (g.mode === 'box' && g.moved) {
      const box = $('current').getBoundingClientRect();
      Object.assign($('zoomRect').style, {
        left: `${Math.min(g.m.x, m.x) - box.left}px`, top: `${Math.min(g.m.y, m.y) - box.top}px`,
        width: `${Math.abs(m.x - g.m.x)}px`, height: `${Math.abs(m.y - g.m.y)}px`,
      });
      $('zoomRect').classList.remove('hidden');
      g.end = m;
    }
  },

  zoomUp(e) {
    if (!this.zoomPointers.has(e.pointerId)) return;
    const g = this.zoomGesture;
    this.zoomPointers.delete(e.pointerId);
    if (g && g.mode === 'box' && !this.zoomPointers.size) {
      $('zoomRect').classList.add('hidden');
      const a = g.u;
      const b = g.end ? this.toSlide({ clientX: g.end.x, clientY: g.end.y }, true) : null;
      if (!g.moved || !b) {
        // A tap zooms in 2× around that point.
        this.setZoom({ x: a.x, y: a.y, s: 2 });
      } else {
        // The visible part keeps the slide's shape, so fit the box's longer side (in slide units).
        const side = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
        const s = Math.min(8, Math.max(1.25, 1 / Math.max(side, 0.01)));
        this.setZoom({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, s });
      }
      this.zoomGesture = null;
      return;
    }
    // Pinch → one finger left: continue as panning with that finger.
    this.startZoomGesture();
    if (this.zoomGesture && this.zoomGesture.mode === 'box' && g && g.mode !== 'box') this.zoomGesture.mode = 'none';
  },

  // --- soundboard --------------------------------------------------------------

  sounds: [],
  soundsKey: '',

  requestSounds(key) {
    if (!this.transport || !key || key === this.soundsKeyRequested) return;
    this.soundsKeyRequested = key;
    if (this.transport.kind === 'bluetooth') this.send('sounds');
    else this.transport.fetchSounds();
  },

  onSounds(obj) {
    this.sounds = obj.list || [];
    this.soundsKey = obj.key;
    if (typeof obj.vol === 'number') $('soundVol').value = obj.vol;
    Activity.log(`Soundboard: ${this.sounds.length} sounds`);
    this.renderSounds();
    this.renderTools();
  },

  renderSounds() {
    const grid = $('soundGrid');
    grid.innerHTML = '';
    if (!this.sounds.length) {
      grid.textContent = 'No sounds yet.';
      return;
    }
    for (const snd of this.sounds) {
      const b = document.createElement('button');
      b.className = 'soundbtn';
      const icon = document.createElement('span');
      icon.className = 'sicon';
      icon.textContent = snd.icon || '🔊';
      const name = document.createElement('span');
      name.textContent = snd.name;
      b.append(icon, name);
      b.addEventListener('click', () => {
        buzz(15);
        this.send(`snd play ${snd.id}`);
        b.classList.remove('played');
        void b.offsetWidth;
        b.classList.add('played');
      });
      grid.appendChild(b);
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

/** Checks that the browser can really decode an image (e.g. some AVIF variants fail on Android). */
async function canDecode(blob) {
  if (typeof createImageBitmap !== 'function') return true;
  try {
    const bmp = await createImageBitmap(blob);
    if (bmp.close) bmp.close();
    return true;
  } catch {
    return false;
  }
}

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

/** Lecture recording on the Mac: chip in the top bar and the Record panel. */
const Rec = {
  stopArmed: 0,

  info() {
    const s = App.st;
    return App.transport && s && s.rec ? s.rec : null;
  },

  /** Seconds recorded, counting on from the last state the Mac sent. */
  seconds(r) {
    return r.st === 'rec' ? r.t + Math.floor((Date.now() - (App.recAt || Date.now())) / 1000) : r.t;
  },

  clock(t) {
    const h = Math.floor(t / 3600);
    const m = Math.floor(t / 60) % 60;
    const sec = String(t % 60).padStart(2, '0');
    return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
  },

  render() {
    const r = this.info();
    const chip = $('recBtn');
    chip.classList.toggle('hidden', !r);
    if (!r) return;
    const t = this.clock(this.seconds(r));
    chip.className = `chip recchip ${r.st}`;
    $('recLabel').textContent = r.st === 'rec' || r.st === 'paused' ? t : r.st === 'saving' ? `${r.p || 0}%` : '';
    chip.title = r.st === 'off' ? 'Record lecture' : `Recording: ${r.st}`;
    if ($('recView').classList.contains('hidden')) return;
    const status = $('recStatus');
    status.className = `recstatus ${r.st}`;
    status.textContent = {
      off: 'Not recording',
      starting: 'Starting…',
      rec: `⏺ Recording ${t}`,
      paused: `⏸ Paused at ${t}`,
      saving: `Saving… ${r.p || 0}%`,
    }[r.st] || r.st;
    $('recStart').classList.toggle('hidden', r.st !== 'off');
    $('recSaveNow').classList.toggle('hidden', !r.rw);
    if (r.rw) status.textContent = `Receiving the iPad's sound… ${r.rp || 0}%`;
    const bt = App.transport && App.transport.kind === 'bluetooth';
    $('micBox').classList.toggle('hidden', !RemoteMic.supported || !bt);
    $('micToggle').checked = RemoteMic.enabled;
    $('micClean').checked = store.get('micClean', false);
    $('micClean').parentElement.classList.toggle('hidden', !RemoteMic.enabled);
    const ms = RemoteMic.statusText();
    $('micStatus').textContent = ms;
    $('micStatus').classList.toggle('hidden', !ms);
    $('micResume').classList.toggle('hidden', !(RemoteMic.enabled && RemoteMic.needsTap && !RemoteMic.recorder && r.st === 'rec'));
    $('micDelete').classList.toggle('hidden', r.st !== 'off' || !RemoteMic.segs.size);
    $('recRunning').classList.toggle('hidden', r.st !== 'rec' && r.st !== 'paused');
    $('recPause').textContent = r.st === 'paused' ? '⏺ Resume' : '⏸ Pause';
    const sel = $('recScreen');
    const screens = r.screens || [];
    const key = JSON.stringify([screens, r.screen]);
    if (sel.dataset.key !== key && document.activeElement !== sel) {
      sel.dataset.key = key;
      sel.innerHTML = '';
      sel.add(new Option('Automatic (follows PowerPoint)', 'auto'));
      for (const sc of screens) sel.add(new Option(sc.name, sc.id));
      sel.value = r.screen || 'auto';
    }
    sel.parentElement.classList.toggle('hidden', !r.screens || screens.length < 2);
    if (this.stopArmed && Date.now() > this.stopArmed) this.stopArmed = 0;
    $('recStop').textContent = this.stopArmed ? 'Tap again to stop' : '■ Stop & save';
    const bits = [];
    if (r.st !== 'off' && r.disp) bits.push(`Recording: ${r.disp}${r.mic ? ' · MacBook microphone' : ' · no MacBook microphone'}${r.rmic ? ' · iPad/phone microphone' : ''}`);
    if (r.err) bits.push(`⚠︎ ${r.err}`);
    if (r.st === 'off' && r.file) bits.push(`Last recording: ${r.file}`);
    if (r.st === 'off' && r.file && r.mix) bits.push(r.mix);
    if (r.st === 'off' && r.file && r.chap) bits.push(`${r.chap} chapters (one per slide), also listed in a .chapters.txt file`);
    const ink = (App.st && App.st.inkpdf) || null;
    for (const id of ['inkAuto', 'inkPages', 'inkSave']) $(id).disabled = !ink;
    if (ink) {
      $('inkAuto').checked = !!ink.auto;
      if (document.activeElement !== $('inkPages')) $('inkPages').value = ink.pages || 'all';
      $('inkSave').disabled = !ink.can || !!ink.busy;
      $('inkSave').textContent = ink.busy ? 'Saving…' : '⤓ Save drawings as PDF now';
      $('inkInfo').textContent = ink.last ? `Last saved: ${ink.last}` : ink.can ? '' : 'Nothing drawn yet in this slide show.';
    } else {
      $('inkInfo').textContent = 'Update the Mac helper to save drawings as a PDF.';
    }
    $('recInfo').textContent = bits.join('\n');
  },

  open() {
    $('recView').classList.remove('hidden');
    this.render();
  },

  init() {
    $('recBtn').addEventListener('click', () => this.open());
    $('recClose').addEventListener('click', () => $('recView').classList.add('hidden'));
    $('recStart').addEventListener('click', () => { buzz(20); App.send('rec start'); });
    $('recScreen').addEventListener('change', (e) => App.send(`rec screen ${e.target.value}`));
    $('recSaveNow').addEventListener('click', () => App.send('rec savenow'));
    $('inkAuto').addEventListener('change', (e) => App.send(`ink auto ${e.target.checked ? 'on' : 'off'}`));
    $('inkPages').addEventListener('change', (e) => App.send(`ink pages ${e.target.value}`));
    $('inkSave').addEventListener('click', () => { buzz(15); App.send('ink save'); });
    $('micToggle').addEventListener('change', (e) => RemoteMic.setEnabled(e.target.checked));
    // Takes effect for the next piece (after a pause or the next recording).
    $('micClean').addEventListener('change', (e) => store.set('micClean', e.target.checked));
    $('micResume').addEventListener('click', () => {
      const r = this.info();
      if (r && r.st === 'rec') RemoteMic.startSegment(r.id, true);
    });
    $('micDelete').addEventListener('click', () => {
      if (window.confirm('Delete the microphone sound stored on this device?')) RemoteMic.deleteAll();
    });
    RemoteMic.init();
    $('recPause').addEventListener('click', () => {
      const r = this.info();
      if (r) App.send(r.st === 'paused' ? 'rec resume' : 'rec pause');
    });
    // Two taps, so a recording isn't stopped by accident.
    $('recStop').addEventListener('click', () => {
      if (!this.stopArmed) {
        this.stopArmed = Date.now() + 3000;
        this.render();
        return;
      }
      this.stopArmed = 0;
      buzz(20);
      App.send('rec stop');
      this.render();
    });
  },
};

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
  buzz(15);
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
  SlideStore.migrate();
  ImageFormats.detect().then((list) => {
    App.formats = list;
    Activity.log(`This browser can show: ${list.join(', ').toUpperCase()}`);
  });

  setFontSize(prefs.fontSize);
  $('qualitySel').value = prefs.quality;
  $('swipeChk').checked = prefs.swipe;
  $('autoTimerChk').checked = prefs.autoTimer;
  $('vibrateChk').checked = prefs.vibrate;
  $('vibrateChk').closest('.row').classList.toggle('hidden', !navigator.vibrate);
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
  $('spotBtn').addEventListener('click', (e) => { e.stopPropagation(); App.setTool(App.tool === 'spot' ? null : 'spot'); });
  for (const b of document.querySelectorAll('.spotsize')) {
    b.addEventListener('click', (e) => { e.stopPropagation(); App.setSpotSize(b.dataset.size); });
  }
  App.setSpotSize(App.spotSize);
  $('eraseBtn').addEventListener('click', (e) => { e.stopPropagation(); App.eraseInk(); });
  $('wbBtn').addEventListener('click', (e) => { e.stopPropagation(); App.toggleWhiteboard(); });
  $('zoomBtn').addEventListener('click', (e) => { e.stopPropagation(); App.setTool(App.tool === 'zoom' ? null : 'zoom'); });
  $('zoomIn').addEventListener('click', (e) => { e.stopPropagation(); App.zoomBy(1.5); });
  $('zoomOut').addEventListener('click', (e) => { e.stopPropagation(); App.zoomBy(1 / 1.5); });
  $('zoomReset').addEventListener('click', (e) => { e.stopPropagation(); App.setZoom(null); });
  $('fsBtn').addEventListener('click', (e) => { e.stopPropagation(); App.setBig(!App.isBig()); });
  $('bigClose').addEventListener('click', (e) => { e.stopPropagation(); App.setBig(false); });
  $('bigPrev').addEventListener('click', (e) => { e.stopPropagation(); pressNav(e.currentTarget, 'prev'); });
  $('bigNext').addEventListener('click', (e) => { e.stopPropagation(); pressNav(e.currentTarget, 'next'); });
  for (const sh of document.querySelectorAll('.shape')) {
    sh.addEventListener('click', (e) => { e.stopPropagation(); App.setShape(sh.dataset.shape); });
  }
  const landscape = matchMedia('(orientation: landscape) and (max-height: 500px)');
  const onOrientation = () => { App.landscapeDismissed = false; App.applyBig(); };
  if (landscape.addEventListener) landscape.addEventListener('change', onOrientation);
  else if (landscape.addListener) landscape.addListener(onOrientation);

  $('soundsBtn').addEventListener('click', () => { App.renderSounds(); $('soundsView').classList.remove('hidden'); });
  $('soundsClose').addEventListener('click', () => $('soundsView').classList.add('hidden'));
  $('soundStop').addEventListener('click', () => { buzz(15); App.send('snd stop'); });
  $('soundVol').addEventListener('change', (e) => App.send(`snd vol ${Number(e.target.value).toFixed(2)}`));
  for (const sw of document.querySelectorAll('.swatch')) {
    sw.addEventListener('click', (e) => {
      e.stopPropagation();
      App.penColor = sw.dataset.color;
      document.querySelectorAll('.swatch').forEach((x) => x.classList.toggle('on', x === sw));
    });
  }
  const cur = $('current');
  const onSlideTools = (e) => e.target.closest('.slidetools, .mediabars, .bignav, .bigclose');
  cur.addEventListener('pointerdown', (e) => { if (!onSlideTools(e)) App.pointerDown(e); });
  cur.addEventListener('pointermove', (e) => App.pointerMove(e));
  cur.addEventListener('pointerup', (e) => App.pointerUp(e));
  cur.addEventListener('pointercancel', (e) => App.pointerUp(e));
  // With a drawing tool on, iOS would otherwise treat quick Pencil strokes as
  // text-selection / long-press gestures and select words in the notes.
  const blockTouch = (e) => { if (App.tool && !onSlideTools(e)) e.preventDefault(); };
  cur.addEventListener('touchstart', blockTouch, { passive: false });
  cur.addEventListener('touchmove', blockTouch, { passive: false });
  // A hand resting elsewhere on the screen (e.g. on the notes) while writing must not select,
  // zoom or scroll anything. Buttons and other controls keep working.
  document.addEventListener('touchstart', (e) => {
    if (!App.tool || cur.contains(e.target)) return;
    if (e.target.closest('button, input, select, textarea, a, label, .panel, .overlay')) return;
    // The notes still scroll with a finger, except while (or just after) writing with the Pencil.
    const writing = App.activePointerType === 'pen' && App.activePointer !== null;
    if (e.target.closest('.notes') && !writing && Date.now() - (App.pencilAt || 0) > 2000) return;
    e.preventDefault();
  }, { passive: false });
  document.addEventListener('selectstart', (e) => { if (App.tool) e.preventDefault(); });

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
  $('vibrateChk').addEventListener('change', (e) => { prefs.vibrate = e.target.checked; store.set('vibrate', prefs.vibrate); buzz(30); });
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
    Rec.render();
    App.tickMedia();
    if (Panels.activityOpen) Panels.renderActivity(false);
  }, 500);
  window.addEventListener('resize', () => { App.renderSlides(); App.applyZoomView(); });
  App.applyBig();
  Rec.init();
  $('currentImg').addEventListener('load', () => App.requestInk(true));
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
