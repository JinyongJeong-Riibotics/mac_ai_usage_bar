# mac_ai_usage_bar

macOS 메뉴바에서 **여러 Codex 계정과 여러 Claude 계정**의 사용률(rate limit)을 보여주는 앱.
각 서비스의 5시간 창 / 주간 창에 대해 **사용률 %** 와 **리셋까지 남은 시간**을 표시한다.

## 표시 항목

| | 5시간 사용률 | 5시간 리셋 | 주간 사용률 | 주간 리셋 | 리셋 티켓 |
|---|---|---|---|---|---|
| Codex | ✅ (활성 제약일 때) | ✅ | ✅ | ✅ | ✅ (상세 화면) |
| Claude | ✅ | ✅ | ✅ | ✅ | — |

메뉴바에는 계정/서비스 이름과 선택한 창의 %를 `Codex 92% · Claude 9% · Claude 2 31%` 형태로 보여주고,
클릭하면 두 서비스의 5h/주간 상세와 리셋 시간이 펼쳐진다. 각 계정의 **Graph**를 누르면
최근 7일의 5시간/주간 사용률을 날짜·시간 축으로 볼 수 있다. Codex 리셋 티켓 잔여 수는
상세 화면에만 표시하며 메뉴바 문자열에는 추가하지 않는다.

정상 조회 결과는 계정별로 `~/Library/Application Support/io.riibotics.MacAIUsageBar/usage-history.json`에
저장한다. 파일에는 시각과 사용률만 기록하며 계정 경로·토큰·자격증명은 포함하지 않는다.
7일이 지난 기록은 다음 주기 조회 또는 그래프 열기 때 자동으로 삭제된다.

## 설정 (Cmd+, 또는 드롭다운 ⚙︎)

- **부팅 시 자동 실행** — `SMAppService` 로그인 항목. `.app` 번들로 실행할 때만 적용된다
  (`swift run`은 번들이 아니라 등록에 실패하고 그 오류를 설정 화면에 표시).
- **Codex 계정** — 계정마다 표시 이름과 별도 `CODEX_HOME`을 저장하고 개별 활성화/비활성화.
  `로그인 명령 복사` 버튼으로 해당 프로필의 로그인 명령을 복사할 수 있다.
- **Claude 계정** — 계정마다 표시 이름과 별도 `CLAUDE_CONFIG_DIR`을 저장하고 개별 활성화/비활성화.
  로그인과 토큰 갱신은 선택한 프로필의 Claude Code CLI에 맡긴다.
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

Codex는 공식 `codex app-server` 프로토콜로 계정 한도를 읽는다. Claude는 계정별
`CLAUDE_CONFIG_DIR`과 그 경로에 대응하는 Claude Code 키체인 항목을 사용한다. 두 서비스 모두
한 Mac에서 여러 계정의 인증과 상태가 서로 섞이지 않게 분리된다.

| | Codex | Claude |
|---|---|---|
| 인증 | 계정별 `$CODEX_HOME/auth.json` | 계정별 `$CLAUDE_CONFIG_DIR/.credentials.json` 또는 프로필별 로그인 키체인 |
| 조회 | `codex app-server` → `account/rateLimits/read` | `GET https://api.anthropic.com/api/oauth/usage` |
| 계정 수 | 여러 계정 | 여러 계정 |
| 토큰 갱신 | Codex CLI/App Server에 위임 | 프로필별 Claude Code CLI에 위임 |
| 최소 주기 | 60초 | 180초 (기본 5분) |

Claude Code는 백그라운드에서 토큰을 갱신하지 않으므로, 토큰 만료 시 앱이 해당 프로필의
`claude -p ok`를 한 번 실행해 Claude Code가 스스로 갱신하게 한다. 앱은 파일과 키체인을
읽기만 하며 refresh token을 복사하거나 직접 회전시키지 않는다. 자동 갱신 프로세스는
safe/restricted 모드, 무도구·무MCP·무세션 상태와 중립 임시 작업 디렉터리에서 실행된다.

