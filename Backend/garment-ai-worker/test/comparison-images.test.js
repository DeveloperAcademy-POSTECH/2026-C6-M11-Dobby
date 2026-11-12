import test from 'node:test';
import assert from 'node:assert/strict';
import { downloadComparisonImage } from '../src/comparison-images.js';
const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=', 'base64');
const url = 'https://images.example.com/photo.png';
const response = (body = bytes, headers = {}) => new Response(body, { headers: { 'content-type': 'image/png', ...headers } });
test('downloads exact bytes without credentials and produces bounded data URL plus digest', async () => {
  const result = await downloadComparisonImage(url, { fetchImpl: async (u, init) => {
    assert.equal(u, url); assert.equal(init.redirect, 'manual'); assert.equal(init.credentials, 'omit');
    assert.deepEqual(Object.keys(init.headers), ['Accept']); return response();
  } });
  assert.deepEqual(Buffer.from(result.dataUrl.split(',')[1], 'base64'), bytes);
  assert.equal(result.width, 1); assert.equal(result.height, 1); assert.equal(result.sha256.length, 64);
});
test('unsafe URLs fail before network', async () => {
  for (const u of ['http://example.com/a', 'https://127.0.0.1/a', 'https://[::1]/a', 'https://x.local/a', 'https://user:pass@example.com/a', 'https://example.com:8080/a']) {
    await assert.rejects(downloadComparisonImage(u, { fetchImpl: () => assert.fail('network') }), { code: 'unsafe_image_url' });
  }
});
test('rejects redirect, unsupported payload, truncated image and oversized stream', async () => {
  for (const [r, code] of [
    [new Response(null, { status: 302, headers: { location: 'https://example.com' } }), 'image_redirect_rejected'],
    [response(bytes, { 'content-type': 'text/html' }), 'unsupported_image_type'],
    [response('<html>not an image</html>'), 'invalid_image'],
    [response(bytes.subarray(0, 35)), 'invalid_image'],
    [response(Buffer.alloc(2 * 1024 * 1024 + 1)), 'image_too_large'],
  ]) await assert.rejects(downloadComparisonImage(url, { fetchImpl: async () => r }), { code });
});
test('aborts timed out downloads', async () => {
  await assert.rejects(downloadComparisonImage(url, { timeoutMs: 5, fetchImpl: (u, { signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(new Error('abort')));
  }) }), { code: 'image_download_timeout' });
});
test('rejects excessive dimensions before encoding', async () => {
  const large = Buffer.from(bytes); large.writeUInt32BE(10000, 16);
  await assert.rejects(downloadComparisonImage(url, { fetchImpl: async () => response(large) }), { code: 'invalid_image_dimensions' });
});
