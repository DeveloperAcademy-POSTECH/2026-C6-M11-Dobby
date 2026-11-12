import test from 'node:test';
import assert from 'node:assert/strict';
import { loadProductPageImage } from '../src/product-page-images.js';
const url = 'https://poshmark.com/listing/item';
const html = body => new Response(body, { headers: { 'content-type': 'text/html;charset=utf-8' } });
test('extracts only public product metadata image with original page identity and no credentials', async () => {
  const result = await loadProductPageImage(url, { fetchImpl: async (u, init) => {
    assert.equal(u, url); assert.equal(init.redirect, 'manual'); assert.equal(init.credentials, 'omit');
    assert.deepEqual(Object.keys(init.headers), ['Accept']);
    return html(`<meta content="Save Thyself" property="og:title"><meta property='og:image' content='https://images.example.com/palace.jpg?a=1&amp;b=2'><meta name="description" content="Heart graphic shirt">`);
  } });
  assert.equal(result.imageUrl, 'https://images.example.com/palace.jpg?a=1&b=2');
  assert.equal(result.pageTitle, 'Save Thyself'); assert.equal(result.pageDescription, 'Heart graphic shirt');
});
test('rejects unsafe origins, redirects and private images without following them', async () => {
  await assert.rejects(loadProductPageImage('https://127.0.0.1/a', { fetchImpl: () => assert.fail() }), { code: 'unsafe_product_url' });
  await assert.rejects(loadProductPageImage(url, { fetchImpl: async () => new Response(null, { status: 302 }) }), { code: 'product_page_redirect_rejected' });
  await assert.rejects(loadProductPageImage(url, { fetchImpl: async () => html('<meta property="og:image" content="https://127.0.0.1/a">') }), { code: 'product_image_missing' });
});
test('HTML without usable image is not claimed as visual product evidence', async () => {
  await assert.rejects(loadProductPageImage(url, { fetchImpl: async () => html('<html>blocked</html>') }), { code: 'product_image_missing' });
});
