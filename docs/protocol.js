// Bluetooth framing shared with the Mac helper (see mac-helper/Sources/BLEServer.swift).
// Each notification: [type u8][msgId u8][seq u16 LE][total u16 LE][payload...]
(function (root) {
  'use strict';

  const PPT_BLE = {
    service: '2a4c9463-10dd-4d1d-9670-1c3d7737e942',
    command: '41d625bb-4f1d-4bbe-98b2-362daaed35c1',
    data: 'c8cbd42e-2eea-403d-9223-66344adf9c27',
    HEADER: 6,
    TYPE_JSON: 1,
    TYPE_IMAGE: 2,
  };

  class FrameAssembler {
    constructor(onMessage) {
      this.onMessage = onMessage; // (type, Uint8Array payload) => void
      this.pending = new Map();
    }

    reset() {
      this.pending.clear();
    }

    /** @param {DataView|ArrayBuffer|Uint8Array} chunk */
    push(chunk) {
      const bytes = chunk instanceof Uint8Array
        ? chunk
        : chunk instanceof DataView
          ? new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength)
          : new Uint8Array(chunk);
      if (bytes.length < PPT_BLE.HEADER) return;
      const type = bytes[0];
      const id = bytes[1];
      const seq = bytes[2] | (bytes[3] << 8);
      const total = bytes[4] | (bytes[5] << 8);
      if (total === 0 || seq >= total) return;
      // Copy: some browsers reuse the notification buffer.
      const payload = bytes.slice(PPT_BLE.HEADER);

      let msg = this.pending.get(id);
      if (!msg || seq === 0 || msg.total !== total || msg.type !== type) {
        if (seq !== 0) return; // missed the start of this message
        msg = { type, total, parts: new Array(total), received: 0, size: 0 };
        this.pending.set(id, msg);
      }
      if (msg.parts[seq] === undefined) {
        msg.parts[seq] = payload;
        msg.received++;
        msg.size += payload.length;
      }
      if (msg.received === msg.total) {
        this.pending.delete(id);
        const out = new Uint8Array(msg.size);
        let off = 0;
        for (const p of msg.parts) {
          out.set(p, off);
          off += p.length;
        }
        this.onMessage(msg.type, out);
      }
    }
  }

  /** Splits an image payload into its JSON header and JPEG bytes. */
  function parseImagePayload(bytes) {
    const nl = bytes.indexOf(0x0a);
    if (nl < 0) return null;
    const header = JSON.parse(new TextDecoder().decode(bytes.subarray(0, nl)));
    return { header, jpeg: bytes.subarray(nl + 1) };
  }

  /** Builds frames the same way the Mac does (used for tests). */
  function buildFrames(type, msgId, payload, chunkSize) {
    const total = Math.max(1, Math.ceil(payload.length / chunkSize));
    const frames = [];
    for (let seq = 0; seq < total; seq++) {
      const part = payload.subarray(seq * chunkSize, (seq + 1) * chunkSize);
      const f = new Uint8Array(PPT_BLE.HEADER + part.length);
      f.set([type, msgId & 0xff, seq & 0xff, seq >> 8, total & 0xff, total >> 8]);
      f.set(part, PPT_BLE.HEADER);
      frames.push(f);
    }
    return frames;
  }

  const api = { PPT_BLE, FrameAssembler, parseImagePayload, buildFrames };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  Object.assign(root, api);
})(typeof window !== 'undefined' ? window : globalThis);
