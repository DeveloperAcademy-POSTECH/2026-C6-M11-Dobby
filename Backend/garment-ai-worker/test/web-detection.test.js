import test from "node:test";
import assert from "node:assert/strict";
import { runWebDetectionAutofill, searchWebDetection, normalizeWebDetection } from "../src/garment-web-detection.js";
import { createWorker } from "../src/index.js";
const image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const photos = [{ id: "front", imageDataUrl: image }, { id: "label", imageDataUrl: image }];
const source = { title: "Brand official", url: "https://clique.se/about", snippet: "Corporate clothing", photoId: "label" };
const draft = { brand: { originalName: "CLIQUE", localizedName: null },
  productNameWithoutBrand: "블루 데님 셔츠", description: "- 가슴 업체명 자수와 스냅 버튼\n- 유니폼으로 사용되었을 가능성", reviewNotes: [] };
const synthesis = (overrides = {}) => ({ draft, informationUsage: [], sourceIds: [0], brandPhotoId: "label", brandObservedText: "CLIQUE", ...overrides });
const model = value => ({ status: "completed", output: [{ type: "message", role: "assistant",
  content: [{ type: "output_text", text: JSON.stringify(value) }] }] });
const plan = ids => ({ photoIds: ids, observations: [{ photoId: "label", kind: "brand_candidate", text: "CLIQUE" }], queries: ["CLIQUE denim shirt"] });
const emptyResearch = () => ({ ...model({ findings: [] }), output: [{ type: "web_search_call", status: "completed", action: { type: "search", query: "CLIQUE denim shirt", sources: [] } }, ...model({ findings: [] }).output] });
function pipeline(options = {}) {
  const requests = [], searches = [];
  return { requests, searches, run: () => runWebDetectionAutofill(photos, {
    requestResponse: async body => { if (body.text.format.name === "garment_keyword_research") return emptyResearch(); requests.push(body); return model(requests.length === 1
      ? plan(options.ids || ["front", "label"]) : synthesis(options.result)); },
    searchPhoto: async photo => { searches.push(photo.id); if (options.fail === photo.id || options.fail === "all") throw Error("provider-secret");
      return { evidence: options.empty ? [] : [source], calls: 1 }; },
  }) };
}
test("Web Detection searches whole garment and label without an OCR prerequisite, preserving brand vs embroidery", async () => {
  const p = pipeline(); const result = await p.run();
  assert.deepEqual(p.searches, ["front", "label"]);
  assert.equal(result.draft.brand, "CLIQUE");
  assert.equal(result.draft.sources.length, 1);
  assert.match(result.draft.description, /가능성/u);
  assert.equal(result.researchStatus, "matched");
  assert.equal(p.requests.length, 2);
  assert.equal(p.requests[1].model, "gpt-6-luna");
  assert.equal(p.requests[1].tools, undefined);
});
test("unknown, duplicate and excessive selected photo IDs never trigger paid searches", async () => {
  for (const ids of [["missing"], ["front", "front"], ["front", "label", "front"], []]) {
    const p = pipeline({ ids }); await assert.rejects(p.run()); assert.equal(p.searches.length, 0);
  }
});
test("invalid citations and invented brand photo evidence are rejected", async () => {
  for (const result of [{ sourceIds: [100] }, { sourceIds: [0, 0] }, { brandPhotoId: "invented" }, { brandObservedText: null }]) {
    await assert.rejects(pipeline({ result }).run());
  }
});
test("empty search results allow a photo description with explicit missing-source note", async () => {
  const result = await pipeline({ empty: true, result: { sourceIds: [] } }).run();
  assert.equal(result.researchStatus, "no_match"); assert.deepEqual(result.draft.sources, []);
  assert.match(result.draft.reviewNotes.join(" "), /검색에서/u);
});
test("partial search failure uses surviving evidence and warns; complete outage is an error", async () => {
  const result = await pipeline({ fail: "front" }).run();
  assert.equal(result.researchStatus, "incomplete"); assert.match(result.draft.reviewNotes[0], /일부/u);
  await assert.rejects(pipeline({ fail: "all" }).run(), { code: "web_detection_unavailable" });
});
test("source normalization rejects local/unsafe links and bounds text", () => {
  const items = normalizeWebDetection({ pagesWithMatchingImages: [
    { pageTitle: "bad", url: "http://127.0.0.1/" }, { pageTitle: "bad", url: "https://x.local/" },
    { pageTitle: "ok", url: source.url, snippet: "x".repeat(2000) },
  ] }, "front");
  assert.equal(items.evidence.length, 1); assert.equal(items.evidence[0].title, "ok");
});
const detection = { webEntities: [{ description: "CLIQUE", score: 0.9 }], bestGuessLabels: [{ label: "denim shirt" }],
  pagesWithMatchingImages: [{ url: source.url, pageTitle: "<b>Brand</b> official",
    fullMatchingImages: [{ url: "https://clique.se/shirt.jpg" }] }],
  visuallySimilarImages: [{ url: "https://images.clique.se/similar.jpg" }] };
