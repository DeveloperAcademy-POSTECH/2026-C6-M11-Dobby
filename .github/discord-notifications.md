# Discord 알림 운영

## 브랜치 정책

Git Flow의 개발 통합 브랜치는 `develop`, 릴리스 통합 브랜치는 `main`이다.
PR 리뷰 요청, 머지 준비, 머지 완료 알림은 두 브랜치를 대상으로 한다. 다른 브랜치를
대상으로 하는 PR은 알림에서 제외한다.

`develop` 또는 `main`에 push되거나 PR 리뷰·검사 상태가 바뀌면 열린 PR의 머지 준비
상태를 다시 확인한다. 충돌이 없고 필수 검사와 리뷰 조건을 충족한 PR만 작성자에게
머지 준비 알림을 보낸다.

## 알림과 중복 처리

- 이슈 생성 알림은 `issues.opened` 이벤트에서 한 번 발송하며 GitHub에 발송 기록 댓글을
  남기지 않는다. 실패한 Actions 실행을 수동으로 재실행하면 같은 알림이 다시 발송될 수
  있다.
- PR 리뷰 요청, 머지 준비, 머지 완료 알림은 GitHub Actions 봇 댓글에 내부 마커를
  기록해 같은 상태의 중복 발송을 막는다. 이 댓글은 삭제하지 않는다.
- Draft PR은 리뷰 요청 알림을 보내지 않는다. Draft를 해제하면 리뷰 요청 알림을 보낸다.

## 저장소 설정

다음 Actions Secret이 필요하다.

- `DISCORD_ISSUE_WEBHOOK_URL`: 이슈 알림 채널 Webhook
- `DISCORD_PR_WEBHOOK_URL`: PR 알림 채널 Webhook
- `DISCORD_USER_MAP`: GitHub 로그인과 Discord 사용자 ID의 JSON 대응표

`DISCORD_REVIEWER_LOGINS` Actions Variable로 리뷰 요청 시 멘션할 GitHub 로그인을
쉼표로 구분해 설정할 수 있다. 비어 있으면 스크립트의 기본 리뷰어 목록을 사용한다.
대상 브랜치는 코드에서 `develop`, `main`으로 관리하므로 별도 브랜치 변수는 사용하지
않는다.
