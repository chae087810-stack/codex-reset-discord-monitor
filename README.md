# Codex 리셋 Discord 감지기

[`willcodexquotareset.com`](https://www.willcodexquotareset.com/)의 공개 API를 확인해 Tibo(`@thsottiaux`)가 **Codex 사용량 리셋 완료 글**을 올렸을 때만 Discord로 보냅니다.

- 사이트 API에서 Tibo 게시물의 분류가 정확히 `reset_completed`인 새 글만 알림
- Tibo 원문, 한글 자동 번역, 게시 시각, 사이트 모델 판정, X 링크 표시
- 예측 점수·확률 상승, `Recent Movement`, 떡밥, 리셋 제안·예정 발표, 쿠폰 알림은 보내지 않음
- 신호 강도가 0이거나 판정 이유가 `무관함`·`리셋 아님`으로 모순되는 글은 보내지 않음

GitHub에서 실행되는 사이트 모니터는 **개인 Codex 계정의 5시간·주간 할당량을 직접 검사하지 않습니다.** 공개 사이트가 Tibo 글을 `reset_completed`로 분류했는지를 감지하는 방식이므로 특정 계정·플랜에 즉시 적용됐다는 보장은 아닙니다.

GitHub Actions가 매시 7·22·37·52분에 실행을 요청합니다. GitHub 예약 실행은 지연되거나 드물게 누락될 수 있으므로 Discord에는 이벤트·게시 시각, 사이트 API 스냅샷 시각, 봇 감지 시각을 따로 표시합니다. 이 사이트·Tibo 감시는 사용자 PC가 꺼져 있어도 동작하며 Windows 예약 작업이나 로컬 PowerShell을 사용하지 않습니다.

[공개 저장소는 60일 동안 저장소 활동이 없으면](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/disable-and-enable-workflows?tool=cli) GitHub가 예약 워크플로를 자동으로 비활성화할 수 있습니다. 두 달 이상 커밋이 없다면 Actions 화면에서 워크플로가 활성 상태인지 확인해야 합니다.

Discord 웹훅 주소는 GitHub Actions의 암호화 Secret `DISCORD_WEBHOOK_URL`에 저장됩니다. `state.json`은 Actions 캐시로 이어받고, 이미 확인한 `reset_completed` 게시물 ID를 기록해 중복 알림을 막습니다. 이전 상태를 v3로 올릴 때는 현재 보이는 과거 완료 글을 모두 읽은 것으로 초기화해 알림 폭탄을 방지합니다.

번역 서비스가 일시적으로 응답하지 않아도 영문 원문과 X 링크는 정상적으로 전송됩니다.

워크플로는 `.github/workflows/monitor.yml`에 있습니다. GitHub의 **Actions > Codex quota reset monitor > Run workflow**에서 `test_latest_log`를 켜고 실행하면 `🧪 형식 확인`이 붙은 최신 Tibo 리셋 완료 알림 예시를 한 번 보냅니다. 테스트 실행은 알림 상태 캐시를 바꾸지 않습니다.

## 실제 계정 할당량·리셋 티켓

`account-monitor.mjs`는 이 PC에 로그인된 공식 Codex app-server에서 실제 계정 값을 읽습니다. 로그인 토큰이나 Discord 웹훅은 PC 밖으로 복사하지 않습니다. Discord 전송만 GitHub Actions의 기존 암호화 Secret을 통해 중계합니다.

- 실제 할당량 사용률과 백엔드의 초 단위 `resetsAt`을 KST로 표시
- 티켓 만료 24시간·12시간·6시간·1시간·30분 전에 각각 한 번 알림
- PC가 꺼져 여러 경고를 놓쳤다면 현재 남은 시간에 가장 가까운 경고 한 건만 전송
- 티켓마다 만료 5분 전에 숨김 준비 작업을 시작하고 정확히 1분 전에 자동사용
- 사용 결과(`reset`, `nothingToReset`, `noCredit`, `alreadyRedeemed`)와 사용 후 실제 할당량을 전송

상주 프로세스는 없습니다. `Codex Quota Ticket Daily Probe` 예약 작업이 매일 오전 9시에 몇 초만 실행되어 새 티켓을 찾고 종료합니다. 티켓이 있으면 경고 시각과 자동사용 시각에 실행되는 일회성 숨김 작업만 등록됩니다. 대기 중인 예약 작업은 추가 CPU·RAM을 사용하지 않습니다. 자동사용 작업만 절전 해제 타이머를 요청하지만, PC가 완전히 꺼져 있거나 Windows·하드웨어에서 깨우기 타이머를 막으면 실행할 수 없습니다.

설치와 제거:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-account-monitor.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall-account-monitor.ps1
```

설치 전에는 `node .\account-monitor.mjs once`로 Discord 발송·예약 등록·티켓 사용 없이 현재 실제 값만 확인할 수 있습니다. 로컬 상태와 로그는 `%LOCALAPPDATA%\CodexQuotaMonitor`에 저장됩니다.
