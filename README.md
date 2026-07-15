# Codex 리셋 Discord 감지기

`willcodexquotareset.com`의 공개 상태 API를 확인해 다음 이벤트를 Discord로 보냅니다.

- 사이트 예측 점수를 실제로 올린 Tibo(`@thsottiaux`) 게시물
- 리셋 예고, vaguepost, 출시·행사·마일스톤 및 신모델 떡밥
- `banked reset` 리셋 쿠폰 게시물
- 해당 게시물의 한글 자동 번역과 원문 링크
- Codex 리셋 쿠폰 지급
- 실제 할당량 리셋
- 리셋 예측 70% 진입

GitHub Actions가 약 30분마다 외부 서버에서 실행합니다. 사용자 PC가 꺼져 있어도 동작하며 Windows 예약 작업이나 로컬 PowerShell을 사용하지 않습니다.

Discord 웹훅 주소는 GitHub Actions의 암호화 Secret `DISCORD_WEBHOOK_URL`에 저장됩니다. `state.json`은 Actions 캐시로 이어받아 이미 보낸 이벤트의 중복 알림을 막습니다.

번역 서비스가 일시적으로 응답하지 않아도 영문 원문 알림은 정상적으로 전송됩니다.
완료된 리셋을 알리는 사후 트윗과 사이트 점수에 반영되지 않은 일반 게시물·잡담·답글은 트윗 알림에서 제외됩니다. 실제 리셋 발생 자체는 사이트의 상태 변화로 별도 알림을 보냅니다.

워크플로는 `.github/workflows/monitor.yml`에 있습니다. 필요할 때 GitHub의 **Actions > Codex quota reset monitor > Run workflow**에서 수동 실행할 수도 있습니다.
