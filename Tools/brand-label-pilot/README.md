# 브랜드 라벨 분리 판독 실험

상품 초안 생성과 독립된 프로세스입니다. 같은 옷의 사진 1~5장에서 Luna가 브랜드명을 추측하지 않고 실제 라벨 영역만 찾고, 로컬에서 해당 픽셀을 크롭한 뒤 크롭 사진만 새 요청으로 전달해 원문과 브랜드를 판독합니다. 웹 검색과 상품 설명 생성은 이 실험에 포함되지 않습니다.

1. `POST /v1/garments/brand-label-regions` → 최대 3개 실제 라벨 영역, 좌상단 원점 정규화 좌표
2. Python/Pillow → EXIF 방향을 반영한 입력 사진에서 경계 밖으로 나가지 않게 크롭, 영역별 8% 또는 최소 8픽셀 여백
3. Apple Vision OCR → 가장 큰 브랜드 라벨 크롭 하나를 0~315°까지 45° 간격으로 회전해 원문 판독. 언어 교정·브랜드 사전 없이 얻은 원문을 크롭과 함께 전달
4. `POST /v1/garments/brand-label-readings` → 크롭별 원문·가독성·브랜드. 고확신이며 같은 크롭의 clear 원문과 서로 다른 두 회전 이상의 OCR 원문이 같은 브랜드를 뒷받침할 때만 브랜드 채택
5. 브라우저 → 원본의 크롭 범위, 실제 크롭, 원문, 회전별 OCR, 브랜드, 단계별 소요 시간 표시

라벨 위치를 못 찾으면 두 번째 호출은 하지 않습니다. 가독성이 낮거나 라벨이 충돌하면 null이 정상 결과입니다. 브랜드를 정품 판정으로 취급하지 않습니다. 크롭 원본 ID·좌표는 결과 JSON에 남겨 위치 탐지와 문자 판독의 실패를 구분합니다.

## 실행

macOS의 Swift/Vision, Python 3와 Pillow가 필요합니다. 최초 실행 시 OCR 도구를 임시 디렉터리에 컴파일합니다. 서버 API 두 경로를 먼저 배포해야 합니다. OpenAI 키는 Worker 안에 유지합니다. 로컬 도구는 **빌드된 Dobby 앱**의 Info.plist에서 기존 `InstagramAppAPIKey`를 읽으며 키는 브라우저·결과 JSON·로그에 포함하지 않습니다.

```sh
python3 Tools/brand-label-pilot/server.py \
  --app-plist /path/to/Build/Products/Debug-iphonesimulator/Dobby.app/Info.plist
```

브라우저에서 `http://127.0.0.1:8776/`을 열어 사진을 선택하고 **라벨 분리 판독**을 누릅니다. 파일 선택만으로 과금 호출하지 않습니다. 테스트 한 번에 최대 AI 2회이며 공통 설치별·공유 제한을 따릅니다. 기존 상품/실측 기록을 생성하거나 변경하지 않습니다. 앱의 자동 생성에는 아직 연결하지 않은 독립 실험입니다.

서버는 loopback에만 바인딩하며 동일 출처·세션 nonce를 검증합니다. UI 결과는 메모리에만 유지하며 결과 JSON을 사용자가 내려받을 수 있습니다. 사진/크롭 데이터가 포함되므로 결과를 저장소에 커밋하지 마세요.

저장된 `{photos:[{id,role,imageDataUrl}]}` 요청을 한 번 재현하려면:

```sh
python3 Tools/brand-label-pilot/server.py \
  --app-plist /path/to/Dobby.app/Info.plist \
  --request-json /tmp/photo-request.json --output-dir /tmp/brand-label-result
```

## 검증

```sh
npm --prefix Backend/garment-ai-worker test
python3 -m unittest discover -s Tools/brand-label-pilot -p 'test_*.py'
```

합성 테스트는 인증·호출 상한·좌표 복원·크롭 전달·원문 근거 검증을 확인합니다. 실사진의 정확도 보증은 별도이며, 위치 탐지와 판독 모두 모델 오류가 날 수 있습니다. 이전의 전체 사진 재판독 실패 실험은 운영 자동 생성에 활성화하지 않습니다.


회전 OCR은 목 프린트·직조 라벨을 케어 라벨보다 우선하고 그중 가장 큰 크롭 하나에서 최대 35초 예산으로 처리합니다. 여러 OCR 프로세스의 초기화 경합을 피하기 위한 프로토타입 제한입니다. 시간 초과 시 완료된 회전까지의 원문을 보존하며, OCR 원문을 확보하지 못하면 브랜드 확정을 중단하고 크롭과 실패 사유를 표시합니다. 이 프로토타입은 Mac에서 실행되며 iPhone 앱에 이식한 구현은 아닙니다.

스키마 구성은 [OpenAI Structured Outputs 공식 문서](https://developers.openai.com/api/docs/guides/structured-outputs)를 확인했습니다. 스키마·인증 테스트 통과와 실사진 브랜드 인지 정확도는 별도 검증 항목입니다.

최종 PALACE 4장 시험: 브랜드 PALACE 채택, 총 18.78초(위치 12.74초 / 크롭·OCR 1.41초 / 최종 판독 4.63초). 동일 크롭의 독립 OCR 여러 방향과 최종 clear 원문이 일치했습니다. 이 한 묶음으로 전체 정확도를 판단할 수는 없습니다. 테스트: Worker 514개·로컬 5개 통과.


Dobby 앱에도 대응 네이티브 프로세스를 연결했습니다. 앱의 `ProductAutofillLabelReader.swift`가 iPhone에서 직접 크롭·OCR을 수행하고, `/v1/garments/autofill-labels`에서 브랜드 검증과 상품 정보 생성을 결합합니다. 이 폴더의 도구는 Mac용 독립 비교 실험으로 유지됩니다. 앱 실행에는 이 로컬 서버가 필요하지 않습니다.
