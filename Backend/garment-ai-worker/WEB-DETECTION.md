# Google Web Detection → Luna 상품 정보 생성

브랜치: `codex/web-detection-product-info`.
SerpApi 호출·키·전용 500KB 제한·AI Overview 처리와 `/autofill-lens`를 제거했다.
구글 공식 Cloud Vision API의 `WEB_DETECTION`으로 대체한다. Gemini는 사용하지 않는다.

## 구현 흐름

1. 앱은 같은 상품 사진을 선택 순서대로 최대 5장 전송한다. 기존 JPEG 정규화·메타데이터 제거·사진당 2MiB/총 8MiB 제한을 재사용하며 원본은 보존한다.
2. `POST /v1/garments/autofill-web-detection`에서 기존 앱 인증·크기·사용량 제한을 적용하고 `GOOGLE_VISION_API_KEY` 설정을 확인한다.
3. Luna가 대표 사진과 라벨·자수·그래픽 사진을 최대 2장 고르면서 원본 사진별 브랜드 후보·자수·그래픽·시각 특징을 최대 8개, 서로 보완적인 텍스트 검색어를 최대 3개 추출한다. OCR 크롭이나 OCR 일치 횟수는 검색의 선행 조건이 아니다.
4. 추출한 관찰과 검색어를 Luna의 네이티브 `web_search`로 조사한다. 서버가 검색어별 요청을 각각 병렬 실행하고 요청당 검색 도구 호출은 정확히 1회, 전체 최대 3회이다. 이미지 검색도 함께 병렬 실행한다. 실제 도구 출처와 일치하는 URL의 조사 요약 최대 5개만 최종 입력에 포함한다. Worker가 선택 사진을 병렬로 `https://vision.googleapis.com/v1/images:annotate`에 POST한다. `image.content`는 Base64 이미지이며 `features`에는 `WEB_DETECTION` 하나만 넣는다. 공개 호스팅·Cloud Storage는 필요 없다.
5. `webEntities`, `bestGuessLabels`, `pagesWithMatchingImages`, `fullMatchingImages`, `partialMatchingImages`, `visuallySimilarImages`를 길이·개수 제한과 공개 HTTPS URL 검사 후 정리한다. 키워드는 브랜드 확정 근거가 아니다.
6. Luna에 원본, 검색 키워드, 페이지 제목, 출처 URL, 중복을 제거한 비교 이미지 최대 2장을 전달한다. 외부 이미지는 `comparisonSourceId`, 원본은 `photoId`로 구분한다. Worker가 공개 HTTPS 비교 이미지 후보 최대 4개를 두 장씩 다운로드하고, 검증에 통과한 최대 2장을 Base64 data URL로 전달한다. 이미지 요청에는 API 키·쿠키·인증 헤더를 전달하지 않고 리디렉션을 거절한다. Cloudflare 기본 공개 인터넷 fetch의 비공개 IP 접근 차단을 전제로 하며 private network binding을 사용하면 안 된다. 요청당 6초, 이미지당 2MiB, JPEG·PNG·WebP 헤더/해상도 검사(최대 8192px·1600만 픽셀)를 적용한다. 이는 완전한 이미지 디코딩 검증은 아니며 OpenAI 입력 오류 시 복구가 유지된다.
7. 실제 출처 ID·원본 브랜드 근거 ID·기존 상품 정보 형식을 검증한다. 단순 유사성으로 모델·연식·정품·협업을 확정하지 않고 의류 브랜드와 자수 업체명을 구분하도록 지시한다. 모델의 실제 판단 정확도는 실사진 검증이 필요하다.

**범위:** Web Detection의 페이지 제목·URL은 본문이 아니다. 별도의 네이티브 웹 검색이 검색 도구가 반환한 출처 기반 요약·후보 모델명·식별 특징을 추가한다. 네이티브 검색에서 반환된 상품 후보 최대 2개의 공개 페이지에서 대표 이미지·상품 메타데이터를 제한적으로 추출하며, 모델 요약과 개별 제품의 관계·정확한 연식은 원본과 출처를 통해 별도로 검증해야 한다. Lens나 AI 개요와 동일한 서비스는 아니다.

