import { publicURL } from './garment-heritage.js';
const fail = code => { throw Object.assign(new Error(code), { code }); };
const decode = value => value.replace(/&(?:amp|quot|apos|lt|gt|#39|#x27);/giu, s => ({ '&amp;': '&', '&quot;': '"', '&apos;': "'", '&lt;': '<', '&gt;': '>', '&#39;': "'", '&#x27;': "'" })[s.toLowerCase()] || s);
const safe = value => {
  const url = publicURL(value);
  return url && !new URL(url).port && /[a-z]/iu.test(new URL(url).hostname.split('.').at(-1)) ? url : null;
};
// Only metadata from a native-search source page is read. Scripts are never run.
// Cloudflare's default public Internet fetch service blocks private network IPs.
export async function loadProductPageImage(url, { fetchImpl, signal, timeoutMs = 4000 }) {
  if (!safe(url)) fail('unsafe_product_url');
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) abort();
  const timer = setTimeout(abort, timeoutMs);
  try {
    const response = await fetchImpl(url, { redirect: 'manual', credentials: 'omit', signal: controller.signal,
      headers: { Accept: 'text/html,application/xhtml+xml' } });
    if (response.status >= 300 && response.status < 400) fail('product_page_redirect_rejected');
    if (!response.ok) fail('product_page_http_error');
    if (!/^(?:text\/html|application\/xhtml\+xml)(?:;|$)/iu.test(response.headers.get('content-type') || '')) fail('unsupported_product_page');
    const reader = response.body?.getReader();
    if (!reader) fail('invalid_product_page');
    let size = 0; const decoder = new TextDecoder(); let html = '';
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 768 * 1024) { html += decoder.decode(value.subarray(0, Math.max(0, 768 * 1024 - (size - value.length))), { stream: true }); await reader.cancel(); break; }
        html += decoder.decode(value, { stream: true });
      }
      html += decoder.decode();
    } catch (error) { await reader.cancel().catch(() => {}); throw error; }
    const metadata = new Map();
    for (const tag of html.match(/<meta\b[^>]{0,5000}>/giu) || []) {
      const attrs = new Map();
      for (const a of tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/gu)) attrs.set(a[1].toLowerCase(), decode(a[2] ?? a[3]));
      const key = (attrs.get('property') || attrs.get('name') || '').toLowerCase();
      if (!metadata.has(key)) metadata.set(key, attrs.get('content'));
    }
    const raw = metadata.get('og:image:secure_url') || metadata.get('og:image') || metadata.get('twitter:image');
    let imageUrl;
    try { imageUrl = raw && safe(new URL(raw, url).href); } catch { /* Reject malformed metadata. */ }
    if (!imageUrl) fail('product_image_missing');
    const clean = s => typeof s === 'string' ? s.replace(/<[^>]*>|[\u0000-\u001f]/gu, ' ').slice(0, 500) : null;
    return { imageUrl, pageTitle: clean(metadata.get('og:title')), pageDescription: clean(metadata.get('og:description') || metadata.get('description')) };
  } catch (error) {
    if (controller.signal.aborted) fail(signal?.aborted ? 'request_aborted' : 'product_page_timeout');
    if (error?.code) throw error;
    fail('product_page_unavailable');
  } finally { clearTimeout(timer); signal?.removeEventListener('abort', abort); }
}
