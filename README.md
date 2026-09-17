# mac_ai_usage_bar

macOS 메뉴바에서 **여러 Codex 계정**과 **Claude 한 계정**의 사용률(rate limit)을 보여주는 앱.
각 서비스의 5시간 창 / 주간 창에 대해 **사용률 %** 와 **리셋까지 남은 시간**을 표시한다.

## 표시 항목

| | 5시간 사용률 | 5시간 리셋 | 주간 사용률 | 주간 리셋 |
|---|---|---|---|---|
| Codex | ✅ (활성 제약일 때) | ✅ | ✅ | ✅ |
| Claude | ✅ | ✅ | ✅ | ✅ |

메뉴바에는 계정/서비스 이름과 선택한 창의 %를 `Codex 92% · Codex 2 31% · Claude 9%` 형태로 보여주고,
클릭하면 두 서비스의 5h/주간 상세와 리셋 시간이 펼쳐진다.

## 설정 (Cmd+, 또는 드롭다운 ⚙︎)

- **부팅 시 자동 실행** — `SMAppService` 로그인 항목. `.app` 번들로 실행할 때만 적용된다
  (`swift run`은 번들이 아니라 등록에 실패하고 그 오류를 설정 화면에 표시).
- **Codex 계정** — 계정마다 표시 이름과 별도 `CODEX_HOME`을 저장하고 개별 활성화/비활성화.
  `로그인 명령 복사` 버튼으로 해당 프로필의 로그인 명령을 복사할 수 있다.
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

Codex는 공식 `codex app-server` 프로토콜로 계정 한도를 읽는다. 계정별로 서로 다른
`CODEX_HOME`을 넘기고 파일 기반 인증 저장소를 강제하므로, 한 Mac에서도 여러 ChatGPT 계정의
인증과 설정이 섞이지 않는다. Claude는 기존처럼 Claude Code 자격증명으로 한 계정만 조회한다.

| | Codex | Claude |
|---|---|---|
| 인증 | 계정별 `$CODEX_HOME/auth.json` | `~/.claude/.credentials.json` 또는 로그인 키체인 |
| 조회 | `codex app-server` → `account/rateLimits/read` | `GET https://api.anthropic.com/api/oauth/usage` |
| 계정 수 | 여러 계정 | 한 계정 |
| 토큰 갱신 | Codex CLI/App Server에 위임 | **앱이 파일 사본을 직접 갱신** (아래) |
| 최소 주기 | 60초 | 180초 (기본 5분) |

Claude Code는 백그라운드에서 토큰을 갱신하지 않으므로, 앱이 파일 기반 자격증명일 때
만료 임박(또는 401) 시 refreshToken으로 accessToken을 스스로 갱신해 파일에 원자적으로
써넣는다(형식·권한 0600 보존). 키체인 자격증명은 회전 충돌을 피하려 갱신하지 않는다.
자세한 내용은 "문제 해결"의 인증 유지 절 참고.

- **Codex** App Server 응답의 `rateLimitsByLimitId.codex`에서 `primary` / `secondary` 창을 읽는다.
  프로필은 순차 조회해 여러 계정이 동시에 요청을 몰아 보내지 않으며, 한 계정의 일시적 실패는
  다른 계정이나 마지막 정상값을 지우지 않는다.
- **Claude**는 `User-Agent: claude-code/<version>` 헤더가 없으면 공격적으로 429가 나므로
  반드시 붙인다. 429가 나면 간격을 2배씩(최대 8배) 늘렸다가 성공하면 원복하는 백오프가 있고,
  차단 중에도 마지막 정상값을 지우지 않고 경고만 표시한다.
  - macOS의 Claude Code는 기본적으로 토큰을 **로그인 키체인**에 넣는다. 앱은 파일이 없으면
    Apple 서명 도구 `/usr/bin/security`를 통해 그 키체인 항목을 읽는다. 처음 한 번
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

## 갱신 구조 정리

`UsageStore`가 두 소스를 각각의 타이머로 폴링한다. 활성 Codex 프로필은 같은 반복 타이머에서
순차 조회하고, Claude는
매 호출 후 (백오프 반영) 간격으로 재무장하는 단발 타이머다. 설정에서 주기를 바꾸면
Combine 구독을 통해 타이머가 즉시 재스케줄된다.

## 구조