- **Codex** App Server 응답의 `rateLimitsByLimitId.codex`에서 `primary` / `secondary` 창을 읽는다.
  프로필은 순차 조회해 여러 계정이 동시에 요청을 몰아 보내지 않으며, 한 계정의 일시적 실패는
  다른 계정이나 마지막 정상값을 지우지 않는다.
- **Claude**는 `User-Agent: claude-code/<version>` 헤더가 없으면 공격적으로 429가 나므로
  반드시 붙인다. 429가 나면 간격을 2배씩(최대 8배) 늘렸다가 성공하면 원복하는 백오프가 있고,
  차단 중에도 마지막 정상값을 지우지 않고 경고만 표시한다.
  - macOS의 Claude Code는 기본적으로 토큰을 **로그인 키체인**에 넣는다. 추가 프로필은
    config 디렉터리 해시에 따라 별도 키체인 항목을 가진다. 앱은 파일이 없으면 Apple 서명
    도구 `/usr/bin/security`를 통해 해당 계정의 키체인 항목을 읽는다. 처음 한 번
    시스템이 접근을 물으면 **"항상 허용"**을 누르면 되고, 이후로는 앱을 업데이트해도
    다시 묻지 않는다(자세한 이유는 "문제 해결" 참고).

## Codex 다계정 설정

1. 기존 `~/.codex` 로그인은 첫 번째 `Codex` 프로필로 자동 등록된다.
2. 설정 → **Codex 계정**에서 `Codex 계정 추가`를 누른다.
3. 표시 이름과 `CODEX_HOME` 경로를 확인하고 `로그인 명령 복사`를 누른다.
4. 복사한 명령을 터미널에서 실행한 뒤, 브라우저에서 모니터링할 ChatGPT 계정으로 로그인한다.
5. 앱에서 새로고침하면 메뉴바와 상세 화면에 해당 계정이 별도 항목으로 나타난다.

각 추가 프로필은 기본적으로 `~/.codex-accounts/account-N`을 사용한다. 다른 PC에서 그 계정을
사용 중이어도, 이 Mac에서 프로필별 로그인을 한 번 해 두면 서버에 기록된 계정 전체 한도를
조회하므로 다른 PC의 사용량도 함께 반영된다. `auth.json`에는 접근 토큰이 있으므로 복사·공유하거나
저장소에 커밋하면 안 된다.

## Claude 다계정 설정

1. 기존 `~/.claude` 로그인은 첫 번째 `Claude` 프로필로 자동 등록된다.
2. 설정 → **Claude 계정**에서 `Claude 계정 추가`를 누른다.
3. 표시 이름과 `CLAUDE_CONFIG_DIR` 경로를 확인하고 `로그인 명령 복사`를 누른다.
4. 복사한 명령을 터미널에서 실행하고 해당 Claude 계정으로 로그인한다.
5. 앱에서 새로고침하면 메뉴바와 상세 화면에 계정별 사용량이 표시된다.

추가 프로필은 기본적으로 `~/.claude-accounts/account-N`을 사용한다. 경로 문자열은 Claude Code의
키체인 항목을 구분하는 기준이므로 로그인 후 임의로 바꾸지 않는 것이 좋다. 앱은 절대경로로
정규화한 동일한 값을 로그인·자동 갱신·키체인 조회에 사용하며, 중복 경로는 조회하지 않는다.

## 갱신 구조 정리

`UsageStore`가 두 소스를 각각의 타이머로 폴링한다. 활성 Codex 및 Claude 프로필은 각각
순차 조회하고, Claude는
매 호출 후 (백오프 반영) 간격으로 재무장하는 단발 타이머다. 설정에서 주기를 바꾸면
Combine 구독을 통해 타이머가 즉시 재스케줄된다.

## 구조

