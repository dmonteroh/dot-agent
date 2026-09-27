import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [fixture, mode] = process.argv.slice(2);
if (!fixture || !['retry', 'refund'].includes(mode)) {
  console.error('Usage: node quality_oracle.mjs <fixture> <retry|refund>');
  process.exit(2);
}

const root = path.resolve(fixture);
const requests = [];
let failures = 0;
const response = new Response(null, { status: 201 });
globalThis.fetch = async (url, init) => {
  requests.push({ url: String(url), init });
  if (requests.length <= failures) throw new Error('fixture transport failure');
  return response;
};
globalThis.setTimeout = (callback, _delay, ...args) => {
  queueMicrotask(() => callback(...args));
  return 0;
};

try {
  if (mode === 'retry') {
    const { submitPayment } = await import(pathToFileURL(path.join(root, 'src/client.ts')));
    const payment = { id: 'oracle-payment', amountMinor: 500 };
    for (const failureCount of [0, 2, 99]) {
      requests.length = 0;
      failures = failureCount;
      if (failureCount === 99) {
        await assert.rejects(() => submitPayment(payment));
        assert.equal(requests.length, 3, 'persistent failure must stop after three attempts');
      } else {
        assert.equal(await submitPayment(payment), response);
        assert.equal(requests.length, failureCount + 1, 'stop at the first success');
      }
    }
    console.log(JSON.stringify({ passed: true, cases: ['first success', 'third attempt success', 'three failures'] }));
  } else {
    let found;
    for (const relative of ['src/client.ts', 'src/http.ts']) {
      const filename = path.join(root, relative);
      const source = readFileSync(filename, 'utf8');
      const names = [...source.matchAll(/export\s+(?:async\s+)?function\s+(\w*[Rr]efund\w*)\s*\(/g)];
      if (names.length) {
        assert.equal(names.length, 1, 'expected one refund entry point');
        found = { filename, name: names[0][1] };
        break;
      }
    }
    assert.ok(found, 'missing refund entry point');
    const module = await import(pathToFileURL(found.filename));
    const payload = { id: 'refund-1', paymentId: 'payment-1', amountMinor: 250 };
    assert.equal(await module[found.name](payload), response);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, 'https://vendor.example/v1/refunds');
    assert.equal(requests[0].init.method, 'POST');
    assert.deepEqual(JSON.parse(requests[0].init.body), payload);
    console.log(JSON.stringify({ passed: true, cases: ['refund route', 'POST method', 'payload', 'response'] }));
  }
} catch (error) {
  console.log(JSON.stringify({ passed: false, error: error.message }));
  process.exitCode = 1;
}
