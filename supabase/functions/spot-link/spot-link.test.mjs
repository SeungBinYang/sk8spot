import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

let handler;
const source = readFileSync(new URL('./index.ts', import.meta.url), 'utf8');
runInNewContext(source, {
  Deno: { serve: (fn) => { handler = fn; } },
  Response,
  URL,
});

test('valid share id renders an app deep link', async () => {
  const response = handler({ method: 'GET', url: 'https://example.test/spot-link?id=42' });
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /href="com\.skatespot\.sk8spot:\/\/spot\/42"/);
  assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8');
});

test('invalid ids and methods are rejected', () => {
  assert.equal(handler({ method: 'GET', url: 'https://example.test/spot-link?id=%3Cscript%3E' }).status, 400);
  assert.equal(handler({ method: 'GET', url: 'https://example.test/spot-link?id=0' }).status, 400);
  assert.equal(handler({ method: 'POST', url: 'https://example.test/spot-link?id=42' }).status, 405);
});

test('HEAD includes no response body', async () => {
  const response = handler({ method: 'HEAD', url: 'https://example.test/spot-link?id=42' });
  assert.equal(response.status, 200);
  assert.equal(await response.text(), '');
});