# mac_ai_usage_bar

macOS 메뉴바에서 **Codex**와 **Claude**의 사용률(rate limit)을 보여주는 앱.
각 서비스의 5시간 창 / 주간 창에 대해 **사용률 %** 와 **리셋까지 남은 시간**을 표시한다.

## 표시 항목

| | 5시간 사용률 | 5시간 리셋 | 주간 사용률 | 주간 리셋 |
|---|---|---|---|---|
| Codex | ✅ (활성 제약일 때) | ✅ | ✅ | ✅ |
| Claude | ✅ | ✅ | ✅ | ✅ |

메뉴바에는 서비스 이름과 선택한 창의 %를 `Codex 92% · Claude 9%` 형태로 보여주고,
클릭하면 두 서비스의 5h/주간 상세와 리셋 시간이 펼쳐진다.

## 설정 (Cmd+, 또는 드롭다운 ⚙︎)

- **부팅 시 자동 실행** — `SMAppService` 로그인 항목. `.app` 번들로 실행할 때만 적용된다
  (`swift run`은 번들이 아니라 등록에 실패하고 그 오류를 설정 화면에 표시).
- **표시 방식** — 사용량(used) / 남은 량(remaining) 전환. 색상은 항상 "얼마나 소진됐는지"
  기준이라 빨강은 언제나 위험을 뜻한다.
- **메뉴바 기준 창** — 메뉴바 숫자를 5시간 창 기준으로 볼지 주간 창 기준으로 볼지 선택.
  선택한 창이 없으면(예: Codex 5h 부재) 다른 창으로 자동 대체.
- **메뉴바에 표시할 서비스** — Codex / Claude 각각 on/off.
- **갱신 주기** — Codex(1분~5분) / Claude(3분~30분) 각각 설정.
- **임계값 알림** — 사용률이 임계값(기본 90%)을 넘으면 macOS 알림. 창별로 한 번만 보내고,
  값이 임계값−15% 아래로 내려가면 다시 무장(히스테리시스). *정식 `.app`에서만 동작.*
- **메뉴바 색상 경고** — 임계값 이상이면 메뉴바 숫자를 빨강 + ⚠️, 한 단계 아래는 주황으로 표시.
- **경고 임계값** — 50~95% 슬라이더. 알림·메뉴바 색상·드롭다운 진행바 색이 모두 이 값을 따른다.

## 데이터 소스

두 서비스 모두 **각 CLI가 터미널 로그인으로 만들어 둔 평문 인증 파일을 그대로 읽어
실시간 API를 호출**한다. 앱은 자체 로그인 절차가 없고, 키체인도 건드리지 않는다.
토큰은 매 호출마다 파일에서 새로 읽으며 메모리 밖으로 나가지 않는다.

| | Codex | Claude |
|---|---|---|
| 인증 파일 | `~/.codex/auth.json` (0600) | `~/.claude/.credentials.json` (0600) |
| 엔드포인트 | `GET https://chatgpt.com/backend-api/wham/usage` | `GET https://api.anthropic.com/api/oauth/usage` |
| 헤더 | `Authorization: Bearer` + `chatgpt-account-id` | `Authorization: Bearer` + `User-Agent: claude-code/<version>` |
| 토큰 수명 | 약 10일, Codex CLI가 갱신 | accessToken 약 8시간 · refreshToken 약 26일 |
| 토큰 갱신 | Codex CLI에 위임 | **앱이 파일 사본을 직접 갱신** (아래) |
| 최소 주기 | 60초 | 180초 (기본 5분) |

Claude Code는 백그라운드에서 토큰을 갱신하지 않으므로, 앱이 파일 기반 자격증명일 때
만료 임박(또는 401) 시 refreshToken으로 accessToken을 스스로 갱신해 파일에 원자적으로
써넣는다(형식·권한 0600 보존). 키체인 자격증명은 회전 충돌을 피하려 갱신하지 않는다.
자세한 내용은 "문제 해결"의 인증 유지 절 참고.