function providerHarness(payload = { responses: [{ webDetection: detection }] }, status = 200) {
  const calls = [];
  return { calls, fetchImpl: async (url, init) => {
    calls.push({ url: String(url), init });
    assert.equal(url, "https://vision.googleapis.com/v1/images:annotate");
    assert.equal(init.headers["X-Goog-Api-Key"], "private-key");
    const body = JSON.parse(init.body);
    assert.deepEqual(body.requests[0].features, [{ type: "WEB_DETECTION", maxResults: 8 }]);
    assert.equal(body.requests[0].image.content, image.split(",")[1]);
    assert.equal(init.redirect, "manual");
    return Response.json(payload, { status });
  } };
}
test("Web Detection sends original bytes to Google's fixed endpoint with server-only header auth", async () => {
  const h = providerHarness();
  const result = await searchWebDetection(photos[0], { ...h, apiKey: "private-key" });
  assert.equal(h.calls.length, 1); assert.equal(result.calls, 1);
  assert.deepEqual(result.keywords, ["CLIQUE", "denim shirt"]);
  assert.equal(result.evidence[0].imageUrl, "https://clique.se/shirt.jpg");
  assert.equal(result.evidence[1].kind, "visually_similar");
  assert.ok(!JSON.stringify(result).includes("private-key"));
});
test("empty Web Detection is a successful search; malformed or per-image errors are failures", async () => {
  const result = await searchWebDetection(photos[0], { ...providerHarness({ responses: [{}] }), apiKey: "private-key" });
  assert.deepEqual(result.evidence, []);
  for (const payload of [{}, { responses: [] }, { responses: [null] }, { responses: [{ webDetection: [] }] },
    { responses: [{ error: { code: 3, message: "private secret" } }] }]) {
    await assert.rejects(searchWebDetection(photos[0], { ...providerHarness(payload), apiKey: "private-key" }),
      { code: "web_detection_unavailable" });
  }
});
test("permission and quota failures are classified without exposing raw provider errors", async () => {
  for (const [status, code] of [[403, "web_detection_configuration_error"], [429, "web_detection_rate_limited"]]) {
    await assert.rejects(searchWebDetection(photos[0], { ...providerHarness({ error: "private-key" }, status), apiKey: "private-key" }),
      error => error.code === code && !error.message.includes("private-key"));
  }
  await assert.rejects(searchWebDetection(photos[0], { ...providerHarness({ responses: [{ error: { code: 7 } }] }), apiKey: "private-key" }),
    { code: "web_detection_configuration_error" });
});
test("oversized photos and invalid image formats fail before any upstream call", async () => {
  let count = 0;
  for (const imageDataUrl of ["data:text/plain;base64,AAAA", "data:image/jpeg;base64," + Buffer.alloc(2 * 1024 * 1024 + 1).toString("base64")]) {
    await assert.rejects(searchWebDetection({ imageDataUrl }, { apiKey: "private-key", fetchImpl: () => { count++; } }));
  }
  assert.equal(count, 0);
});
test("normalization bounds keywords and references and excludes unsafe comparison URLs", () => {
  const value = normalizeWebDetection({ webEntities: Array(50).fill({ description: "x".repeat(1000) }),
    fullMatchingImages: [{ url: "https://127.0.0.1/image.jpg" }, { url: "https://x.local/a.jpg" },
      { url: "https://clique.se:8080/a.jpg" }], visuallySimilarImages: [{ url: "https://clique.se/a.jpg" }] }, "front");
  assert.equal(value.evidence.length, 1);
  assert.equal(value.keywords.length, 1); assert.equal(value.keywords[0].length, 160);
});
const env = { DRAFT_API_TOKEN: "test-token", OPENAI_API_KEY: "openai-key" };
function incoming(token = "test-token", route = "autofill-web-detection") {
  return new Request("https://worker.example/v1/garments/" + route, { method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` }, body: JSON.stringify({ photos }) });
}
test("new route requires auth and a Google key, and the removed Lens route is unavailable", async () => {
  let count = 0; const worker = createWorker({ fetchImpl: () => { count++; } });
  assert.equal((await worker.fetch(incoming("wrong"), env)).status, 401);
  const response = await worker.fetch(incoming(), env);
  assert.equal(response.status, 503); assert.equal((await response.json()).error.code, "service_not_configured");
  assert.equal((await worker.fetch(incoming("test-token", "autofill-lens"), env)).status, 404);
  assert.equal(count, 0);
});
function workerHarness({ imageError, imageParam, providerStatus = 200, downloadFailure = false } = {}) {
  const requests = [], h = providerHarness(undefined, providerStatus);
  let synthesisCalls = 0;
  const worker = createWorker({ fetchImpl: async (url, init) => {
    if (String(url).includes("api.openai.com")) {
      const body = JSON.parse(init.body);
      if (body.text.format.name === "garment_keyword_research") return Response.json(emptyResearch());
      requests.push(body);
      if (body.text.format.name === "garment_web_detection_selection") return Response.json(model(plan(["front"])));
      synthesisCalls++;
      if (imageError && synthesisCalls === 1) return Response.json({ error: { code: imageError, param: imageParam, message: "private-secret" } }, { status: 400 });
      return Response.json(model(synthesis()));
    }
    if (!String(url).includes("vision.googleapis.com") && downloadFailure) return new Response(null, { status: 404 });
    if (!String(url).includes("vision.googleapis.com")) return new Response(Buffer.from(image.split(",")[1], "base64"), { headers: { "Content-Type": "image/png" } });
    return h.fetchImpl(url, init);
  } });
  return { requests, worker, providerCalls: h.calls, run: (route = "autofill-web-detection") => worker.fetch(incoming("test-token", route), { ...env, GOOGLE_VISION_API_KEY: "private-key" }) };
}
test("route supplies actual comparison images to Luna and returns existing app contract and timing headers", async () => {
  const h = workerHarness(), response = await h.run();
  assert.equal(response.status, 200, await response.clone().text());
  assert.equal((await response.json()).brand, "CLIQUE");
  assert.equal(h.providerCalls.length, 1);
  const content = h.requests[1].input[0].content;
  assert.equal(content.filter(item => item.type === "input_image" && item.image_url.startsWith("https:")).length, 0);
  assert.equal(content.filter(item => item.type === "input_image" && item.image_url.startsWith("data:")).length, 4);
  const metadata = JSON.parse(content[0].text);
  assert.deepEqual(metadata.keywords, ["CLIQUE", "denim shirt"]);
  for (const stage of ["Identification", "Web-Detection", "Synthesis", "Server"]) {
    assert.notEqual(response.headers.get(`X-Dobby-AI-${stage}-Ms`), null);
  }
});
test("inaccessible remote images cause exactly one text-only recovery with explicit review note", async () => {
  const h = workerHarness({ imageError: "invalid_image_url" }), response = await h.run();
  assert.equal(response.status, 200);
  const result = await response.json(); assert.match(result.reviewNotes.join(" "), /외부 비교 이미지/u);
  assert.equal(h.requests.length, 3); assert.equal(h.providerCalls.length, 1);
  assert.ok(h.requests[2].input[0].content.filter(item => item.type === "input_image").every(item => item.image_url.startsWith("data:")));
  assert.deepEqual(JSON.parse(h.requests[2].input[0].content[0].text).comparisonSourceIds, []);
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "incomplete");
});
test("other OpenAI failures never cause a retry and provider failure is sanitized", async () => {
  const h = workerHarness({ imageError: "invalid_json_schema" }), response = await h.run();
  assert.equal(response.status, 502); assert.equal(h.requests.length, 2);
  assert.ok(!(await response.text()).includes("private-secret"));
  const permission = await workerHarness({ providerStatus: 403 }).run();
  assert.equal(permission.status, 503);
  assert.equal((await permission.json()).error.code, "web_detection_configuration_error");
});

test("non-ASCII pasted credentials fail before photo selection or any API request", async () => {
  let calls = 0;
  const worker = createWorker({ fetchImpl: () => { calls++; } });
  const response = await worker.fetch(incoming(), { ...env, GOOGLE_VISION_API_KEY: "잘못붙여넣은값" });
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("X-Dobby-Vision-Reason"), "INVALID_KEY_FORMAT");
  assert.equal(calls, 0);
});

test("Google redirect is rejected without following a location or leaking the key", async () => {
  let calls = 0;
  await assert.rejects(searchWebDetection(photos[0], { apiKey: "private-key", fetchImpl: async () => {
    calls++; return new Response(null, { status: 302, headers: { Location: "https://untrusted.example/" } });
  } }), error => error.providerReason === "UNEXPECTED_REDIRECT");
  assert.equal(calls, 1);
});

test("billing diagnostics expose only a numeric Google consumer project, never raw provider metadata", async () => {
  for (const [consumer, expected] of [["projects/123456789", "123456789"], ["projects/private-key", undefined]]) {
    await assert.rejects(searchWebDetection(photos[0], { apiKey: "private-key", ...providerHarness({ error: {
      status: "PERMISSION_DENIED", message: "private-key", details: [{ domain: "googleapis.com", reason: "BILLING_DISABLED",
        metadata: { consumer, secret: "private-key" } }],
    } }, 403) }), error => error.providerProject === expected && !error.message.includes("private-key"));
  }
});

test("rejected remote image input permits one recovery without repeating Google search", async () => {
  const h = workerHarness({ imageError: "invalid_value", imageParam: "input" });
  const response = await h.run();
  assert.equal(response.status, 200);
  assert.equal(h.requests.length, 3);
  assert.equal(h.providerCalls.length, 1);
  assert.match((await response.json()).reviewNotes.join(" "), /외부 비교 이미지/u);
});

test("tester exposes selected photos and the exact final Luna inputs without image bytes or credentials", async () => {
  const h = workerHarness();
  const response = await h.run("autofill-web-detection-test");
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.deepEqual(data.trace.selectedPhotoIds, ["front"]);
  assert.equal(data.trace.searches[0].photoId, "front");
  assert.deepEqual(data.trace.searches[0].keywords, ["CLIQUE", "denim shirt"]);
  const input = JSON.parse(h.requests[1].input[0].content[0].text);
  assert.deepEqual(data.trace.synthesisAttempts[0].evidence, input.evidence);
  assert.deepEqual(data.trace.synthesisAttempts[0].keywords, input.keywords);
  assert.deepEqual(data.trace.synthesisAttempts[0].comparisonSourceIds, input.comparisonSourceIds);
  assert.deepEqual(data.trace.synthesisAttempts[0].originalPhotoIds, ["front", "label"]);
  assert.equal(data.trace.comparisonDownloads.filter(item => item.status === "success").length, 2);
  assert.equal(data.trace.synthesisAttempts[0].comparisonImageTransport, "data_url");
  assert.equal(data.trace.brandPhotoId, "label");
  assert.equal(data.draft.brand, "CLIQUE");
  assert.ok(!JSON.stringify(data).includes("base64"));
  assert.ok(!JSON.stringify(data).includes("private-key"));
});
test("tester preserves both rejected image attempt and successful recovery inputs", async () => {
  const h = workerHarness({ imageError: "invalid_image_url" });
  const response = await h.run("autofill-web-detection-test");
  const data = await response.json();
  assert.equal(data.trace.synthesisAttempts.length, 2);
  assert.equal(data.trace.synthesisAttempts[0].status, "failed");
  assert.equal(data.trace.synthesisAttempts[1].status, "success");
  assert.deepEqual(data.trace.synthesisAttempts[1].comparisonSourceIds, []);
  assert.equal(data.trace.comparisonFailed, true);
});
test("tester keeps completed selection and Google error details when final generation fails", async () => {
  const h = workerHarness({ providerStatus: 403 });
  const response = await h.run("autofill-web-detection-test");
  assert.equal(response.status, 503);
  const data = await response.json();
  assert.equal(data.draft, null);
  assert.deepEqual(data.trace.selectedPhotoIds, ["front"]);
  assert.equal(data.trace.searches[0].status, "failed");
  assert.equal(data.trace.searches[0].errorCode, "web_detection_configuration_error");
  assert.deepEqual(data.trace.synthesisAttempts, []);
  assert.equal(data.error.code, "web_detection_configuration_error");
});

test("failed comparison downloads remain visible and never pass remote URLs to Luna", async () => {
  const h = workerHarness({ downloadFailure: true });
  const response = await h.run("autofill-web-detection-test");
  const data = await response.json();
  assert.equal(response.status, 200);
  assert.equal(data.trace.comparisonDownloads.length, 2);
  assert.ok(data.trace.comparisonDownloads.every(item => item.status === "failed" && item.errorCode === "image_http_error"));
  assert.deepEqual(data.trace.synthesisAttempts[0].comparisonSourceIds, []);
  assert.equal(h.requests[1].input[0].content.filter(item => item.type === "input_image").length, 2);
  assert.match(data.draft.reviewNotes.join(" "), /외부 비교 이미지/u);
});

test("image and keyword searches run concurrently; sourced research reaches synthesis", async () => {
  let releaseImages, releaseText;
  const imagesStarted = new Promise(resolve => { releaseImages = resolve; });
  const textStarted = new Promise(resolve => { releaseText = resolve; });
  const trace = { synthesisAttempts: [] };
  const result = await runWebDetectionAutofill(photos, {
    diagnostics: trace,
    searchPhoto: async () => { releaseImages(); await textStarted; return { evidence: [], calls: 1, keywords: [] }; },
    requestResponse: async body => {
      if (body.text.format.name === "garment_web_detection_selection") return model(plan(["front"]));
      if (body.text.format.name === "garment_keyword_research") {
        releaseText(); await imagesStarted;
        return { ...model({ findings: [{ sourceUrl: source.url, summary: "공식 브랜드 배경" }] }), output: [
          { type: "web_search_call", status: "completed", action: { type: "search", query: "CLIQUE denim shirt", sources: [source] } },
          ...model({ findings: [{ sourceUrl: source.url, summary: "공식 브랜드 배경" }] }).output,
        ] };
      }
      const input = JSON.parse(body.input[0].content[0].text);
      assert.equal(input.evidence[0].summary, "공식 브랜드 배경");
      assert.deepEqual(input.observations, plan([]).observations);
      return model(synthesis());
    },
  });
  assert.equal(result.searchCalls, 2);
  assert.equal(result.draft.sources[0].url, source.url);
  assert.equal(trace.keywordSearch.status, "success");
});

test("keyword search failure is explicit while usable image results still generate a draft", async () => {
  const result = await runWebDetectionAutofill(photos, {
    searchPhoto: async () => ({ evidence: [source], calls: 1 }),
    requestResponse: async body => {
      if (body.text.format.name === "garment_web_detection_selection") return model(plan(["front"]));
      if (body.text.format.name === "garment_keyword_research") throw Error('private-secret');
      return model(synthesis());
    },
  });
  assert.equal(result.researchStatus, 'incomplete');
  assert.match(result.draft.reviewNotes.join(' '), /키워드 웹 검색/u);
  assert.ok(!JSON.stringify(result).includes('private-secret'));
});

test("keyword product page images are prioritized over generic Web Detection images", async () => {
  const candidate = { sourceUrl: 'https://poshmark.com/listing/palace-save-thyself', summary: 'Heart graphic with arm wrestling figures', productName: 'Palace Save Thyself T-Shirt', productFeatures: ['Heart with two arm wrestling figures', 'Save Thyself lettering'] };
  const downloaded = [], trace = { synthesisAttempts: [] };
  const result = await runWebDetectionAutofill(photos, {
    diagnostics: trace,
    searchPhoto: async () => ({ evidence: [{ ...source, imageUrl: 'https://images.example.com/generic.jpg' }], calls: 1 }),
    loadProductImage: async url => { assert.equal(url, candidate.sourceUrl); return { imageUrl: 'https://images.example.com/palace.jpg', pageTitle: candidate.productName }; },
    downloadImage: async url => { downloaded.push(url); return { dataUrl: image, bytes: 68, width: 1, height: 1, mimeType: 'image/png' }; },
    requestResponse: async body => {
      if (body.text.format.name === 'garment_web_detection_selection') return model(plan(['front']));
      if (body.text.format.name === 'garment_keyword_research') return { ...model({ findings: [candidate] }), output: [
        { type: 'web_search_call', status: 'completed', action: { type: 'search', query: 'Palace Save Thyself', sources: [{ url: candidate.sourceUrl, title: candidate.productName }] } },
        ...model({ findings: [candidate] }).output,
      ] };
      const input = JSON.parse(body.input[0].content[0].text);
      assert.equal(input.evidence.find(e => e.productName)?.imageUrl, 'https://images.example.com/palace.jpg');
      assert.match(body.instructions, /같은 모델로 판단/u);
      assert.match(body.instructions, /조사 보고 문장은 reviewNotes/u);
      return model(synthesis());
    },
  });
  assert.equal(downloaded[0], 'https://images.example.com/palace.jpg');
  assert.equal(trace.productPages[0].status, 'success');
  assert.equal(result.draft.brand, 'CLIQUE');
});

test('sourced embroidery meaning and possible use pass intact to writing and auditable final excerpts', async () => {
  const trace = { synthesisAttempts: [] };
  const information = [
    { category: 'marking_meaning', certainty: 'fact', statement: 'KUKKOLA OY는 핀란드 업체', photoIds: ['front'] },
    { category: 'use_context', certainty: 'possibility', statement: '해당 업체의 업무복으로 사용됐을 가능성', photoIds: ['front'] },
  ];
  const result = await runWebDetectionAutofill(photos, {
    diagnostics: trace,
    searchPhoto: async () => ({ evidence: [], keywords: [], calls: 1 }),
    requestResponse: async body => {
      if (body.text.format.name === 'garment_web_detection_selection') return model({ ...plan(['front']),
        observations: [...plan([]).observations, { photoId: 'front', kind: 'embroidery', text: 'KUKKOLA OY' }] });
      if (body.text.format.name === 'garment_keyword_research') return { ...model({ findings: [{ sourceUrl: source.url, summary: '업체 정보', contextType: 'organization', information }] }), output: [
        { type: 'web_search_call', status: 'completed', action: { type: 'search', query: 'KUKKOLA OY', sources: [source] } },
        ...model({ findings: [{ sourceUrl: source.url, summary: '업체 정보', contextType: 'organization', information }] }).output,
      ] };
      const brief = JSON.parse(body.input[0].content[0].text).writingBrief;
      assert.equal(brief.length, 2); assert.equal(brief[0].sourceUrl, source.url);
      return model(synthesis({ draft: { ...draft, description: '- 핀란드 업체 KUKKOLA OY의 회사명 자수\n- 해당 업체의 업무복으로 사용됐을 가능성이 있습니다.' },
        informationUsage: brief.map((info, i) => ({ informationId: info.id, decision: 'included', reason: '원본 자수와 연결된 정보',
          descriptionExcerpt: i === 0 ? '핀란드 업체 KUKKOLA OY의 회사명 자수' : '해당 업체의 업무복으로 사용됐을 가능성이 있습니다.' })) }));
    },
  });
  assert.equal(trace.informationUsage.filter(i => i.decision === 'included').length, 2);
  assert.match(result.draft.description, /가능성이 있습니다/u);
  assert.ok(!('informationUsage' in result.draft));
});

test('all views and back-print information share the original product group; references stay external', async () => {
  const backId = 'AF03F214-04DE-4B61-B393-AECD12F72830';
  const originals = [...photos, { id: backId, role: 'back', imageDataUrl: image }];
  const information = [{ category: 'marking_meaning', certainty: 'fact', statement: 'HAPPY FOOD HANNAM 음식점 명칭', photoIds: [backId] }];
  const trace = { synthesisAttempts: [] };
  await runWebDetectionAutofill(originals, {
    diagnostics: trace,
    searchPhoto: async () => ({ evidence: [{ ...source, imageUrl: 'https://images.example.com/external.jpg' }], calls: 1 }),
    downloadImage: async () => ({ dataUrl: image, bytes: 68, width: 1, height: 1, mimeType: 'image/png' }),
    requestResponse: async body => {
      const input = JSON.parse(body.input[0].content[0].text);
      if (body.text.format.name === 'garment_web_detection_selection') {
        assert.deepEqual(input.originalProduct.photoIds, ['front', 'label', backId]);
        return model({ ...plan(['front', backId]), observations: [{ photoId: backId, kind: 'graphic', text: 'HAPPY FOOD HANNAM' }] });
      }
      if (body.text.format.name === 'garment_keyword_research') {
        assert.ok(input.originalProduct.photoIds.includes(backId));
        return { ...model({ findings: [{ sourceUrl: source.url, summary: '음식점 정보', contextType: 'organization', information }] }), output: [
          { type: 'web_search_call', status: 'completed', action: { type: 'search', query: 'HAPPY FOOD HANNAM', sources: [source] } },
          ...model({ findings: [{ sourceUrl: source.url, summary: '음식점 정보', contextType: 'organization', information }] }).output,
        ] };
      }
      const brief = input.writingBrief;
      assert.equal(input.originalProduct.sameProduct, true);
      assert.equal(brief[0].productGroupId, input.originalProduct.productGroupId);
      assert.equal(brief[0].appliesTo, 'whole_product');
      const tags = body.input[0].content.filter(c => c.type === 'input_text').slice(1).map(c => JSON.parse(c.text));
      const originalTags = tags.filter(t => t.inputType === 'original_product_photo');
      assert.equal(originalTags.length, 3);
      assert.ok(originalTags.every(t => t.productGroupId === input.originalProduct.productGroupId));
      const external = tags.find(t => t.inputType === 'external_reference_image');
      assert.equal(external.belongsToOriginalProduct, false);
      assert.equal(external.productGroupId, undefined);
      assert.equal(external.originalPhotoId, undefined);
      return model(synthesis({ draft: { ...draft, description: '- 등판에 HAPPY FOOD HANNAM 음식점 명칭이 프린트되어 있습니다.' },
        informationUsage: brief.map(info => ({ informationId: info.id, decision: 'included', reason: '같은 상품의 등판 사진에 연결된 정보', descriptionExcerpt: 'HAPPY FOOD HANNAM 음식점 명칭' })) }));
    },
  });
  assert.ok(trace.informationUsage.every(item => item.productGroupId === 'target-garment'));
  assert.ok(trace.informationUsage.every(item => item.decision === 'included'));
});

test('normal product flow and tester produce the same draft and model inputs for identical photos', async () => {
  const flow = workerHarness(), tester = workerHarness();
  const normalResponse = await flow.run('autofill-web-detection');
  const testResponse = await tester.run('autofill-web-detection-test');
  assert.equal(normalResponse.status, 200); assert.equal(testResponse.status, 200);
  assert.deepEqual(await normalResponse.json(), (await testResponse.json()).draft);
  assert.deepEqual(flow.requests, tester.requests);
});
