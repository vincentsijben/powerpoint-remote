// Run: node --test tests/
const test = require('node:test');
const assert = require('node:assert');
const { FrameAssembler, buildFrames, parseImagePayload, PPT_BLE } = require('../docs/protocol.js');

test('reassembles interleaved messages', () => {
  const out = [];
  const a = new FrameAssembler((type, bytes) => out.push({ type, text: Buffer.from(bytes).toString() }));
  const m1 = buildFrames(1, 7, new TextEncoder().encode('{"type":"state","index":3}'), 5);
  const m2 = buildFrames(2, 8, new TextEncoder().encode('IMAGE-BYTES-HERE-1234567890'), 4);
  const max = Math.max(m1.length, m2.length);
  for (let i = 0; i < max; i++) {
    if (m2[i]) a.push(m2[i]);
    if (m1[i]) a.push(m1[i]);
  }
  assert.deepStrictEqual(out.map((o) => o.type).sort(), [1, 2]);
  assert.strictEqual(out.find((o) => o.type === 1).text, '{"type":"state","index":3}');
  assert.strictEqual(out.find((o) => o.type === 2).text, 'IMAGE-BYTES-HERE-1234567890');
});

test('msgId reuse restarts the message and partial starts are ignored', () => {
  const out = [];
  const a = new FrameAssembler((t, b) => out.push(Buffer.from(b).toString()));
  const first = buildFrames(1, 255, new TextEncoder().encode('aaaaaaaaaa'), 3);
  a.push(first[0]); a.push(first[1]); // incomplete
  for (const f of buildFrames(1, 255, new TextEncoder().encode('bbbb'), 3)) a.push(f);
  a.push(buildFrames(1, 9, new TextEncoder().encode('cccccc'), 3)[1]); // no start
  assert.deepStrictEqual(out, ['bbbb']);
});

test('accepts DataView input and single empty frame', () => {
  const out = [];
  const a = new FrameAssembler((t, b) => out.push(b.length));
  const [f] = buildFrames(1, 1, new Uint8Array(0), 10);
  a.push(new DataView(f.buffer));
  assert.deepStrictEqual(out, [0]);
});

test('parses image payload header', () => {
  const header = new TextEncoder().encode('{"slide":4,"deck":"x1"}\n');
  const jpeg = new Uint8Array([0xff, 0xd8, 0x0a, 0xff, 0xd9]);
  const p = new Uint8Array(header.length + jpeg.length);
  p.set(header); p.set(jpeg, header.length);
  const r = parseImagePayload(p);
  assert.deepStrictEqual(r.header, { slide: 4, deck: 'x1' });
  assert.deepStrictEqual([...r.jpeg], [...jpeg]);
  assert.strictEqual(PPT_BLE.HEADER, 6);
});