- **Codex** 응답의 `rate_limit.primary_window` / `secondary_window`를 `limit_window_seconds`로
  구분한다(18000=5h, 604800=주간). Codex는 **현재 binding되는 한도만 primary로** 주므로
  주간이 제약일 때 5h 창이 없을 수 있다. 그럴 때 5h는 `—`로 표시된다(데이터 부재, 버그 아님).
  - 네트워크 실패나 토큰 만료 시에는 로컬 세션 로그
    `~/.codex/sessions/**/rollout-*.jsonl`로 **폴백**하고, 그 값이 언제 기록된 것인지
    함께 표시한다. 폴백 값은 그 PC에서 Codex를 마지막으로 돌린 시점의 것이다.
- **Claude**는 `User-Agent: claude-code/<version>` 헤더가 없으면 공격적으로 429가 나므로
  반드시 붙인다. 429가 나면 간격을 2배씩(최대 8배) 늘렸다가 성공하면 원복하는 백오프가 있고,
  차단 중에도 마지막 정상값을 지우지 않고 경고만 표시한다.
  - macOS의 Claude Code는 기본적으로 토큰을 **로그인 키체인**에 넣는다. 앱은 파일이 없으면
    Apple 서명 도구 `/usr/bin/security`를 통해 그 키체인 항목을 읽는다. 처음 한 번
    시스템이 접근을 물으면 **"항상 허용"**을 누르면 되고, 이후로는 앱을 업데이트해도
    다시 묻지 않는다(자세한 이유는 "문제 해결" 참고).

## 갱신 구조 정리

`UsageStore`가 두 소스를 각각의 타이머로 폴링한다. Codex는 반복 타이머, Claude는
매 호출 후 (백오프 반영) 간격으로 재무장하는 단발 타이머다. 설정에서 주기를 바꾸면
Combine 구독을 통해 타이머가 즉시 재스케줄된다.

## 구조

```
Sources/
  UsageCore/          공유 로직 (플랫폼 비의존, GUI 없음)
    Models.swift        RateWindow / ProviderUsage 등 값 타입
    CodexReader.swift   wham/usage 라이브 조회 (+ 로컬 로그 폴백)
    ClaudeReader.swift  oauth/usage 라이브 조회
    Formatting.swift    % / 리셋 시간 포매팅
  MacAIUsageBar/      SwiftUI 메뉴바 앱 (MenuBarExtra)
    App.swift           앱 진입점 (Dock 아이콘 없는 accessory 앱)
    AppSettings.swift   설정 상태 (UserDefaults 영속) + 로그인 항목
    UsageStore.swift    두 소스 폴링 + @Published 상태 + 백오프
    UsageNotifier.swift 임계값 초과 시 macOS 알림
    Severity.swift      사용률→심각도(정상/주의/경고) 및 색상 매핑
    BarLabelView.swift  메뉴바 라벨 (이름·색상·경고 아이콘)
    MenuContentView.swift  드롭다운 UI
    SettingsView.swift  설정 창
  usage-probe/        터미널에서 값 검증용 CLI
```

## 빌드 / 실행

Swift 6 toolchain 필요 (Xcode 또는 CommandLineTools).

```sh
# 값만 빠르게 확인 (CLI)
swift run usage-probe

# 개발 실행 (알림/로그인 항목은 동작하지 않음 — 번들이 아니라서)
swift run MacAIUsageBar
```

### 배포용 `.app` 만들기 (권장)

```sh
./scripts/build_app.sh      # release 빌드 → dist/MacAIUsageBar.app (ad-hoc 서명)
open dist/MacAIUsageBar.app
```

`.app`은 번들 ID(`io.riibotics.MacAIUsageBar`)를 가지므로 **알림과 "부팅 시 자동 실행"이
정상 동작**한다. `/Applications`로 드래그해 두면 로그인 항목 등록이 안정적이다.
앱 아이콘을 넣으려면 `packaging/AppIcon.icns`를 두고 다시 빌드하면 된다.

앱은 Dock 아이콘 없이 메뉴바에만 뜬다(`LSUIElement`). 종료는 드롭다운의 전원 아이콘.