```
Sources/
  UsageCore/          공유 로직 (플랫폼 비의존, GUI 없음)
    Models.swift        RateWindow / ProviderUsage 등 값 타입
    UsageHistory.swift  계정별 7일 사용률 기록·정리·영속화
    CodexReader.swift   계정별 CODEX_HOME + App Server 한도 조회
    ClaudeReader.swift  oauth/usage 라이브 조회
    Formatting.swift    % / 리셋 시간 포매팅
  MacAIUsageBar/      SwiftUI 메뉴바 앱 (MenuBarExtra)
    App.swift           앱 진입점 (Dock 아이콘 없는 accessory 앱)
    AppSettings.swift   설정 상태·Codex/Claude 프로필 (UserDefaults 영속) + 로그인 항목
    UsageStore.swift    계정별 Codex/Claude 상태 + 폴링·백오프
    UsageNotifier.swift 임계값 초과 시 macOS 알림
    Severity.swift      사용률→심각도(정상/주의/경고) 및 색상 매핑
    BarLabelView.swift  메뉴바 라벨 (이름·색상·경고 아이콘)
    MenuContentView.swift  드롭다운 UI
    UsageGraphView.swift   계정별 최근 7일 사용률 그래프
    SettingsView.swift  설정 창
  usage-probe/        터미널에서 값 검증용 CLI
```

## 빌드 / 실행

Swift 6 toolchain 필요 (Xcode 또는 CommandLineTools).
Codex 모니터링에는 `codex app-server`를 지원하는 최신 Codex CLI가 설치되어 있어야 한다.

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

# 특정 Codex 프로필 진단
CODEX_HOME="$HOME/.codex-accounts/account-2" \
  /Applications/MacAIUsageBar.app/Contents/MacOS/usage-probe

# 특정 Claude 프로필 진단
CLAUDE_CONFIG_DIR="$HOME/.claude-accounts/account-2" \
  /Applications/MacAIUsageBar.app/Contents/MacOS/usage-probe