외부 이미지가 접근 불가해서 OpenAI가 명시적 이미지 입력 오류를 반환한 경우에만 외부 이미지를 뺀 요청으로 한 번 복구하고 검토 메모에 남긴다. 인증·한도·타임아웃·모델 출력 오류는 재시도하지 않는다. 검색 전체 실패는 오류, 일부 실패는 `incomplete`와 확인 메모, 정상 빈 결과는 사진 설명과 미확인 메모로 처리한다.

## Google 설정

1. Google Cloud 프로젝트와 결제 계정을 연결한다.
2. **Cloud Vision API (`vision.googleapis.com`)**를 활성화한다.
3. API 키를 생성하고 API 제한을 **Cloud Vision API**로 설정한다. 서버의 `X-Goog-Api-Key` 헤더로 인증하며 실제 키를 앱·소스·채팅에 넣지 않는다.
4. 로컬에서는 Git에서 제외된 `.dev.vars`의 `GOOGLE_VISION_API_KEY`에 설정한다. 기존 OpenAI·앱/개발 인증 설정도 필요하다.
5. 운영 Worker secret 등록은 저장소 루트에서 다음 명령의 입력 프롬프트를 사용한다.

```sh
cd Backend/garment-ai-worker
npx wrangler secret put GOOGLE_VISION_API_KEY --config wrangler.toml
```

2026-11-12 사용자가 등록한 키를 확인하고 새 경로를 배포했다. 운영본(키 등록 직후 버전 218e187f-5af2-4c60-82f9-f197a5a45600)의 코드를 내려받아 보관된 소스의 번들과 비교했다. 생성된 기본 export 변수 이름을 제외하고 일치했다. 기존 /autofill-research 경로와 완화된 라벨 검증을 로컬 서버 소스에 반영해 보존했다. Dobby 및 Dobby AI Local의 Debug Run 옵션도 활성화했다. 키 등록만으로 코드는 배포되지 않는다.

## 앱 활성화

실제 상품 등록은 Debug·Release 모두 `/autofill-web-detection`을 기본 경로로 사용한다. 설정의 개발 테스터 화면은 제거했다. 제품 입력뷰는 검증한 동일 생성 파이프라인을 계속 사용하며 URL은 `ProductAutofillEndpoints`에서 관리한다. Xcode 실행 환경변수는 필요하지 않으며 앱 아이콘으로 재실행해도 경로가 유지된다. 변경된 앱은 다시 빌드·설치해야 한다. 키가 없으면 설정 오류이며 기존 경로로 몰래 재시도하지 않는다.

## 비용·시간·검증

- 상품당 Web Detection 최대 2장. HTTP 요청 수와 무관하게 이미지별 기능 단위로 과금된다.
- Luna는 분석 1회 + 검색어 수(최대 3회) + 최종 생성 1회로 최대 5회, 명시적 이미지 입력 오류 복구 시 최대 6회. 검색어별 조사 요청은 병렬로 실행한다.
- 기본 종량제 월 최초 1,000단위 무료, 이후 1,000단위당 $3.50. OpenAI·인프라 비용 별도. 아래 공식 가격을 재확인한다.
- 서버 전체 85초, 앱 HTTP 90초, 앱 작업 전체 기존 105초.
- Debug 진단: `Identification`, `Web-Detection`, `Search`, `Synthesis`, `Server` 시간.
- Search-Calls는 정상 응답한 이미지 검색과 실제 키워드 검색 도구 호출의 합계이며 실제 청구 수와 다를 수 있다. 비용 장부가 아니다.
- 서버 로그에 사진·키·원본 응답을 남기지 않는다.

모의 Google/OpenAI 응답, 클라이언트 URLProtocol, iOS 빌드로 검증한다. 실제 CLIQUE 데님 셔츠 전체·라벨·자수 사진으로 서버 호출도 수행했다. Cloudflare의 미지원 `redirect: error` 옵션을 `manual`과 리디렉션 상태 검사로 수정했다. 이후 Google이 HTTP 403 / `BILLING_DISABLED`를 반환해 프로젝트 결제 활성화가 필요함을 확인했다. 검색 결과와 최종 상품 정보의 실사진 품질 평가는 아직 완료되지 않았다.