## CI / 릴리즈

macOS 러너는 비싸므로(러너 분 10배) **패키징은 사람이 릴리즈를 요청할 때만** 돈다.
평소 PR에서는 테스트만 돌고, 설치는 Releases에서 받아서 한다.

| 워크플로 | 트리거 | 하는 일 |
|---|---|---|
| `ci.yml` | PR · master push | `swift build` + `swift test` (캐시로 단축). 문서-only 변경은 스킵 |
| `release.yml` | **수동 실행** · `v*` 태그 push | `.app` 빌드 → zip → **GitHub Release에 첨부**(영구) |

### 릴리즈 만들기 (배포자)

GitHub → **Actions → Release → Run workflow** → 버전(예: `0.2.0`) 입력 → 실행.

그러면 현재 커밋에 `v0.2.0` 태그를 만들고, `.app`을 빌드해
`MacAIUsageBar-0.2.0.zip`을 릴리즈에 첨부한다. 릴리즈 노트에는 설치 안내와
자동 생성된 변경 내역이 함께 들어간다. 같은 버전이 이미 있으면 빌드 전에 실패한다.

터미널에서 태그를 직접 밀어도 동일하게 동작한다:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

### 설치하기 (사용자)

1. [Releases](../../releases)에서 `MacAIUsageBar-<버전>.zip` 다운로드 → 압축 해제 →
   `MacAIUsageBar.app`을 `/Applications`로 이동.
2. Gatekeeper 해제 — 터미널에서:
   ```sh
   xattr -dr com.apple.quarantine /Applications/MacAIUsageBar.app
   ```
3. 메뉴바에만 뜬다(Dock 아이콘 없음). 종료는 드롭다운의 전원 아이콘.

Apple Silicon(arm64) 전용이다. Intel Mac용이 필요하면 `build_app.sh`의 `swift build`에
`--arch arm64 --arch x86_64`를 넘겨 유니버설 바이너리로 만들면 된다.

#### "Apple은 악성 코드가 없음을 확인할 수 없습니다" 경고

Apple Developer 계정($99/년) 없이 ad-hoc 서명만 했기 때문에 **공증(notarization)이 없어서**
나는 경고다. 앱이 손상된 것도, 빌드가 잘못된 것도 아니다. 브라우저로 zip을 받으면
`com.apple.quarantine` 속성이 붙고 그 상태로 열면 차단된다.

해제 방법:

| 방법 | 절차 |
|---|---|
| 터미널 (권장) | `xattr -dr com.apple.quarantine /Applications/MacAIUsageBar.app` |
| GUI | 앱을 한 번 실행해 경고를 띄운 뒤 → 시스템 설정 → 개인정보 보호 및 보안 → 아래로 스크롤 → **"확인 없이 열기"** |

**macOS 15(Sequoia)부터는 Finder에서 우클릭 → 열기로 우회되지 않는다.** 위 두 방법만 유효하다.

근본 해결은 Apple Developer Program에 가입해 Developer ID 서명 + 공증을 붙이는 것인데,
개인용이라 하지 않고 있다. 현재 상태는 `spctl -a -t exec <앱>`으로 확인하면 `rejected`로 나온다.

## 문제 해결

앱이 무엇을 읽고 있는지 그대로 출력하는 진단 CLI가 번들 안에 함께 들어 있다.
(토큰 값은 출력하지 않는다.)

```sh
/Applications/MacAIUsageBar.app/Contents/MacOS/usage-probe
```

### Claude 연결과 키체인 대화상자

앱은 Claude 토큰을 이 순서로 찾는다:

1. `~/.claude/.credentials.json` (있으면 그대로 사용, 대화상자 없음)
2. 없으면 `/usr/bin/security`로 **로그인 키체인**의 `Claude Code-credentials` 항목을 읽고,
   **읽은 값을 곧바로 1번 파일로 저장한다**(0600). 즉 수동으로 `security … > …` 하던 일을
   앱이 대신 한다. 이후로는 항상 1번 경로만 타므로 키체인은 딱 한 번만 건드린다.

