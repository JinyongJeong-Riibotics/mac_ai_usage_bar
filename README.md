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
- **갱신 주기** — Codex(로컬, 30초~5분) / Claude(3분~30분) 각각 설정.
- **임계값 알림** — 사용률이 임계값(기본 90%)을 넘으면 macOS 알림. 창별로 한 번만 보내고,
  값이 임계값−15% 아래로 내려가면 다시 무장(히스테리시스). *정식 `.app`에서만 동작.*
- **메뉴바 색상 경고** — 임계값 이상이면 메뉴바 숫자를 빨강 + ⚠️, 한 단계 아래는 주황으로 표시.
- **경고 임계값** — 50~95% 슬라이더. 알림·메뉴바 색상·드롭다운 진행바 색이 모두 이 값을 따른다.

## 데이터 소스

- **Codex** — 로컬 세션 로그 `~/.codex/sessions/**/rollout-*.jsonl`. 각 세션의 `token_count`
  이벤트에 `rate_limits`(5h=`window_minutes` 300, 주간=10080, 각 `used_percent`·`resets_at`)가
  기록된다. 네트워크 호출 없음.
  - 주의: Codex CLI는 **현재 binding되는 한도만 primary로** 기록하므로, 주간이 제약일 때
    5h 창이 로그에 없을 수 있다. 그럴 때 5h는 `—`로 표시된다(데이터 부재, 버그 아님).
    최근 세션들을 신선도 순으로 훑어 각 창의 아직 유효한(리셋이 미래인) 최신 샘플을 채운다.
- **Claude** — 인증된 사용량 엔드포인트 `GET https://api.anthropic.com/api/oauth/usage`.
  5h/주간 사용률은 로컬 파일에 없어 이 엔드포인트를 호출한다.
  - Bearer 토큰은 Claude Code가 갱신해 두는 `~/.claude/.credentials.json`에서 **매 호출마다
    새로 읽는다**(항상 최신 토큰 사용, 앱은 토큰을 저장/기록하지 않음).
  - `User-Agent: claude-code/<version>` 헤더가 없으면 공격적으로 429가 나므로 반드시 붙인다.
    폴링은 **3분 이상 간격**(앱 기본 5분)으로 제한한다. Codex(로컬)는 기본 60초.
  - 429가 나면 간격을 2배씩(최대 8배) 자동으로 늘렸다가 성공하면 원복하는 백오프가 있다.
    차단 중에도 마지막 정상값을 지우지 않고 유지하며 경고만 표시한다.

## 갱신 구조 정리

`UsageStore`가 두 소스를 각각의 타이머로 폴링한다. Codex는 반복 타이머, Claude는
매 호출 후 (백오프 반영) 간격으로 재무장하는 단발 타이머다. 설정에서 주기를 바꾸면
Combine 구독을 통해 타이머가 즉시 재스케줄된다.

## 구조

```
Sources/
  UsageCore/          공유 로직 (플랫폼 비의존, GUI 없음)
    Models.swift        RateWindow / ProviderUsage 등 값 타입
    CodexReader.swift   로컬 rollout 로그 파싱
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

### Claude이 "인증 정보 없음"으로 나온다

Claude Code는 macOS에서 OAuth 토큰을 **로그인 키체인**(`Claude Code-credentials`)에
저장하고, 설치에 따라 `~/.claude/.credentials.json`을 남기기도 한다. 앱은 파일을 먼저
보고 없으면 키체인을 읽는다. 키체인을 처음 읽을 때는 **접근 허용 대화상자**가 뜨므로
"항상 허용"을 눌러야 한다. ad-hoc 서명이라 새 버전을 설치하면 앱의 코드 서명이 바뀌어
다시 물어볼 수 있다.

`usage-probe`의 `claude 자격증명:` 줄이 실패 원인을 그대로 알려준다.

### Codex 숫자가 낡았거나 다른 PC와 다르다

Codex는 네트워크가 아니라 **그 PC의 `~/.codex/sessions` 로컬 로그**에서 읽는다. 즉
그 PC에서 Codex를 마지막으로 돌렸을 때의 값이다. 다른 PC와 값이 다르거나 오래된
값이 보이는 건 이 때문이며, 샘플이 1시간 이상 지났으면 메뉴에 기록 시각을 함께 표시한다.
해당 PC에서 Codex를 한 번 돌리면 갱신된다.

### 로컬에서 테스트 돌리기

`xcode-select`가 Command Line Tools를 가리키면 `XCTest`가 없어 `swift test`가 실패한다:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
# 또는 영구 전환: sudo xcode-select -s /Applications/Xcode.app
```

## 개인용

개인 맥 전용. Apple Developer 계정 없이 ad-hoc 서명으로 로컬 빌드해 쓴다.
