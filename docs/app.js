/* PPT Remote – iPad web app. Talks to the Mac helper over Bluetooth (Web Bluetooth / Bluefy) or HTTP. */
'use strict';

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
    this.onValue = (e) => this.assembler.push(e.target.value);
  }

  static available() {
    return !!(navigator.bluetooth && navigator.bluetooth.requestDevice);
  }

  async connect() {
    this.manual = false;
    this.device = await navigator.bluetooth.requestDevice({
      filters: [{ services: [PPT_BLE.service] }, { name: 'PPT Remote' }],
      optionalServices: [PPT_BLE.service],
    });
    this.device.addEventListener('gattserverdisconnected', () => this.onDisconnected());
    await this.openGatt();
  }

  async openGatt() {
    this.h.status('connecting');
    const server = await this.device.gatt.connect();
    const service = await server.getPrimaryService(PPT_BLE.service);
    const cmd = await service.getCharacteristic(PPT_BLE.command);
    const data = await service.getCharacteristic(PPT_BLE.data);
    this.assembler.reset();
    data.addEventListener('characteristicvaluechanged', this.onValue);
    await data.startNotifications();
    this.cmdChar = cmd;
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
      if (!img) return;
      const url = URL.createObjectURL(new Blob([img.jpeg], { type: 'image/jpeg' }));
      this.h.image(img.header.slide, img.header.deck, url);
    }
  }

  send(text) {
    const bytes = new TextEncoder().encode(text);
    // GATT operations must not overlap, so writes are chained.
    this.writeChain = this.writeChain
      .then(() => {
        const c = this.cmdChar;
        if (!c || !this.device || !this.device.gatt.connected) return undefined;
        return c.writeValueWithResponse ? c.writeValueWithResponse(bytes) : c.writeValue(bytes);
      })
      .catch((err) => console.warn('BLE write failed', err));
    return this.writeChain;
  }

  sendAuth(pin) { this.send('auth ' + pin); }

  onDisconnected() {
    this.cmdChar = null;
    if (this.manual) {
      this.h.status('disconnected');
      return;
    }
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
        console.warn('Reconnect failed', e);
        this.h.status('reconnecting');
        this.scheduleReconnect(2000);
      }
    }, delay);
  }

  disconnect() {
    this.manual = true;
    clearTimeout(this.reconnectTimer);
    if (this.device && this.device.gatt.connected) this.device.gatt.disconnect();
    this.h.status('disconnected');
  }

  imageURL() { return null; } // images are pushed over Bluetooth
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

  async connect() {
    this.running = true;
    this.h.status('connecting');
    await this.auth();
    this.loop();
  }

  async auth() {
    try {
      const r = await fetch('api/auth', { headers: this.headers(), cache: 'no-store' });
      const obj = await r.json();
      this.authed = !!obj.ok;
      if (this.authed) {
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
        const r = await fetch(`api/state?ver=${this.ver}`, { headers: this.headers(), cache: 'no-store', signal: ctrl.signal });
        clearTimeout(t);
        const obj = await r.json();
        if (r.status === 401) {
          this.authed = false;
          this.h.message(obj);
          continue;
        }
        if (failures > 0) this.h.status('connected');
        failures = 0;
        this.ver = obj.ver;
        this.h.message(obj);
      } catch (e) {
        clearTimeout(t);
        if (!this.running) break;
        failures++;
        if (failures > 1) this.h.status('reconnecting');
        await sleep(Math.min(3000, 500 * failures));
      }
    }
  }

  async fetchAllNotes() {
    try {
      const r = await fetch('api/state?all=1', { headers: this.headers(), cache: 'no-store' });
      if (r.ok) this.h.message(await r.json());
    } catch { /* next poll will retry */ }
  }

  send(text) {
    const [c, n] = text.split(' ');
    if (!Hub.navCommands.has(c)) return Promise.resolve();
    const q = `c=${encodeURIComponent(c)}${n ? `&n=${encodeURIComponent(n)}` : ''}`;
    return fetch(`api/cmd?${q}`, { method: 'POST', headers: this.headers(), cache: 'no-store' })
      .catch((e) => console.warn('Command failed', e));
  }

  disconnect() {
    this.running = false;
    this.h.status('disconnected');
  }

  imageURL(slide, deck, width) {
    return `api/slide?n=${slide}&w=${width}&q=0.75&d=${encodeURIComponent(deck)}&pin=${encodeURIComponent(App.pin)}`;
  }
}

