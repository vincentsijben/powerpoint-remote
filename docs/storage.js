/* Slide images stored on this device (IndexedDB), keyed by the slide's content key from the Mac.
 * The same slide is recognised again next time (even after a re-export), so it isn't sent again. */
'use strict';

const SlideStore = {
  DB: 'pptremote',
  STORE: 'slides',
  MAX_BYTES: 150 * 1024 * 1024,
  /** Bumped when the Mac's images change in a way that makes stored ones unusable (r2: even-sized AVIF grids). */
  REV: 'r2',
  db: null,
  failed: false,

  open() {
    if (this.db) return Promise.resolve(this.db);
    if (this.failed || !window.indexedDB) return Promise.resolve(null);
    if (!this.opening) {
      this.opening = new Promise((resolve) => {
        let req;
        try { req = indexedDB.open(this.DB, 1); } catch { this.failed = true; resolve(null); return; }
        req.onupgradeneeded = () => {
          const os = req.result.createObjectStore(this.STORE, { keyPath: 'id' });
          os.createIndex('key', 'key');
          os.createIndex('usedAt', 'usedAt');
        };
        req.onsuccess = () => { this.db = req.result; resolve(this.db); };
        req.onerror = () => { this.failed = true; resolve(null); };
        req.onblocked = () => resolve(null);
      });
    }
    return this.opening;
  },

  async tx(mode, fn) {
    const db = await this.open();
    if (!db) return undefined;
    return new Promise((resolve, reject) => {
      const t = db.transaction(this.STORE, mode);
      const os = t.objectStore(this.STORE);
      let result;
      Promise.resolve(fn(os)).then((r) => { result = r; });
      t.oncomplete = () => resolve(result);
      t.onerror = () => reject(t.error);
      t.onabort = () => reject(t.error);
    });
  },

  req(r) {
    return new Promise((resolve, reject) => {
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
    });
  },

  /**
   * Looks up a stored image. Prefers the exact variant (format + quality); with `strict` false,
   * any stored variant of the same slide is accepted.
   * @returns {Promise<{data: ArrayBuffer, mime: string, size: number, variant: string}|null>}
   */
  async get(key, variant, strict) {
    if (!key) return null;
    try {
      return (await this.tx('readwrite', async (os) => {
        let rec = await this.req(os.get(`${key}|${variant}`));
        if (!rec && !strict) {
          const all = await this.req(os.index('key').getAll(key));
          rec = all.filter((r) => String(r.variant).endsWith(`-${this.REV}`)).sort((a, b) => b.size - a.size)[0] || null;
        }
        if (rec) {
          rec.usedAt = Date.now();
          os.put(rec);
        }
        return rec;
      })) || null;
    } catch (e) {
      console.warn('SlideStore.get', e);
      return null;
    }
  },

  async put({ key, variant, data, mime, deck, name, slide }) {
    if (!key) return;
    try {
      const now = Date.now();
      await this.tx('readwrite', (os) => {
        os.put({ id: `${key}|${variant}`, key, variant, data, mime, size: data.byteLength, deck, name, slide, savedAt: now, usedAt: now });
      });
      this.requestPersistence();
      this.scheduleEvict();
    } catch (e) {
      console.warn('SlideStore.put', e);
      Activity.log(`Could not store slide ${slide} on this device: ${e && e.name}`, 'error');
    }
  },

  /** @returns {Promise<{count: number, bytes: number, decks: number}>} */
  async stats() {
    const out = { count: 0, bytes: 0, decks: 0 };
    try {
      const names = new Set();
      await this.tx('readonly', (os) => new Promise((resolve) => {
        const cur = os.openCursor();
        cur.onsuccess = () => {
          const c = cur.result;
          if (!c) { resolve(); return; }
          out.count++;
          out.bytes += c.value.size || 0;
          names.add(c.value.name || c.value.deck);
          c.continue();
        };
        cur.onerror = () => resolve();
      }));
      out.decks = names.size;
    } catch { /* unavailable */ }
    return out;
  },

  /** Removes slides stored by older versions (e.g. AVIF files some browsers can't show). */
  async migrate() {
    let removed = 0;
    try {
      await this.tx('readwrite', (os) => new Promise((resolve) => {
        const cur = os.openCursor();
        cur.onsuccess = () => {
          const c = cur.result;
          if (!c) { resolve(); return; }
          if (!String(c.value.variant).endsWith(`-${this.REV}`)) { c.delete(); removed++; }
          c.continue();
        };
        cur.onerror = () => resolve();
      }));
    } catch { /* unavailable */ }
    if (removed) Activity.log(`Removed ${removed} slides stored by an older version`);
  },

  async clear() {
    try { await this.tx('readwrite', (os) => { os.clear(); }); } catch (e) { console.warn(e); }
  },

  scheduleEvict() {
    clearTimeout(this.evictTimer);
    this.evictTimer = setTimeout(() => this.evict(), 5000);
  },

  /** Removes the least recently used slides when over MAX_BYTES. */
  async evict() {
    const s = await this.stats();
    if (s.bytes <= this.MAX_BYTES) return;
    let toFree = s.bytes - this.MAX_BYTES * 0.8;
    let removed = 0;
    await this.tx('readwrite', (os) => new Promise((resolve) => {
      const cur = os.index('usedAt').openCursor();
      cur.onsuccess = () => {
        const c = cur.result;
        if (!c || toFree <= 0) { resolve(); return; }
        toFree -= c.value.size || 0;
        removed++;
        c.delete();
        c.continue();
      };
      cur.onerror = () => resolve();
    }));
    Activity.log(`Storage limit reached: removed ${removed} old slides`);
  },

  persistAsked: false,
  requestPersistence() {
    if (this.persistAsked || !navigator.storage || !navigator.storage.persist) return;
    this.persistAsked = true;
    navigator.storage.persist().then((ok) => Activity.log(`Persistent storage ${ok ? 'granted' : 'not granted (the browser may clear it when space is low)'}`)).catch(() => {});
  },
};