최신 배포: `b324b9b5-6b5d-428e-88b0-e01a3cdb2cc0`. 백엔드 560개 테스트 통과. 외부 오류 원문 대신 허용된 상태·이유·처리 단계만 `X-Dobby-Vision-Status` / `X-Dobby-Vision-Reason`으로 반환한다. Google의 googleapis.com 오류 메타데이터에서 숫자 형식으로 검증된 consumer 프로젝트만 `X-Dobby-Vision-Project`로 반환한다. 등록된 키의 실제 consumer 번호는 `145901535563`이며 최신 실호출도 `BILLING_DISABLED`를 반환했다. 서비스 계정 프로젝트와 키의 프로젝트가 같은지는 별도 확인이 필요하다. 결제 계정 연결 후 동일 사진 요청을 재실행한다.

공식 문서:
- https://docs.cloud.google.com/vision/docs/detecting-web
- https://docs.cloud.google.com/vision/docs/request
- https://docs.cloud.google.com/docs/authentication/api-keys-use
- https://cloud.google.com/vision/pricing
- https://developers.openai.com/api/docs/guides/images-vision


### 결제 연결 후 실호출 (2026-11-12)

배포 `4a9288f2-c7f1-42b3-a335-d9c4d8514407`에서 CLIQUE 셔츠 원본·라벨·자수 3장으로 요청했다. HTTP 200, 전체 11.6초, 서버 9.253초(사진 선택 3.014초, Web Detection 0.890초, 최종 생성·복구 5.349초), 이미지 검색 2회가 확인됐다. 결제 오류는 해소됐다.

결과 브랜드는 CLIQUE, 상품명은 ‘CLIQUE 블루 데님 긴팔 셔츠’. 외부 비교 이미지 입력이 OpenAI에서 `invalid_value / input`으로 거절되어 한 번의 이미지 제외 복구를 거쳤다. 원본 사진과 키워드·페이지 제목으로 초안은 생성됐지만 사용된 출처는 없었고 연구 상태는 `incomplete`였다. 외부 이미지 비교와 출처 기반 헤리티지/자수 업체 조사 품질은 아직 검증 완료가 아니다. 입력 오류 진단은 허용된 코드·파라미터만 반환하며 원문 메시지·이미지 URL을 노출하지 않는다. 백엔드 561개 테스트 통과.


## 서버 진단 API (이전 설정 테스터 검증 기록)

설정 → 개발 테스트 → Web Detection 테스터에서 사진을 최대 5장 고른 후 실행한다. 사진 선택만으로 API를 호출하지 않는다.

앱의 테스트 화면·전용 클라이언트·전용 UI 테스트는 제거했다. 아래는 서버에 보존된 진단 API와 이전 검증 기록이다.

`POST /v1/garments/autofill-web-detection-test`는 일반 생성과 같은 함수·앱/개발 인증·사용량 제한을 사용한다. 테스트 응답은 `{draft, trace, error, requestId, timings}`이며 일반 생성 응답에는 trace를 추가하지 않는다.

- `selectedPhotoIds`: Google에 실제 보낸 사진 ID. 화면은 업로드 사본의 미리보기와 선택 순서 번호를 보여준다.
- `searches`: 사진별 정규화된 키워드·페이지 제목·출처·비교 이미지 URL 또는 실패 코드. Google 원본 전체 응답이 아니다.
- `comparisonDownloads`: 후보별 다운로드 성공·실패, MIME, 바이트 수, 해상도, SHA-256. 이미지 바이트는 제외한다.
- `synthesisAttempts`: Luna에 실제 전달한 원본 사진 ID·검색 자료·외부 비교 이미지 ID 및 각 시도의 성공/실패. 외부 이미지 제외 복구도 별도로 기록한다.
- `brandPhotoId`, `brandObservedText`, `selectedSourceIds`: 모델의 관찰 근거와 선택 출처. 사실성 보증이 아니다.
- `draft`: 검증된 최종 브랜드·상품명·설명·메모·출처.

중간 실패도 완료된 단계의 trace를 반환한다. 결과 JSON 공유를 지원하며 인증 값이나 Base64 이미지 바이트를 반환하지 않는다. 사진 사본은 테스터 임시 폴더에만 보관하며 화면을 벗어나거나 다시 고르면 제거한다. Release에는 테스트 화면이 없다.

### 비교 이미지 데이터 전달 검증 (2026-11-12)

배포 `5ff895e7-742b-4619-8c4f-bb08562efaf6`부터 비교 이미지를 Worker에서 다운로드하여 data URL로 전달한다. 테스터는 후보별 다운로드 결과와 각 생성 요청의 `comparisonImageTransport: data_url`을 표시한다. 다운로드 성공이 모두 실제 입력을 뜻하지는 않으며 실제 입력 ID는 `synthesisAttempts[].comparisonSourceIds`로 확인한다. 이미지 원문은 trace에 포함하지 않는다.

