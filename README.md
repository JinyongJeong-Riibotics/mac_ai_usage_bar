# mac_ai_usage_bar

macOS 메뉴바에서 **Codex**와 **Claude**의 사용률(rate limit)을 보여주는 앱.
각 서비스의 5시간 창 / 주간 창에 대해 **사용률 %** 와 **리셋까지 남은 시간**을 표시한다.

## 표시 항목

| | 5시간 사용률 | 5시간 리셋 | 주간 사용률 | 주간 리셋 |
|---|---|---|---|---|
| Codex | ✅ (활성 제약일 때) | ✅ | ✅ | ✅ |
| Claude | ✅ | ✅ | ✅ | ✅ |

메뉴바에는 각 서비스의 가장 높은(제약이 심한) 창의 %를 요약해 `Cx 92% · Cl 9%` 형태로 보여주고,
클릭하면 두 서비스의 5h/주간 상세와 리셋 시간이 펼쳐진다.

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
    폴링은 **3분 이상 간격**(앱 기본 5분)으로 제한한다. Codex(로컬)는 60초 간격.

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
    UsageStore.swift    두 소스 폴링 + @Published 상태
    MenuContentView.swift  드롭다운 UI
  usage-probe/        터미널에서 값 검증용 CLI
```

## 빌드 / 실행

Swift 6 toolchain 필요 (Xcode 또는 CommandLineTools).

```sh
# 값만 빠르게 확인 (CLI)
swift run usage-probe

# 메뉴바 앱 실행
swift run MacAIUsageBar
```

앱은 Dock 아이콘 없이 메뉴바에만 뜬다. 종료는 드롭다운의 **Quit**.

## 개인용

개인 맥 전용. 코드 서명/공증 없이 로컬 빌드해 사용한다.
자동 실행을 원하면 로그인 항목에 앱 번들을 추가한다(추후 `.app` 패키징 예정).
