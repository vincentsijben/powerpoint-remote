// Cross-checks the Swift framing (Mac) with the JS reassembly (iPad). Requires swiftc.
const test = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const os = require('node:os');
const { FrameAssembler } = require('../docs/protocol.js');

const bin = path.join(os.tmpdir(), 'pptremote-framing-test');
execFileSync('swiftc', [
  path.join(__dirname, '../mac-helper/Sources/Framing.swift'),
  path.join(__dirname, 'swift/main.swift'), '-o', bin,
]);

for (const [size, chunk, id] of [[0, 176, 1], [1, 176, 2], [176, 176, 3], [60123, 176, 255], [300000, 506, 9]]) {
  test(`Swift frames -> JS assembler (size ${size}, chunk ${chunk})`, () => {
    const lines = execFileSync(bin, [String(size), String(chunk), String(id)], { maxBuffer: 64 << 20 })
      .toString().trim().split('\n').filter(Boolean);
    let got = null;
    const a = new FrameAssembler((type, bytes) => { got = { type, bytes }; });
    for (const l of lines) a.push(Uint8Array.from(Buffer.from(l, 'hex')));
    assert.ok(got, 'message completed');
    assert.strictEqual(got.type, 2);
    assert.strictEqual(got.bytes.length, size);
    for (let i = 0; i < size; i++) if (got.bytes[i] !== ((i * 31 + 7) & 0xff)) assert.fail(`byte ${i} differs`);
  });
}