```

### Claude 연결과 키체인 대화상자

각 Claude 계정에서 앱은 파일과 키체인을 모두 보고 **만료가 더 나중인 쪽**을 고른다.

1. `<CLAUDE_CONFIG_DIR>/.credentials.json` — Claude Code가 파일 fallback을 사용한 경우.
2. 파일이 없거나 곧 만료면 `/usr/bin/security`로 해당 프로필의 로그인 키체인을 읽는다.
   기본 `~/.claude`는 기존 `Claude Code-credentials`, 추가 프로필은 config 경로 해시가 붙은
   별도 키체인 항목을 사용한다.

macOS의 Claude Code는 `claude` 실행 시 **키체인**을 갱신한다. 그래서 파일 사본만 읽으면
`claude`를 돌려도 앱은 낡은 파일을 계속 봐서 "만료"로 뜬다 — 신선한 쪽을 고르면 `claude`가
키체인을 갱신하는 즉시 앱이 그 값을 읽는다.

키체인 접근은 macOS가 처음 한 번 묻는다. **"항상 허용"**을 누르면 그 뒤로는 뜨지 않는다.

키체인 항목은 어떤 코드 서명이 접근을 허용받았는지로 보호되는데, macOS는 그 허용을
**요청한 바이너리**에 귀속시킨다. 앱이 직접(in-process) 읽으면 ad-hoc 서명이라 업데이트마다
신원이 바뀌어 매번 다시 묻는다. 그래서 신원이 고정된 Apple 서명 도구 `/usr/bin/security`를
거쳐 읽는다 — "항상 허용" 한 번이 앱 업데이트와 무관하게 영구히 유지된다.

### Music·Documents 같은 폴더 접근을 요청한다

앱의 사용량 조회에는 Music, Documents, Desktop, Downloads 접근이 필요하지 않다. 해당 요청은
허용하지 않아도 된다. `v1.7.1`부터 Claude 자동 갱신은 사용자·프로젝트 설정, 플러그인, hooks,
MCP, 내장 도구, Chrome 연동, 세션 저장을 모두 끄고 실행한다. Claude와 Codex 자식 프로세스의
작업 디렉터리도 시스템 임시 폴더로 고정하며, 부모 앱의 `PWD`, 플러그인 경로, API 키 같은
불필요한 환경변수를 전달하지 않는다.

정상적으로 표시될 수 있는 권한 요청은 macOS 알림과 Claude 키체인 항목의 최초 읽기뿐이다.
불필요한 폴더 권한을 이전 버전에서 허용했다면 시스템 설정 → 개인정보 보호 및 보안 →
파일 및 폴더에서 AI Usage Bar의 해당 권한을 꺼도 된다.

### 인증이 자꾸 만료된다 / 터미널을 켜야만 유지된다

Claude accessToken은 **약 8시간** 만에 만료되는데, **Claude Code는 백그라운드에서
토큰을 자동 갱신하지 않는다**(Claude Code를 실행할 때 갱신). 이 8시간은 서버가 정하는 값이라
앱이 늘릴 수 없다. 앱은 다음 순서로 처리한다:

1. **신선한 쪽 읽기.** 앱은 파일과 키체인 중 만료가 더 나중인 쪽을 쓴다.
2. **프로필별 CLI 자동 갱신**(설정: "터미널 없이 Claude 인증 유지", 기본 켜짐). 토큰이 만료돼
   조회가 실패하면 해당 계정의 `CLAUDE_CONFIG_DIR`로 `claude -p ok`를 실행해 Claude Code가
   스스로 토큰을 갱신하게 한 뒤 다시 읽는다. 이 프로세스에는 파일·명령 도구나 사용자 플러그인을
   제공하지 않으며, 갱신마다 아주 작은 메시지 1개를 소모한다.
   `usage-probe`의 "claude 실행파일" 줄로 앱이 `claude`를 찾는지 확인할 수 있다.

- **앱은 어떤 Claude 자격증명도 쓰거나 복사하지 않는다.** refresh token은 회전식이므로 앱과
  Claude Code가 동시에 갱신하면 재로그인이 필요해질 수 있다. 모든 쓰기와 회전은 선택된 프로필의
  Claude Code CLI만 담당한다.
- 자동 갱신은 계정별 30분 제한이 있어 한 계정의 실패가 다른 계정의 갱신을 막지 않는다.

> 이전 버전(1.3.1)은 키체인을 파일로 자동 복사한 뒤 파일만 읽어서, `claude`를 실행해도
> 앱이 낡은 파일을 계속 보는 버그가 있었다. 현재 멀티 계정 구조에서는 파일 복사를 하지 않는다.

Codex 인증 갱신도 계정별 `CODEX_HOME`에서 실행되는 Codex CLI/App Server가 담당한다.

### "rate limited (429)"이 가끔 뜬다

Claude 사용량 엔드포인트는 짧은 시간에 여러 번 부르면 429를 낸다. 앱은 예약된 주기(기본 5분)와
수동 새로고침만 실제 호출하고, 메뉴를 자주 열거나 절전에서 깨어난 직후의 중복 호출은 60초
간격으로 합쳐 429를 피한다. 429가 나도 마지막 정상값은 지우지 않고 주기를 자동으로 늘렸다가
회복하며, 잠깐 경고만 표시한다.

### Codex 계정에 오류가 표시된다

`CODEX_HOME 폴더 없음`이면 설정의 `로그인 명령 복사`로 만든 명령을 터미널에서 실행한다.
인증 오류이면 같은 명령으로 해당 프로필에 다시 로그인한다. `codex 실행파일을 찾지 못함`이면
Codex CLI를 설치하고 `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` 중 하나에서 실행 가능해야
한다. 일시적 실패 때는 마지막 정상값을 유지하고 계정 아래에 경고만 표시한다.

`v1.6.0`에서 Homebrew Codex를 사용하면 Finder/로그인 항목의 제한된 `PATH` 때문에
`Codex App Server 초기화 시간 초과`가 발생할 수 있었다. `v1.6.1`부터 앱이 Codex 실행 경로를
자식 프로세스의 `PATH`에 자동으로 추가하고, 프로세스가 조기 종료되면 실제 stderr 원인을 표시한다.

### 로컬에서 테스트 돌리기

`xcode-select`가 Command Line Tools를 가리키면 `XCTest`가 없어 `swift test`가 실패한다:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# 또는 영구 전환: sudo xcode-select -s /Applications/Xcode.app
```

## 개인용

개인 맥 전용. Apple Developer 계정 없이 ad-hoc 서명으로 로컬 빌드해 쓴다.