```
Sources/
  UsageCore/          공유 로직 (플랫폼 비의존, GUI 없음)
    Models.swift        RateWindow / ProviderUsage 등 값 타입
    CodexReader.swift   계정별 CODEX_HOME + App Server 한도 조회
    ClaudeReader.swift  oauth/usage 라이브 조회
    Formatting.swift    % / 리셋 시간 포매팅
  MacAIUsageBar/      SwiftUI 메뉴바 앱 (MenuBarExtra)
    App.swift           앱 진입점 (Dock 아이콘 없는 accessory 앱)
    AppSettings.swift   설정 상태·Codex 프로필 (UserDefaults 영속) + 로그인 항목
    UsageStore.swift    계정별 Codex 상태 + Claude 폴링·백오프
    UsageNotifier.swift 임계값 초과 시 macOS 알림
    Severity.swift      사용률→심각도(정상/주의/경고) 및 색상 매핑
    BarLabelView.swift  메뉴바 라벨 (이름·색상·경고 아이콘)
    MenuContentView.swift  드롭다운 UI
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
```

### Claude 연결과 키체인 대화상자

앱은 Claude 토큰을 이 순서로 찾는다:

앱은 파일과 키체인을 모두 보고 **만료가 더 나중인(더 신선한) 쪽을 매번 고른다.**

1. `~/.claude/.credentials.json` — 파일이 신선하면 이걸 쓴다(대화상자 없음).
2. 파일이 없거나 곧 만료면 `/usr/bin/security`로 **로그인 키체인**의 `Claude Code-credentials`을
   읽어 비교하고, 더 신선한 쪽을 쓴다.

macOS의 Claude Code는 `claude` 실행 시 **키체인**을 갱신한다. 그래서 파일 사본만 읽으면
`claude`를 돌려도 앱은 낡은 파일을 계속 봐서 "만료"로 뜬다 — 신선한 쪽을 고르면 `claude`가
키체인을 갱신하는 즉시 앱이 그 값을 읽는다.

키체인 접근은 macOS가 처음 한 번 묻는다. **"항상 허용"**을 누르면 그 뒤로는 뜨지 않는다.

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

Claude accessToken은 **약 8시간** 만에 만료되는데, **Claude Code는 백그라운드에서
토큰을 자동 갱신하지 않는다**(터미널에서 `claude`를 실행할 때만 갱신). 이 8시간은 서버가 정하는
값이라 앱이 못 늘린다. 그래서 앱은 세 방향으로 이를 버틴다:

1. **신선한 쪽 읽기.** 앱은 파일과 키체인 중 만료가 더 나중인 쪽을 쓴다.
   `claude`를 한 번이라도 실행하면 키체인이 갱신되고, 앱이 그 즉시 그 값을 읽는다.
2. **파일 자동 갱신.** 자격증명이 파일에 있으면 앱이 refreshToken으로 accessToken을 직접
   갱신한다(`api.anthropic.com/v1/oauth/token`).
3. **CLI 자동 갱신 (설정: "터미널 없이 Claude 인증 유지", 기본 켜짐).** 토큰이 만료돼 조회가
   실패하고 파일 갱신도 불가능할 때(키체인 기반 맥), 앱이 `claude -p`를 잠깐 실행해 **Claude
   Code가 스스로 토큰을 갱신**하게 한 뒤 다시 읽는다. 키체인을 직접 건드리지 않아 안전하며,
   갱신마다 아주 작은 메시지 1개를 소모한다(~8시간마다). 터미널을 아예 안 켜도 유지된다.
   `usage-probe`의 "claude 실행파일" 줄로 앱이 `claude`를 찾는지 확인할 수 있다.

- **키체인 토큰은 앱이 갱신하지 않는다.** refreshToken은 회전식이라 앱이 키체인 토큰을
  갱신하면 Claude Code 자신의 refreshToken이 무효화돼 다음 `claude` 실행 때 재로그인을 요구할
  수 있다. 그래서 자기 파일 사본만 갱신하고, 키체인은 읽기만 한다.
- 따라서 **키체인만 있는 맥에서 터미널을 아예 안 켜고 유지**하려면, "키체인 대화상자" 절의
  일회성 명령으로 파일을 한 번 만들면 그 뒤로는 앱이 파일을 자동 갱신한다. 파일을 안 만들면
  `claude`를 이따금 실행하는 것만으로도(키체인 갱신 → 앱이 읽음) 유지된다.

> 이전 버전(1.3.1)은 키체인을 파일로 자동 복사한 뒤 파일만 읽어서, `claude`를 실행해도
> 앱이 낡은 파일을 계속 보는 버그가 있었다. 지금은 "신선한 쪽"을 고르므로 해결됐다.

Codex 인증 갱신은 계정별 `CODEX_HOME`에서 실행되는 Codex CLI/App Server가 담당한다. 앱은 토큰을
직접 해석하거나 별도 인증 엔드포인트로 보내지 않는다.

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
