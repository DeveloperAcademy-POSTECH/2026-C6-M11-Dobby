import test from 'node:test';
import assert from 'node:assert/strict';
import { validateSearchPlan, searchGarmentKeywords } from '../src/garment-keyword-search.js';
const photos = [{ id: 'label' }, { id: 'front' }];
const plan = { photoIds: ['front','label'], observations: [{ photoId: 'label', kind: 'brand_candidate', text: 'CLIQUE' }, { photoId: 'front', kind: 'embroidery', text: 'KUKKOLA OY' }], queries: ['CLIQUE denim shirt history','KUKKOLA OY company'] };
const payload = findings => ({ status: 'completed', output: [
  { type: 'web_search_call', status: 'completed', action: { type: 'search', queries: plan.queries, sources: [{ url: 'https://clique.se/about', title: 'CLIQUE' }] } },
  { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: JSON.stringify({ findings }) }] },
] });
test('plan preserves brand vs embroidery; rejects invented photo references and unbounded queries', () => {
  assert.equal(validateSearchPlan(plan, photos), plan);
  for (const overrides of [{ photoIds: ['missing'] }, { queries: ['x'.repeat(241)] }, { observations: [{ photoId: 'missing', kind: 'brand_candidate', text: 'CLIQUE' }] }, { observations: [{ photoId: 'label', kind: 'company', text: 'CLIQUE' }] }])
    assert.throws(() => validateSearchPlan({ ...plan, ...overrides }, photos));
});
test('search uses bounded native tool and only returns findings with real tool provenance', async () => {
  const result = await searchGarmentKeywords(plan, async body => {
    assert.equal(body.model, 'gpt-6-luna'); assert.equal(body.tool_choice, 'required'); assert.equal(body.max_tool_calls, 1);
    assert.equal(JSON.parse(body.input[0].content[0].text).queries.length, 1);
    return payload([{ sourceUrl: 'https://clique.se/about', summary: '브랜드 배경' }, { sourceUrl: 'https://invented.com/about', summary: '만들어낸 출처' }]);
  });
  assert.equal(result.evidence.length, 1); assert.equal(result.evidence[0].kind, 'web_research');
  assert.deepEqual(result.queries, plan.queries); assert.equal(result.searchCalls, 2);
});
test('absence of native search cannot be presented as successful research', async () => {
  assert.equal((await searchGarmentKeywords(plan, async () => ({ ...payload([]), output: payload([]).output.slice(1) }))).status, 'failed');
});
test('no usable search terms skip web tool without fabricating search', async () => {
  assert.equal((await searchGarmentKeywords({ ...plan, queries: [] }, () => assert.fail())).status, 'skipped');
});
test('server dispatches every planned query separately and preserves partial failure', async () => {
  const sent = [];
  const result = await searchGarmentKeywords(plan, async body => {
    const query = JSON.parse(body.input[0].content[0].text).queries;
    assert.equal(query.length, 1); sent.push(query[0]);
    if (query[0].includes('KUKKOLA')) throw Error('private-secret');
    const response = payload([{ sourceUrl: 'https://clique.se/about', summary: '브랜드 배경' }]);
    response.output[0].action.queries = query;
    return response;
  });
  assert.deepEqual(sent, plan.queries);
  assert.equal(result.status, 'incomplete');
  assert.equal(result.attempts[1].status, 'failed');
  assert.equal(result.evidence.length, 1);
  assert.ok(!JSON.stringify(result).includes('private-secret'));
});

test('organization evidence survives a full set of product candidates', async () => {
  const result = await searchGarmentKeywords(plan, async body => {
    const query = JSON.parse(body.input[0].content[0].text).queries[0];
    const findings = query.includes('KUKKOLA')
      ? [{ sourceUrl: 'https://inlook.fi/company', summary: 'KUKKOLA OY 회사 정보', contextType: 'organization' }]
      : Array.from({ length: 5 }, (_, i) => ({ sourceUrl: `https://clique.se/product/${i}`, summary: '데님 상품', productName: `Denim ${i}`, productFeatures: [], contextType: 'product' }));
    const response = payload(findings);
    response.output[0].action.sources = findings.map(f => ({ url: f.sourceUrl, title: 'Source' }));
    return response;
  });
  assert.equal(result.evidence.length, 5);
  assert.equal(result.evidence[0].contextType, 'organization');
});
test('direct manufacturing relationship requires sourced names, original observations and a relation quote', async () => {
  const relation = { sourceUrl: 'https://clique.se/about', summary: 'CLIQUE가 KUKKOLA OY용 의류를 공급한 사례',
    contextType: 'documented_relationship', relatedBrand: 'CLIQUE', relatedOrganization: 'KUKKOLA OY',
    supportingQuote: 'CLIQUE supplied embroidered workwear to KUKKOLA OY.' };
  const single = { ...plan, queries: ['CLIQUE KUKKOLA OY uniform'] };
  const valid = await searchGarmentKeywords(single, async () => payload([relation]));
  assert.equal(valid.evidence[0].contextType, 'documented_relationship');
  for (const override of [{ supportingQuote: null }, { supportingQuote: 'CLIQUE and KUKKOLA OY.' },
    { relatedOrganization: 'OTHER ORGANIZATION' }, { sourceUrl: 'https://invented.com/case' }]) {
    const invalid = await searchGarmentKeywords(single, async () => payload([{ ...relation, ...override }]));
    assert.equal(invalid.evidence.length, 0);
  }
});
