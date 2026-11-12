import { publicURL } from './garment-heritage.js';
const MAX_BYTES = 2 * 1024 * 1024;
const fail = code => { throw Object.assign(new Error(code), { code }); };

// Cloudflare's default public Internet fetch service additionally prevents private-IP
// connections, including DNS rebinding. Never use a private-network binding here.
export async function downloadComparisonImage(url, { fetchImpl, signal, timeoutMs = 6000 }) {
  const safe = publicURL(url);
  if (!safe || new URL(safe).port || !/[a-z]/i.test(new URL(safe).hostname.split('.').at(-1))) fail('unsafe_image_url');
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) abort();
  const timer = setTimeout(abort, timeoutMs);
  try {
    const response = await fetchImpl(safe, { redirect: 'manual', credentials: 'omit',
      headers: { Accept: 'image/jpeg,image/png,image/webp' }, signal: controller.signal });
    if (response.status >= 300 && response.status < 400) fail('image_redirect_rejected');
    if (!response.ok) fail('image_http_error');
    const mime = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(mime)) fail('unsupported_image_type');
    if (Number(response.headers.get('content-length')) > MAX_BYTES) fail('image_too_large');
    const reader = response.body?.getReader();
    if (!reader) fail('invalid_image');
    let size = 0; const chunks = [];
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > MAX_BYTES) fail('image_too_large');
        chunks.push(value);
      }
    } catch (error) { await reader.cancel().catch(() => {}); throw error; }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const { width, height } = dimensions(bytes, mime);
    if (!width || !height || width > 8192 || height > 8192 || width * height > 16000000) fail('invalid_image_dimensions');
    let binary = '';
    for (let i = 0; i < size; i += 16384) binary += String.fromCharCode(...bytes.subarray(i, i + 16384));
    const sha256 = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2, '0')).join('');
    return { dataUrl: `data:${mime};base64,${btoa(binary)}`, mimeType: mime, bytes: size, width, height, sha256 };
  } catch (error) {
    if (controller.signal.aborted) fail(signal?.aborted ? 'request_aborted' : 'image_download_timeout');
    if (error?.code) throw error;
    fail('image_download_failed');
  } finally { clearTimeout(timer); signal?.removeEventListener('abort', abort); }
}
function dimensions(b, mime) {
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const ascii = (start, end) => String.fromCharCode(...b.subarray(start, end));
  if (mime === 'image/png' && b.length >= 45 && ascii(1, 4) === 'PNG' && b[0] === 137
    && b[4] === 13 && b[5] === 10 && b[6] === 26 && b[7] === 10
    && v.getUint32(8) === 13 && ascii(12, 16) === 'IHDR' && ascii(b.length - 8, b.length - 4) === 'IEND') {
    return { width: v.getUint32(16), height: v.getUint32(20) };
  }
  if (mime === 'image/jpeg' && b.length >= 12 && b[0] === 255 && b[1] === 216 && b.at(-2) === 255 && b.at(-1) === 217) {
    for (let i = 2; i + 8 < b.length;) {
      if (b[i++] !== 255) break;
      while (b[i] === 255) i++;
      const marker = b[i++];
      if (marker === 218 || marker === 217) break;
      if (marker === 1 || marker >= 208 && marker <= 215) continue;
      if (i + 2 > b.length) break;
      const length = v.getUint16(i);
      if (length < 2 || i + length > b.length) break;
      if ([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker) && length >= 8)
        return { width: v.getUint16(i + 5), height: v.getUint16(i + 3) };
      i += length;
    }
  }
  if (mime === 'image/webp' && b.length >= 30 && ascii(0,4) === 'RIFF' && ascii(8,12) === 'WEBP' && v.getUint32(4,true) + 8 === b.length) {
    const kind = ascii(12,16);
    if (kind === 'VP8X' && !(b[20] & 2)) return { width: 1 + b[24] + (b[25]<<8) + (b[26]<<16), height: 1 + b[27] + (b[28]<<8) + (b[29]<<16) };
    if (kind === 'VP8 ' && b[23] === 157 && b[24] === 1 && b[25] === 42) return { width: v.getUint16(26,true) & 16383, height: v.getUint16(28,true) & 16383 };
    if (kind === 'VP8L' && b[20] === 47) return { width: 1 + ((b[22]&63)<<8) + b[21], height: 1 + ((b[24]&15)<<10) + (b[23]<<2) + (b[22]>>6) };
  }
  fail('invalid_image');
}