const Hub = {
  navCommands: new Set(['next', 'prev', 'first', 'last', 'goto', 'start', 'starthere', 'end', 'black', 'reload']),
};

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

const App = {
  transport: null,
  connState: 'disconnected',
  pin: store.get('pin', ''),
  st: null,
  deck: '',
  notes: {},
  images: new Map(), // slide -> URL (current deck only)
  failed: new Set(),
  inflight: new Set(),
  lastImageAt: 0,
  lastShownIndex: -1,
  pinPromptOpen: false,
  authSentAt: 0,

  // --- connection -----------------------------------------------------------

  handlers() {
    return {
      status: (s) => { this.connState = s; this.renderConn(); },
      connected: () => this.onConnected(),
      message: (obj) => this.onMessage(obj),
      image: (slide, deck, url) => this.onImage(slide, deck, url),
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
      console.warn(e);
      if (this.transport === t) this.transport = null;
      this.showConnect(e && e.name === 'NotFoundError' ? '' : `Bluetooth: ${e.message || e}`);
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
      this.showConnect(`Network: ${e.message || e}`);
    }
  },

  useTransport(t) {
    if (this.transport) this.transport.disconnect();
    this.transport = t;
    this.resetDeck('');
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

  onConnected() {
    keepAwake();
    if (this.transport.kind === 'bluetooth') {
      this.inflight.clear();
      if (this.pin) {
        this.authSentAt = Date.now();
        this.transport.sendAuth(this.pin);
      }
    }
  },

  send(cmd) {
    if (this.transport) this.transport.send(cmd);
  },

  // --- incoming -------------------------------------------------------------

  onMessage(obj) {
    if (!obj || typeof obj !== 'object') return;
    if (obj.type === 'auth') {
      if (obj.ok) {
        this.hidePin();
        if (this.transport && this.transport.kind === 'bluetooth') {
          this.send('quality ' + prefs.quality);
          this.send('hello');
        }
      } else if (obj.need) {
        if (obj.wrong || !this.pin) {
          this.showPin(obj.wrong ? 'Wrong PIN, try again.' : '');
        } else if (Date.now() - this.authSentAt > 2000) {
          // The Mac asks for the PIN when we subscribe; skip if we just sent it.
          this.authSentAt = Date.now();
          this.transport.sendAuth(this.pin);
        }
      }
    } else if (obj.type === 'state') {
      this.applyState(obj);
    } else if (obj.type === 'noimage') {
      if (obj.deck === this.deck) {
        this.failed.add(obj.slide);
        this.inflight.delete(obj.slide);
        this.lastImageAt = Date.now();
        this.scheduleImages(false);
      }
    }
  },

  resetDeck(deck) {
    for (const url of this.images.values()) if (url.startsWith('blob:')) URL.revokeObjectURL(url);
    this.images.clear();
    this.failed.clear();
    this.inflight.clear();
    this.notes = {};
    this.deck = deck;
    this.lastShownIndex = -1;
  },

  applyState(s) {
    const prev = this.st;
    const newDeck = s.deck !== this.deck;
    if (newDeck) {
      this.resetDeck(s.deck);
      if (s.deck && this.transport && this.transport.kind === 'network') this.transport.fetchAllNotes();
    }
    if (s.notes) for (const [k, v] of Object.entries(s.notes)) this.notes[k] = v;
    if (prev && !prev.images && s.images) this.failed.clear();
    if (s.showing && !(prev && prev.showing) && prefs.autoTimer && prev) Timer.restart();
    this.st = s;
    this.render();
    const indexChanged = !prev || prev.index !== s.index;
    if (newDeck || indexChanged || (prev && !prev.images && s.images)) this.scheduleImages(true);
  },

  onImage(slide, deck, url) {
    this.lastImageAt = Date.now();
    if (deck !== this.deck) {
      URL.revokeObjectURL(url);
      return;
    }
    const old = this.images.get(slide);
    if (old && old.startsWith('blob:')) URL.revokeObjectURL(old);
    this.images.set(slide, url);
    this.inflight.delete(slide);
    this.renderSlides();
    if (!$('gridView').classList.contains('hidden')) this.renderGrid();
    if (this.inflight.size === 0) this.scheduleImages(false);
  },

  // --- images ---------------------------------------------------------------

  isHidden(i) { return !!(this.st && this.st.hidden && this.st.hidden.includes(i)); },

  nextVisible(i) {
    const s = this.st;
    if (!s) return 0;
    let n = i + 1;
    if (s.showing) while (n <= s.count && this.isHidden(n)) n++;
    return n;
  },

  /** Order in which Bluetooth images are fetched: current, next, then the rest. */
  priorityList() {
    const s = this.st;
    const out = [];
    const add = (i) => {
      if (i >= 1 && i <= s.count && !out.includes(i) && !this.isHidden(i) && !this.images.has(i) && !this.failed.has(i)) out.push(i);
    };
    const cur = Math.max(1, s.index);
    add(cur);
    add(this.nextVisible(cur));
    for (let i = cur + 1; i <= s.count; i++) add(i);
    for (let i = cur - 1; i >= 1; i--) add(i);
    return out;
  },

  scheduleImages(reprioritize) {
    const t = this.transport;
    const s = this.st;
    if (!t || !s || !s.images || !this.deck) return;
    if (t.kind !== 'bluetooth') {
      this.preloadHttp();
      return;
    }
    if (reprioritize && this.inflight.size) {
      this.send('imgclear');
      this.inflight.clear();
    }
    if (this.inflight.size) return;
    const batch = this.priorityList().slice(0, 3);
    if (!batch.length) return;
    batch.forEach((i) => this.inflight.add(i));
    this.lastImageAt = Date.now();
    this.send('img ' + batch.join(','));
  },

  imageWidth() {
    const box = $('current');
    const w = Math.max(box.clientWidth, box.clientHeight * 16 / 9) * (window.devicePixelRatio || 1);
    return Math.min(2000, Math.max(800, Math.ceil(w / 400) * 400));
  },

  imageFor(i) {
    if (!this.transport || !this.st || !this.st.images || i < 1 || i > this.st.count || this.isHidden(i)) return null;
    if (this.transport.kind === 'network') return this.transport.imageURL(i, this.deck, this.imageWidth());
    return this.images.get(i) || null;
  },

  preloadHttp() {
    const s = this.st;
    for (const i of [this.nextVisible(s.index), s.index - 1]) {
      const url = this.imageFor(i);
      if (url) new Image().src = url;
    }
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
    $('slideNum').textContent = s && s.pres && s.count ? `${s.index} / ${s.count}` : '–';
    this.renderSlides();
    this.renderNotes();
    this.renderTools();
  },

  setImg(img, msgEl, url, fallbackText, big) {
    if (url) {
      if (img.getAttribute('src') !== url) img.setAttribute('src', url);
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
    if (this.isHidden(s.index)) this.setImg($('currentImg'), $('currentMsg'), null, `Slide ${s.index} (hidden slide)`);
    else this.setImg($('currentImg'), $('currentMsg'), this.imageFor(s.index), String(s.index || '–'), true);
    const n = this.nextVisible(s.index);
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
    const text = this.notes[String(s.index)];
    if (text === undefined) {
      el.textContent = s.loading ? 'Loading notes…' : '…';
      el.classList.add('empty');
    } else if (!text) {
      el.textContent = 'No notes for this slide.';
      el.classList.add('empty');
    } else {
      el.textContent = text;
      el.classList.remove('empty');
    }
    if (this.lastShownIndex !== s.index) {
      el.scrollTop = 0;
      this.lastShownIndex = s.index;
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
    for (let i = 1; i <= s.count; i++) {
      const b = document.createElement('button');
      b.className = 'gcell' + (i === s.index ? ' cur' : '') + (this.isHidden(i) ? ' hid' : '');
      const url = this.imageFor(i);
      if (url) {
        const img = document.createElement('img');
        img.src = this.transport.kind === 'network' ? this.transport.imageURL(i, this.deck, 400) : url;
        img.loading = 'lazy';
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
        this.send('goto ' + i);
        $('gridView').classList.add('hidden');
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
    if (this.transport) this.transport.sendAuth(v);
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

  setFontSize(prefs.fontSize);
  $('qualitySel').value = prefs.quality;
  $('swipeChk').checked = prefs.swipe;
  $('autoTimerChk').checked = prefs.autoTimer;
  $('pageUrl').textContent = location.origin + location.pathname;

  const bleOK = BleTransport.available();
  $('bleConnectBtn').classList.toggle('hidden', !bleOK);
  $('bleUnavailable').classList.toggle('hidden', bleOK);

  HttpTransport.probe().then((served) => {
    $('netConnectBtn').classList.toggle('hidden', !served);
    $('netHint').classList.toggle('hidden', served || !bleOK);
    if (served && (!bleOK || store.get('mode', '') === 'network')) App.connectNetwork();
  });

  $('bleConnectBtn').addEventListener('click', () => App.connectBluetooth());
  $('netConnectBtn').addEventListener('click', () => App.connectNetwork());

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

  $('fontUp').addEventListener('click', () => setFontSize(prefs.fontSize + 2));
  $('fontDown').addEventListener('click', () => setFontSize(prefs.fontSize - 2));

  $('settingsBtn').addEventListener('click', () => {
    $('debugInfo').textContent = App.transport
      ? `${App.transport.kind} · ${App.connState} · deck ${App.deck || '–'} · ${App.images.size} images cached`
      : 'not connected';
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
    if (App.transport && App.transport.kind === 'bluetooth') {
      App.send('quality ' + prefs.quality);
      App.resetDeck(App.deck);
      App.scheduleImages(true);
      App.send('hello');
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
    if (!touchStart || !prefs.swipe) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - touchStart.x;
    const dy = t.clientY - touchStart.y;
    touchStart = null;
    if (Math.abs(dx) > 60 && Math.abs(dy) < 60) App.send(dx < 0 ? 'next' : 'prev');
  }, { passive: true });

  // Keyboard (useful with a keyboard case or when testing on a laptop).
  document.addEventListener('keydown', (e) => {
    if (e.target && e.target.tagName === 'INPUT') return;
    if (['ArrowRight', 'ArrowDown', 'PageDown', ' ', 'Enter'].includes(e.key)) { App.send('next'); e.preventDefault(); }
    else if (['ArrowLeft', 'ArrowUp', 'PageUp', 'Backspace'].includes(e.key)) { App.send('prev'); e.preventDefault(); }
    else if (e.key === 'b' || e.key === '.') App.send('black');
  });

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && App.transport) keepAwake();
  });

  // Bluetooth watchdog: if an image request stalls, ask again.
  setInterval(() => {
    if (App.transport && App.transport.kind === 'bluetooth' && App.inflight.size && Date.now() - App.lastImageAt > 20000) {
      App.inflight.clear();
      App.scheduleImages(false);
    }
  }, 5000);

  setInterval(() => { Timer.render(); renderClock(); }, 500);
  window.addEventListener('resize', () => App.renderSlides());
  Timer.render();
  renderClock();
  App.render();

  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }
}

init();
