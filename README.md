# dsh-beam — a harness for the BEAM

"모든 것은 플러그인" — 논문(A Programming Paradigm for Spatiotemporal
Composability)의 되돌릴 수 있는 효과 + 반응적 코이펙트 + L-Unload 가드를
Elixir/OTP 위에 재현하는 PoC.

설계와 테스트 목록은 [PLAN.md](PLAN.md), 리뷰 기록과 수정 계획은
[REVIEW.md](REVIEW.md).

## 실행

    mix test

Elixir 1.20.2 / OTP 28(.tool-versions로 asdf 고정).

## 구조

- lib/dsh/context.ex — 통합 컨텍스트(바인딩 + 파이버 + pending-unload 머신)
- lib/dsh/plugin.ex — use DshBeam.Plugin 매크로(활성화/철수/종료 프로토콜)
- lib/dsh/effect.ex · coeffect.ex · fiber.ex — 기판 프리미티브
- lib/dsh/loader.ex · runtime.ex — 선언적 조성 + 증분 재구성
- lib/dsh/session.ex + session/* — 첫 플러그인: append-only 세션 로그
- test/dsh/* — TDD 스위트(논문 보증당 테스트)

## 프로토콜 요약

- 플러그인은 DshBeam.Context.register로 의존(deps)과 제공(provides)을 선언.
- 활성화: {:dsh_activate, view} / 철수: {:dsh_withdraw, keys} -> ack
  {:dsh_deactivated, pid, keys} (또는 :DOWN, 또는 타임아웃).
- 철수는 의존자 전원의 teardown 완료 후에만 바인딩을 제거(L-Unload 가드).