CLIQUE 원본·라벨·자수 3장으로 실제 요청한 결과 HTTP 200 / 18.4초, 비교 이미지 2장 포함 요청이 첫 시도에 성공했다. 후보 4개 중 1개는 리디렉션으로 거절했고 3개는 다운로드에 성공했으며 그중 2개만 전달했다. 브랜드 `CLIQUE`, 상품명 `CLIQUE 블루 데님 버튼업 셔츠`가 생성됐다. 다만 검색 키워드는 `pocket`이고 설명에 사용할 출처는 선택되지 않았다. 이미지 전달 문제는 해소됐으나 검색 관련성·헤리티지·자수 업체 조사 품질은 개선 과제로 남는다. 모델이 자수 위치를 뒷면이라고 잘못 설명한 점도 있어 최종 설명의 정확성을 보장하지 않는다.

검증: 백엔드 570개 테스트, iOS XCTest 22개·설정 테스터 UI 테스트 1개 통과, 앱 시뮬레이터 빌드와 Worker dry-run 통과.

키워드 검색 추가: 테스터의 `searchPlan`은 원본 관찰·계획 검색어, `keywordSearch`는 실제 도구 검색어·출처 요약·성공/실패를 반환한다. 키워드 검색 실패는 검토 메모와 incomplete로 표시한다. Search-Calls는 이미지 검색 + 실제 텍스트 검색 도구 호출 합계(최대 5), Search-Attempts는 이미지 검색 요청 + 텍스트 조사 요청 수(최대 5)이며 모두 청구 장부가 아니다.

### 원본 관찰 + 검색어별 병렬 조사 검증 (2026-11-12)

최종 배포 `347dce1c-5b92-48d6-859d-c69bf2a0854c`. 초기에 한 조사 요청에 검색어 3개를 넣었을 때 모델이 첫 검색어만 실행했으므로, 서버가 검색어마다 별도 요청을 병렬 실행하도록 수정했다. 각 요청은 네이티브 검색 1회로 제한된다. 테스터 `keywordSearch.attempts`에서 계획된 각 검색어의 성공·실패를 확인할 수 있다. Search 시간은 병렬 OpenAI 조사 요청들의 소요 시간 합계이며 벽시계 전체 시간과 다르다.

같은 CLIQUE 사진 3장으로 최종 실험: HTTP 200, 클라이언트 전체 26.8초, 서버 20.0초. 목 라벨의 CLIQUE와 자수 SISÄRAKENNE KUKKOLA OY를 각각 관찰했고 제품 특징·자수 업체·브랜드 배경 검색어 3개가 실제 각각 실행됐다. 검색 조사 자료 5개를 최종 입력에 포함했고, 비교 이미지 2장을 포함한 첫 생성이 성공했다. 최종 브랜드 CLIQUE, 상품명 ‘CLIQUE 중청 데님 스냅 셔츠 재킷’. 설명에는 자수 문구, 회사의 건축 서비스 관련 검색 정보, Clique의 판촉 의류 배경이 출처 2개와 함께 포함됐다. 공식 유니폼·협업·개별 제품 연식은 미확인으로 구분했다. 한 제품의 성공 사례이며 다른 상품에서도 동일한 판독·검색 정확도를 보장하지 않는다.

검증: 백엔드 577개, iOS XCTest 23개·Swift Testing 11개·UI 1개 통과. 앱 빌드 및 Worker dry-run 통과. 인증 값과 이미지 바이트가 진단 응답에 포함되지 않는 점도 확인했다. 커밋·푸시는 하지 않았다.


### 상품 설명과 모델 식별 보완 (2026-11-12)

설명은 제품 자체의 디자인·그래픽·라벨·확인된 모델명·직접 관련된 배경만 작성한다. 검색 과정, 비교 이미지 해설, 다른 상품과의 차이, 미확인 사유는 reviewNotes로 분리한다. 최초 관찰 텍스트의 오독보다 최종 원본 재판독을 우선하고, 모델명이 실제 프린트 문구와 같아야 한다는 잘못된 기준을 적용하지 않도록 수정했다.