2번에서 macOS가 처음 한 번 접근을 묻는다. **"항상 허용"**을 누르면 그 뒤로는 뜨지 않는다.
(파일이 만들어졌으니 다시 물을 일도 없다.)

키체인 항목은 어떤 코드 서명이 접근을 허용받았는지로 보호되는데, macOS는 그 허용을
**요청한 바이너리**에 귀속시킨다. 앱이 직접(in-process) 읽으면 ad-hoc 서명이라 업데이트마다
신원이 바뀌어 매번 다시 묻는다. 그래서 신원이 고정된 Apple 서명 도구 `/usr/bin/security`를
거쳐 읽는다 — "항상 허용" 한 번이 앱 업데이트와 무관하게 영구히 유지된다.

> 수동으로 미리 파일을 만들고 싶으면 아래도 여전히 유효하지만, 이제는 필수가 아니다:
> ```sh
> security find-generic-password -s "Claude Code-credentials" -w > ~/.claude/.credentials.json
> chmod 600 ~/.claude/.credentials.json
> ```

### 인증이 자꾸 만료된다 / 터미널을 켜야만 유지된다

Claude accessToken은 **약 8시간** 만에 만료되는데, **Claude Code는 백그라운드에서 토큰을
자동 갱신하지 않는다**(터미널에서 `claude`를 실행할 때만 갱신). 그래서 앱만 켜두면 8시간 뒤
인증이 끊긴다.

그래서 이 앱은 **자격증명이 `~/.claude/.credentials.json` 파일에 있을 때** refreshToken으로
accessToken을 스스로 갱신한다(`api.anthropic.com/v1/oauth/token`). refreshToken은 약 26일
유효하므로, 그 안에 앱이 한 번이라도 돌면 무기한 유지된다 — 터미널을 켤 필요가 없다.

- **키체인 자격증명은 앱이 갱신하지 않는다.** refreshToken은 회전(rotating)식이라, 앱이
  키체인 토큰을 갱신하면 Claude Code 자신의 refreshToken이 무효화돼 다음 `claude` 실행 때
  재로그인을 요구할 수 있다. 그 충돌을 피하려고 파일 사본만 갱신한다.
- **키체인만 있는 맥도 이제 자동으로 커버된다.** 앱이 키체인을 처음 읽을 때 그 값을 파일로
  저장하므로("키체인 대화상자" 절 참고), 그 뒤로는 파일 기반이 되어 앱이 알아서 갱신한다.
  사용자가 할 일은 첫 실행 시 뜨는 키체인 대화상자에서 **"항상 허용"**을 누르는 것뿐이다.

Codex 토큰은 약 10일이고 Codex CLI가 갱신한다. 만료되면 그 PC에서 `codex`를 한 번 실행.
`usage-probe`가 두 토큰의 남은 수명을 보여준다.

### "rate limited (429)"이 가끔 뜬다

Claude 사용량 엔드포인트는 짧은 시간에 여러 번 부르면 429를 낸다. 앱은 예약된 주기(기본 5분)와
수동 새로고침만 실제 호출하고, 메뉴를 자주 열거나 절전에서 깨어난 직후의 중복 호출은 60초
간격으로 합쳐 429를 피한다. 429가 나도 마지막 정상값은 지우지 않고 주기를 자동으로 늘렸다가
회복하며, 잠깐 경고만 표시한다.

### Codex 숫자가 낡았다고 표시된다

라이브 조회가 실패하면(오프라인·토큰 만료) 그 PC의 로컬 세션 로그로 폴백하고, 값 아래에
언제 기록된 것인지 표시한다. 그 PC에서 Codex를 한 번 돌리거나 네트워크를 복구하면 된다.

### 로컬에서 테스트 돌리기

`xcode-select`가 Command Line Tools를 가리키면 `XCTest`가 없어 `swift test`가 실패한다:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# 또는 영구 전환: sudo xcode-select -s /Applications/Xcode.app
```

## 개인용

개인 맥 전용. Apple Developer 계정 없이 ad-hoc 서명으로 로컬 빌드해 쓴다.
