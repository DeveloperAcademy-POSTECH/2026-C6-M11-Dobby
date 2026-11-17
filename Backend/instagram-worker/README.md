# Instagram Worker

| Xcode 빌드 | Worker | 앱 설정 |
| --- | --- | --- |
| Debug | `dobby-instagram-dev` | `INSTAGRAM_DEV_BACKEND_BASE_URL`, `DOBBY_INSTAGRAM_DEV_APP_API_KEY` |
| Release | `dobby-instagram` | `INSTAGRAM_BACKEND_BASE_URL`, `DOBBY_INSTAGRAM_APP_API_KEY` |

## 배포 및 로그 확인

1. 개발 Worker는 실제 값이 설정된 `wrangler.dev.local.toml`을 사용해 `pnpm run deploy:dev`로 배포합니다.
2. 앱의 `Config/DobbySecrets.xcconfig`에는 개발·운영 Worker의 URL과 각 `DOBBY_APP_API_KEY`에 대응하는 앱 키를 설정합니다.
3. 운영 Worker는 기존 `wrangler.local.toml`과 `pnpm run deploy:prod`를 사용합니다.

Debug 업로드 테스트 중 `pnpm run tail:dev`로 개발 Worker 로그를 엽니다. Xcode 콘솔에서 `instagram_upload_timing`을 검색하면 두 로그를 같은 `id`로 비교할 수 있습니다.

## Meta 콜백 설정

Meta 앱의 Instagram 비즈니스 로그인 설정에는 운영 Worker의 다음 주소를 등록합니다.

- 콜백 URL 승인 취소: `https://dobby-instagram.dobbyisvintage.workers.dev/oauth/deauthorize`
- 데이터 삭제 요청 URL: `https://dobby-instagram.dobbyisvintage.workers.dev/oauth/data-deletion`

두 엔드포인트는 Meta가 보내는 `signed_request`를 `INSTAGRAM_APP_SECRET`으로 검증합니다. 데이터 삭제 요청은 연결 토큰과 해당 연결의 게시 요청 기록을 삭제하고, 30일 동안 확인 가능한 상태 URL과 확인 코드를 반환합니다. 게시 과정에서 KV에 올린 임시 이미지는 게시 요청 종료 시 삭제되며 삭제 실패 시에도 기존 1시간 TTL로 만료됩니다.