키워드 조사에서 상품 후보는 `productName`, `productFeatures`를 보존하고 전체 자료 상한 안에서 우선한다. 네이티브 도구 출처와 일치하는 후보 최대 2개의 페이지에서 OG/Twitter 대표 이미지·상품 메타데이터를 추출한다. 공개 HTTPS, 기본 Cloudflare public fetch, 인증 미전달, 리디렉션 거절, 요청당 4초, 최대 768KiB HTML prefix만 읽기를 적용하며 스크립트를 실행하지 않는다. 확보한 상품 후보 이미지는 일반 Web Detection 유사 이미지보다 우선 다운로드해 최종 Luna 입력 최대 2장에 포함한다. 페이지·이미지 접근 실패는 `productPages`, `comparisonDownloads`에서 확인한다. 전체 본문 읽기나 후보의 진위 검증을 보장하는 기능은 아니다.

Palace 재현 검증: 이전에 확보한 흰색 그래픽 티셔츠 원본·라벨·확대 사진 4장으로 테스트했다. 첫 재현에서 올바른 Poshmark 상품 사진을 실제 입력했는데도 최초 문자 오독(HEAVEN/SOULS)과 모델명 Save Thyself의 불일치를 이유로 모델명을 제외했다. 다른 실행에서는 문자 오독 HELLSTAR가 검색어까지 오염시켜 올바른 후보를 놓쳤다. 이를 바탕으로 모델명과 인쇄 문구를 구별하고, 장식 문자와 무관한 영어 시각 특징 상품 검색어를 최소 하나 작성하도록 변경했다.

배포 `68fdc2cc-fc64-4ae6-91a5-afb00efb3a84`에서 HTTP 200 / 23.0초에 ‘팰리스 Save Thyself 화이트 그래픽 반팔 티셔츠’가 생성됐다. 사용자 제공 Poshmark URL의 대표 이미지를 확보해 실제 대조 입력으로 사용했고 모델명 근거로 선택했다. 설명은 의류의 색상·형태·그래픽만 포함하고 검색 판단은 reviewNotes에 분리됐다. 단 장식 문구 Souls 오독이 남아, 후속 배포 `1c9cafd0-245d-4902-b806-0de7196c0fa3`에서 고딕체·장식체를 직접 전사하지 않고 시각적 특징으로 표현하도록 보완했다. 해당 티셔츠의 S 라벨과 다른 판매 개체 L 사이즈를 구별하며, 판매자의 SS24 표기는 검토 메모에서 근거 수준을 구분한다.

백엔드 581개, iOS XCTest 23개·Swift Testing 11개·UI 테스트 1개 통과. Worker dry-run 통과. 폰의 현재 진단 폴더에는 11/10 기록만 있어 사용자의 방금 실행한 전체 trace를 직접 확인한 것은 아니며, 위 원인은 확보한 동일 티셔츠 사진으로 재현한 결과다. 커밋·푸시는 하지 않았다.

마지막 장식체 표현 보완 배포의 실사진 재검증도 HTTP 200 / 22.1초에 성공했다. 제품명 ‘Palace Save Thyself 화이트 그래픽 반팔 티셔츠’, 설명은 화이트 크루넥 반팔·붉은 하트 인물 그래픽·고딕 레터링·목 안쪽 Palace 로고로 구성됐다. 오독한 장식 문구의 직접 전사나 검색·비교 과정 설명은 포함되지 않았고, 모델 판단 근거와 시즌 근거의 한계는 reviewNotes로 분리됐다. 사용자 제공 Poshmark 출처 1개가 선택됐다.

### 회사명 자수의 제품 맥락 보존 (2026-11-12)

브랜드와 회사·단체 자수가 함께 있으면 3개 검색 중 상품 시각 특징, 자수 업체 자체, 브랜드+업체 제작/납품 관계에 각각 검색어를 배정한다. 일부만 읽힌 문구는 후보임을 표시해 검색 단서로 보존한다. 회사 자수에는 일반 고딕체 그래픽의 직접 전사 제한을 적용하지 않는다.

키워드 자료에 `contextType`(product/organization/brand_service/brand_history/documented_relationship/other)을 추가했다. 최종 5개 자료 안에서 개별 제작 관계, 업체 정보, 브랜드의 기업복 서비스를 우선 보존해 상품 후보 다수에 밀려 자수 조사가 사라지지 않게 한다. documented_relationship은 네이티브 검색의 실제 출처 URL, 브랜드·조직명과 제작·공급 등의 관계가 들어간 짧은 원문, 원본 관찰의 해당 브랜드·자수 식별자 일치가 필요하다. 이 검사는 모델이 추출한 근거의 일관성 검사이며 외부 사실의 독립적인 진위 보장은 아니다.

