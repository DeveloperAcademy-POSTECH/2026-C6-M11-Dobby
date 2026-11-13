import { DraftResponseError } from './garment-draft.js';
export const INFORMATION_CATEGORIES = ['product_identity', 'marking_meaning', 'use_context'];
const text = (v, max) => typeof v === 'string' && v.trim().length > 0 && v.length <= max && !/[\u0000-\u001f]/u.test(v);
export function normalizeInformation(items, observations, contextType) {
  if (!Array.isArray(items)) return [];
  const ids = new Set(observations.map(o => o.photoId));
  return items.slice(0, 2).filter(item => item && INFORMATION_CATEGORIES.includes(item.category)
    && ['fact','possibility'].includes(item.certainty) && text(item.statement, 220)
    && Array.isArray(item.photoIds) && item.photoIds.length > 0 && item.photoIds.length <= 5
    && new Set(item.photoIds).size === item.photoIds.length && item.photoIds.every(id => ids.has(id))
    && !(item.category === 'use_context' && item.certainty === 'fact' && contextType !== 'documented_relationship'))
    .map(item => ({ category: item.category, certainty: item.certainty, statement: item.statement.trim(), photoIds: item.photoIds }));
}
// Request-scoped ID: photo IDs identify views of this one product, not products.
export const ORIGINAL_PRODUCT_GROUP_ID = 'target-garment';
export function originalProductContext(photos) {
  return { productGroupId: ORIGINAL_PRODUCT_GROUP_ID, sameProduct: true,
    photoIds: photos.map(photo => photo.id),
    photos: photos.map(photo => ({ photoId: photo.id, role: photo.role || 'detail' })) };
}
export function buildWritingBrief(evidence, originalPhotos = []) {
  const originalIds = new Set(originalPhotos.map(photo => photo.id));
  return evidence.flatMap(source => (source.information || []).map((item, index) => ({
    id: `source-${source.id}-info-${index}`, sourceId: source.id, sourceUrl: source.url,
    contextType: source.contextType, ...item,
    ...(item.photoIds?.length && item.photoIds.every(id => originalIds.has(id))
      ? { productGroupId: ORIGINAL_PRODUCT_GROUP_ID, appliesTo: 'whole_product',
        photoIdsMeaning: 'original_views_where_the_information_was_observed' } : {}),
  }))).slice(0, 10);
}
export const INFORMATION_USAGE_SCHEMA = { type: 'array', maxItems: 10, items: {
  type: 'object', additionalProperties: false,
  properties: { informationId: { type: 'string' }, decision: { type: 'string', enum: ['included','omitted'] },
    reason: { type: 'string', maxLength: 160 }, descriptionExcerpt: { type: ['string','null'], maxLength: 220 } },
  required: ['informationId','decision','reason','descriptionExcerpt'],
} };
export function informationUsage(items, brief, description) {
  if (!Array.isArray(items) || items.length > 10) throw new DraftResponseError();
  const seen = new Set();
  for (const item of items) {
    if (!item || !brief.some(info => info.id === item.informationId) || seen.has(item.informationId)
      || !['included','omitted'].includes(item.decision) || !text(item.reason, 160)
      || (item.decision === 'included' ? !text(item.descriptionExcerpt, 220) || !description.includes(item.descriptionExcerpt)
        : item.descriptionExcerpt !== null)) throw new DraftResponseError();
    seen.add(item.informationId);
  }
  // Reports are model self-assessments; an exact excerpt check proves only that
  // the cited wording exists, not that it correctly represents the external fact.
  return brief.map(info => ({ ...info, ...(items.find(item => item.informationId === info.id)
    || { decision: 'not_reported', reason: '모델이 반영 여부를 보고하지 않았습니다.', descriptionExcerpt: null }) }));
}
