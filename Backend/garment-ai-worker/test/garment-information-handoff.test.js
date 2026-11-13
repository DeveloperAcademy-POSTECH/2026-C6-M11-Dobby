import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeInformation, buildWritingBrief, informationUsage } from '../src/garment-information-handoff.js';
const observations = [{ photoId: 'chest', kind: 'embroidery', text: 'KUKKOLA OY' }];
const meaning = { category: 'marking_meaning', certainty: 'fact', statement: '핀란드 업체의 회사명 자수', photoIds: ['chest'] };
test('preserves source meaning and cautious use context while rejecting invented photo IDs and unsupported direct facts', () => {
  const use = { ...meaning, category: 'use_context', certainty: 'possibility', statement: '해당 업체의 업무복 사용 가능성' };
  assert.deepEqual(normalizeInformation([meaning, use], observations, 'organization'), [meaning, use]);
  assert.deepEqual(normalizeInformation([{ ...meaning, photoIds: ['invented'] }], observations, 'organization'), []);
  assert.deepEqual(normalizeInformation([{ ...use, certainty: 'fact' }], observations, 'organization'), []);
});
test('builds explicit source and original-photo links for the writer', () => {
  const brief = buildWritingBrief([{ id: 4, url: 'https://inlook.fi/company', contextType: 'organization', information: [meaning] }]);
  assert.equal(brief[0].sourceId, 4); assert.equal(brief[0].sourceUrl, 'https://inlook.fi/company');
  assert.deepEqual(brief[0].photoIds, ['chest']);
});
test('included information must cite text actually in the description; missing reporting remains visible', () => {
  const brief = buildWritingBrief([{ id: 4, url: 'https://inlook.fi/company', information: [meaning] }]);
  const item = { informationId: brief[0].id, decision: 'included', reason: '원본 자수와 업체명이 일치', descriptionExcerpt: '회사명 자수가 있습니다' };
  const usage = informationUsage([item], brief, '가슴에 회사명 자수가 있습니다.');
  assert.equal(usage[0].decision, 'included');
  assert.throws(() => informationUsage([item], brief, '다른 설명'));
  assert.throws(() => informationUsage([{ ...item, informationId: 'invented' }], brief, '회사명 자수가 있습니다'));
  assert.equal(informationUsage([], brief, '').at(0).decision, 'not_reported');
});