설명에는 원본과 일치하는 회사명 자수와 직접 관련 업종을 넣을 수 있다. 원본 라벨·업체 자수 + 업체 정보 + 브랜드 기업복 서비스 근거가 모두 있으면 단체복/업무용 의류로 사용됐을 가능성을 명시적으로 가능성으로 표현할 수 있다. 특정 업체용 제작·납품·공식 유니폼·협업 사실은 별도 직접 관계 근거가 있을 때만 허용한다. 업체가 존재한다는 사실이나 자수 주문 서비스만으로 특정 납품을 만들지 않는다. 검색 과정과 관계 미확인에 대한 보고는 계속 reviewNotes로 분리한다.

배포 `f4184bc5-6894-4312-b8a8-c558f9bc2a25`, 백엔드 583개 테스트·Worker dry-run 통과. 이번 변경은 서버 로직만 수정했다.

CLIQUE/KUKKOLA 실사진 3장으로 검증: HTTP 200 / 28.9초. 상품 특징 검색, ‘Sisärakenne Kukkola Oy’ 검색, ‘CLIQUE Kukkola Oy uniform workwear embroidery’ 관계 검색이 각각 실제 실행됐다. 업체 자료가 최종 입력에 보존됐고 설명에 가슴의 SISÄRAKENNE KUKKOLA OY 흰색 자수와 실내 천장·벽 시공 관련 업체라는 제품 맥락이 포함됐다. 이번 검색에서는 직접 제작·납품 관계나 브랜드 기업복 서비스 근거가 확보되지 않아 공식 단체복·납품 사실 및 그에 근거한 단체복 가능성 문장은 생성하지 않았고, 관계 미확인은 reviewNotes로 분리됐다. 실제 업체·업종의 사실 확인은 반환된 출처를 검토해야 하며 이 기록은 생성 동작 검증이다.

상품 설명에서 목 안쪽·넥/케어 라벨의 브랜드·로고·REG.TRADEMARK·사이즈 표기를 나열하거나 라벨을 확인했다는 문장을 제외하도록 수정했다. 라벨은 계속 내부 식별 근거로 사용하고, 유용한 소재·제조국 등의 제품 사실과 외부 가슴 자수·프린트 설명은 유지한다.

### 검색 정보 → 설명용 정보 전달 및 반영 보고 (2026-11-12)

배포 `87f13365-b985-43c9-aeb4-4154d9fa080c`. 키워드 검색 자료마다 information 최대 2개를 추가한다. 제품 식별(product_identity), 자수·프린트 의미(marking_meaning), 사용 맥락(use_context)을 구분하고 statement·fact/possibility·관련 원본 photoIds를 보존한다. 네이티브 도구 출처 URL을 통과한 기존 검색 자료의 정보만 사용한다. 존재하지 않는 사진 ID, 중복 photoIds, 조직 자료만으로 단정한 use_context fact는 제거한다. 특정 제작·납품은 기존 documented_relationship 검사를 유지한다.

최종 작성 요청에는 출처·사진·정보 ID가 있는 writingBrief 최대 10개를 전달한다. 관련 배경을 사진에서 직접 볼 수 없다는 이유로 배제하지 않고 상품 설명에 활용하도록 변경했다. 회사명 자수와 실제 업체가 일치하면 업무복 가능성을 표현할 수 있으며, 특정 납품 기록은 요구하지 않는다. 명확한 모순·다른 대상·무관함·중복·구체적인 근거 부족은 제외할 수 있다. 이번 변경에서 설명의 기존 '- ' 목록 및 최대 1200자 형식은 유지했다.

모델은 informationUsage에서 정보별 included/omitted 사유와 descriptionExcerpt를 보고한다. 서버는 ID와 중복을 검증하고 included의 발췌가 실제 최종 설명에 존재하는지 확인한다. 보고하지 않은 정보는 not_reported로 표시한다. 이는 모델의 반영 자기보고에 대한 일관성 검사이며, 출처 사실의 정확성이나 발췌의 의미적 일치를 독립적으로 보증하지 않는다. 테스터에서만 trace로 제공하며 일반 상품 등록 응답 형식은 유지한다. Debug 설정 테스터에 ‘검색 정보 → 설명 반영’ 섹션을 추가했다. 이전 서버 trace도 optional 필드로 계속 디코딩한다.