/** Detects which compact image formats this browser can decode. */
const ImageFormats = {
  // 2×2 red images encoded by macOS ImageIO.
  samples: {
    avif: 'AAAAIGZ0eXBhdmlmAAAAAE1pUHJhdmlmbWlhZm1pZjEAAAEhbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAAOcGl0bQAAAAAAAQAAACNpaW5mAAAAAAABAAAAFWluZmUCAAAAAAEAAGF2MDEAAAAAgWlwcnAAAABgaXBjbwAAABNjb2xybmNseAACAAIABoAAAAAMY2xsaQDLAEAAAAAUaXNwZQAAAAAAAAACAAAAAgAAAAlpcm90AAAAABBwaXhpAAAAAAMICAgAAAAMYXYxQ4EADAAAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAAHmlsb2MAAAAARAAAAQABAAAAAQAAAVEAAAAfAAAAAW1kYXQAAAAAAAAALxIACgwAAAAABn/8CBAQNCAyDRAB8AH///4gAKyv7xs=',
    heic: 'AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABh21ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAOdpcHJwAAAAxmlwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAAAAAAAgAAAAIAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAAcmh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEMAf//A3AAAAMAsAAAAwAAAwAecCShAAEAJEIBAQNwAAADALAAAAMAAAMAHqAUIEHAoQQYh7kWVTcCAgYAgKIAAQAJRAHAYeLIRFNkAAAAGWlwbWEAAAAAAAAAAQABBoECAwWGhAAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAG7AAAALwAAAAFtZGF0AAAAAAAAAD8AAAArKAGvotL5Q+/wsPs1AlZJwUlQcUl+K9vrirqher8Z1cWXDexjqoVk9YBEwA==',
  },
  supported: null,

  detect() {
    if (this.supported) return this.supported;
    const test = (fmt) => new Promise((resolve) => {
      const img = new Image();
      const done = (ok) => { clearTimeout(t); resolve(ok); };
      const t = setTimeout(() => done(false), 1500);
      img.onload = () => done(img.naturalWidth > 0);
      img.onerror = () => done(false);
      img.src = `data:image/${fmt};base64,${this.samples[fmt]}`;
    });
    this.supported = Promise.all(['avif', 'heic'].map(test)).then(([avif, heic]) => {
      const list = [];
      if (avif) list.push('avif');
      if (heic) list.push('heic');
      list.push('jpeg');
      return list;
    });
    return this.supported;
  },
};