실사진 CLIQUE/KUKKOLA 검증: HTTP 200 / 31.1초, 설명용 정보 5개 중 업체의 지역·업종·명칭 및 업무복 사용 가능성 2개를 반영했다. 일반 기업복 서비스 2개와 다른 브랜드 유사 모델 1개는 구체적인 사유와 함께 제외됐다. 설명에는 가슴 자수의 업체 정보와 업무복 가능성이 자연스럽게 연결되었고, 특정 업체용 제작·납품은 주장하지 않았다. 발췌 2개가 실제 설명에 존재하며 기존 목록 형식을 유지했다. 이 실행의 비교 이미지 다운로드는 실패했지만 출처 기반 업체 정보 전달·활용은 정상 동작했다. 업체 정보의 사실 정확도는 원 출처를 검토해야 한다.

백엔드 587개, iOS XCTest 24개·Swift Testing 11개·설정 테스터 UI 1개 통과. Worker dry-run 통과. 커밋·푸시는 하지 않았다.

### 동일 상품의 원본 뷰 묶음 명시 (2026-11-12)

해피푸드 공유 trace(requestId `48703e9b-3dda-4249-81e9-824c3d45dbc5`)에서 등판 사진 AF03F214-04DE-4B61-B393-AECD12F72830은 실제 originalPhotoIds 안에 있었지만, 최종 모델이 다른 상품의 사진이라고 판단하여 업체 정보와 사용 맥락 3개를 모두 제외했다. 검색·정보 전달은 성공했고 원본 뷰의 상품 소속 해석이 잘못된 사례다.

사진 선택·최종 생성 요청의 첫 텍스트에 originalProduct(productGroupId=target-garment, sameProduct=true, 전체 원본 photoIds·역할)를 추가했다. 각 원본 이미지 바로 앞에도 inputType=original_product_photo와 같은 그룹 ID를 붙인다. 키워드 조사도 관찰된 원본 ID들이 동일 상품에 속함을 전달한다. writingBrief의 검증된 원본 photoIds에는 productGroupId와 appliesTo=whole_product를 붙여 photoIds가 관찰 위치이지 상품별 사용 제한이 아님을 명시한다.

외부 비교 이미지 태그는 inputType=external_reference_image, referenceGroupId=external-references, belongsToOriginalProduct=false로 구분한다. 예전 originalPhotoId 필드는 searchedFromOriginalPhotoId로 바꿔 검색에 사용한 원본 뷰와 외부 상품의 소속을 혼동하지 않게 했다. 다른 photoId라는 이유만으로 원본 등판·소매·확대 정보의 사용을 거부하지 않도록 지시하되, 사실 모순이나 실제 외부 상품 정보를 원본으로 옮기지 않는 기준은 유지한다. 설명 형식·길이와 외부 공개 API는 유지한다.

배포 `42ddf002-b887-49a4-a2d1-8a03f64cc1b1`. 백엔드 588개 및 Worker dry-run 통과. 등판에 연결된 설명용 정보가 원본 전체와 같은 그룹에 속하고, 외부 비교 이미지가 그룹 밖으로 표시되는 회귀 테스트를 추가했다. 앱 코드 변경은 없다.


공유 기록과 ID가 일치하는 해피푸드 원본 3장을 폰의 앱 임시 폴더에서 읽어 실사진 재검증했다(EXIF 방향 반영·2048px JPEG 재인코딩으로 앱 전송 바이트와 완전히 같지는 않음). HTTP 200 / 26.6초. 이전에 전부 제외됐던 등판 기반 음식점 의미·사용 맥락 4개가 모두 included로 보고됐고 발췌가 실제 설명에 존재함을 확인했다. 설명에는 소매 그래픽, 등판의 식당 명칭·주소, Brick Happy Food Hannam의 음식점 정보와 업무복/단체복 사용 가능성이 포함됐다. 브랜드는 제조 브랜드 근거가 없어 null을 유지했다. 외부 바지 사진은 다른 상품으로 구별해 모델 식별에 쓰지 않았다. 특정 제작·납품·공식 협업은 주장하지 않았다. 커밋·푸시는 하지 않았다.
