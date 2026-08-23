# Elixir Harness PoC — 계획

> 아이디어는 계승, 생태계는 새로 시작. DeepSeek Harness의 "모든 것은 플러그인" 철학 —
> 정확히는 그 이론 기반인 **시공간 합성(spatiotemporal composability)** 패러다임 — 을
> Elixir/OTP 위에 재현하는 PoC. 마일스톤 1은 구현·독립 리뷰·수정 완료(§11).

## 1. 검증할 질문 (단 하나)

Cordis의 정밀 모델 — **되돌릴 수 있는 효과(revertible effect) + 반응적 코이펙트(reactive coeffect)** —
을 OTP의 조악하지만 강한 **프로세스 격리/감독** 위에 구현할 때, 어디가 서로 강화되고 어디가 충돌하는가.

## 2. 이론 배경 (paper.pdf 요약)

"A Programming Paradigm for Spatiotemporal Composability" (Shi, Zhang, Cui; PKU / DeepSeek-AI, 88쪽)는
동적 합성을 두 직교 차원으로 분해한다.

- **시간적 합성(temporal)** — 제거 시 부작용의 완전한 되돌림.
  **되돌릴 수 있는 효과**: 모든 context 변환 Γ→Γ에 역(inverse)을 짝지우고, 런타임이 역을
  LIFO 누산기(accumulator, 비틀린 합성 모노이드 𝔗Γ)로 추적. track/recover.
- **공간적 합성(spatial)** — 의존성의 선언·반응적 관리.
  **반응적 코이펙트**: 컴포넌트가 의존 키 집합 d를 선언하고, context 변경 시 활성화/비활성화/중립으로 통지.
- **통합 context** — 효과 context와 코이펙트 context를 단일 context 타입 Γ로 통합.
- **동적 합성 계산** — 컴포넌트 → 파이버(fiber, 인스턴스). 라이프사이클 Θ = INACTIVE/ACTIVE/RELOADING/UNLOADING.
  규칙: O-Insert/Retire/Remove(오케스트레이션), L-Begin/Iter/Finish(활성화), L-Divert/Raise(조기 종료),
  L-Leave/Unload(비활성화).

계승해야 할 보증(metatheory):

1. **복구 정확성** — 파이버의 누산기를 실행하면 그 파이버의 기여만, 그 외엔 아무것도 제거 안 됨(쌍별 독립 전제).
2. **L-Unload 가드** — 제공자의 철수는 그걸 resolve한 모든 소비자가 비활성화된 뒤에만 실행(의존 방향 정렬, 교착 없음).
3. **합류** — 정지 상태는 최종 구성의 함수일 뿐(재구성 순서 무관).
4. **고장 격리** — 실패는 UNLOADING 경유로 효과를 복구하고 파이버 단위로 기록(형제는 계속 동작).

## 3. OTP 매핑 (본 PoC의 지적 핵심)

| 논문 | Elixir/OTP 재현 |
|---|---|
| 되돌릴 수 있는 효과 Γ→Γ×(Γ→Γ) | 역을 클로저로 반환하는 함수 `{new_state, inverse_fun}` (클로저 1급) |
| LIFO 누산기 | 역 클로저 리스트, teardown 시 역순 적용 |
| 효과 독립성(교환) | 프로세스 격리: 별도 프로세스는 상태 비공유 → 교환 자명. 공유 상태(ETS)는 별도 규율 |
| 코이펙트 선언 d | 플러그인이 선언한 키 리스트; Registry/store에서 resolve |
| 반응 통지 | Registry.register/subscribe + 의존 변경 시 child 재시작 |
| 파이버 라이프사이클 | Context 맵 레코드 3상태(inactive/active/unloading) + pending-unload 머신 — :gen_statem 프로세스 승격은 마일스톤 2 |
| committed view ω | GenServer 상태의 `%{key => pid | module}` |
| L-Unload 가드(¬relied) | 소비자 프로세스 monitor; 전원 비활성화 후 역 실행 |
| O-Insert/Retire/Remove | DynamicSupervisor.start_child/terminate_child/delete_child |
| 재구성 | config entry diff → child start/stop/update |
| HMR(트랜잭션 리로드) | BEAM code server(:code, Code.compile_string) + hot swap — Node보다 네이티브 |
| 샌드박스(실행 경계) | 신뢰 불가 코드를 Port/subprocess(다른 런타임)로 감독 하에 실행 — §6.3이 정확히 이 설계를 요구 |
| 크로스 프로세스 호출 | :erlang.dist + GenServer.call/:rpc — §6.2 |
| 접근 제어(inject=capability) | behaviour + Registry 중재; interception = provider 래핑 |

**중앙 설계 긴장(탐구 대상)**: 논문은 *파이버 내부의 미세 단위 효과 추적*을 모델링하지만,
OTP의 격리/감독 단위는 *프로세스*로 더 거칠다. PoC가 답할 것 — 미세 누산기를 Elixir 클로저로 재현하되,
OTP 감독이 그 위의 조악한 안전망으로 겹치는지, 그리고 그 겹침이 강화인지 충돌인지.

## 4. 기판(substrate) 설계

"모든 것이 플러그인"을 참으로 만드는 메타프레임워크(Cordis core에 해당). 플러그인이 아니라 전제.

- Dsh.Context — 통합 효과/코이펙트 context.
- Dsh.Effect — ctx.effect(fn -> ... {value, inverse} end); 역 누산, LIFO dispose.
- Dsh.Coeffect — 키 선언 d + resolve + 변경 통지.
- Dsh.Fiber — 3상태 맵 레코드; L-Unload 가드는 Context의 pending-unload 머신이 구현(비동기, 의존자 ack/DOWN/타임아웃).
- Dsh.Loader — 선언적 entry 목록(id/url/isolate/config/disabled) + 증분 재구성.

## 5. 마일스톤 1: 첫 플러그인 — Session (append-only 로그)

**선택 근거**: DSH에서 세션 로그는 "단일 진실 원천"이고 모든 것(model-visible ⟺ logged)이 여기서 파생된다.
동시에 이 플러그인 하나가 두 메커니즘을 모두 시연한다.

- **효과**: append 이벤트 (역 = 그 시퀀스 이후 truncate/복원).
- **코이펙트**: projection/소비자가 :session을 선언 → 제공자가 내려가면 소비자가 먼저 비활성화.
- **provider 스왑**: in-memory(ETS) ↔ persisted(파일) 제공자 교체 = 재구성.

## 6. 검증 기준 (마일스톤 1 완료의 정의)

1. 런타임이 정렬된 플러그인 목록에서 부팅.
2. Session 제공자 마운트 → 소비자가 :session resolve → append/read 동작.
3. 제공자 언로드 → 소비자 먼저 비활성화 → 제공자 효과 역순 복구 → context 사전 상태 복귀(복구 정확성).
4. provider 스왑이 소비자만 재활성화(형제는 무영향).
5. mix test로 1–4 자동 검증.

## 7. 논문이 미리 답해주는 어려운 부분

- **샌드박스(§6.3)** — 언어 수준 접근 제어는 악의 코드 앞에서 무력; 실행 경계(별도 런타임/샌드박스 프로세스/컨테이너)가 필요.
  → 신뢰 불가 플러그인은 BEAM 밖 subprocess 런타임으로. (사용자 제안과 일치, 이론 근거 확보)
- **언어 독립성(§6.4)** — 시간 합성은 클로저 + 런타임 모듈 레지스트리, 공간 합성은 typed DI + 동적 중재.
  Elixir: 클로저 ✓, :code 모듈 레지스트리 ✓(Node보다 우월), typed DI는 behaviour+Registry+1.20 타입으로 *부분* 충족(동적 Proxy 부재는 약점).
- **시스템 경계(§6.1)** — 외부 위치(파일 쓰기, 네트워크)에 대한 연산은 idΓ로 취급되어 추적·복구 불가; 복구는 보류(withholding) 또는 보상(compensation).
  → 세션 로그의 영속화는 "경계 밖"이므로 별도 복구 전략 필요.
- **의존 타입/버저닝(§6.6)** — nominal 키 충돌/드리프트. PoC는 namespacing으로 회피, 구조적 호환은 비-목표.

## 8. 비-목표

- TS 하네스의 SDK projection/타입 그래프 재현.
- LLM 어댑터, 에이전트 루프, 툴 파이프라인(후속 마일스톤).
- 제3자 플러그인 생태계 호환.
- Windows 지원.

## 9. 디렉터리

elixir/ (저장소 최상위, python/·native/와 자매) — Mix 프로젝트 dsh.
.tool-versions에 Elixir 1.20.2 / Erlang 28.4.3 고정.

## 10. TDD 테스트 목록 (마일스톤 1 실행 사양)

ExUnit으로 테스트를 먼저 쓰고 구현으로 초록을 만든다. 각 테스트는 논문의 보증 하나를 고정한다.

| 증분 | 테스트 | 고정하는 보증 |
|---|---|---|
| 1. Effect | dispose가 역을 LIFO로 적용 | 복구 순서(§3.1, recoverΓ) |
| 1. Effect | 각 역은 자기 단계만 되돌림 | 역의 합성 |
| 1. Coeffect | 선언 키 전부 제공 시 satisfied | 공간 합성(§3.2) |
| 1. Coeffect | 누락 키 보고 | unsatisfied |
| 1. Coeffect | 뷰는 선언 키만 포함 | committed view |
| 2. Session | Memory: seq 할당·순서 읽기·count | 첫 플러그인 동작 |
| 2. Session | File: 재시작 후에도 지속(JSONL) | 영속 경계(§6.1) |
| 3. Context | unload가 소유자 기여만 복구 | 복구 정확성(Thm 61/62) |
| 3. Context | 키 등장 시 의존자 활성화 | 반응적 코이펙트 |
| 3. Context | 의존자 비활성화가 철수보다 먼저 | L-Unload 가드(Thm 63) |
| 3. Context | teardown 중 committed view 유지 | 가드의 실체 |
| 3. Context | 소유자 사망 시 바인딩 철수 | OTP 안전망 |
| 3. Context | 중복 키 거부 | exclusive binding(§6.2) |
| 4. Runtime | 정렬 조성 부팅·session 사용 | 조성 |
| 4. Runtime | 제공자 제거 시 가드 순서 | 재구성 |
| 4. Runtime | provider 스왑이 의존자만 재활성화 | 스왑 + 합류(Thm 73) |
| 4. Runtime | teardown 중 세션 읽기(probe) | 가드의 실체 |
| M2. DSL | needs/provides 선언이 Spark로 검증·introspect | 논문 Def 44(d, p)의 인코딩 |
| M2. DSL | 조성 DSL(entry)이 마일스톤 1 테스트를 그대로 통과 | Def 74의 인코딩 + 회귀망 |

**마일스톤 2 — Spark DSL 전면.** 논문의 선언들(컴포넌트의 d/p, entry의 id/url/isolate/config/disabled)은 사실상 DSL 문법이다. Spark(Ash 팀, v2.6)의 section/entity/옵션 검증 + introspection으로 `use Dsh.Plugin`(needs/provides)과 `use Dsh.Composition`(entry)을 작성한다. 이점: (1) 선언의 컴파일타임 검증, (2) `Spark.Dsl.Extension` introspection이 cordis_inspect/크리에이터 모드의 기질, (3) entry 스키마 검증이 Loader.diff의 전제. **순서**: 증분 1–4로 런타임 의미론(인터프리터)을 먼저 고정한 뒤 DSL을 얹는다 — DSL의 관측 가능한 동작은 그 의미론뿐이고, 기존 테스트가 회귀망이 된다. 핸드롤 defmacro도 가능하나 검증·introspection 재발명을 피해 유지보수되는 Spark를 쓴다.

주의: Elixir는 미정의 모듈 참조가 테스트 컴파일을 깨므로, 전체 레드 스위트를 한 번에 쓰지 않고 증분(테스트 파일 하나 + 구현)으로 진행한다.

## 11. 진행 상태

- [x] 증분 1–4: 기판 + Session + Runtime — 마일스톤 1 구현 완료
- [x] 독립 리뷰 2건(A: Elixir 공식 문서, B: 정확성·동시성) — REVIEW.md에 병합
- [x] P1 register fiber 병합(H3) / P2 C' 비동기 철수 프로토콜 + use Dsh.Plugin(B-H1/B-H2) / P3 Runtime 실패 보고·재주입(A-H2) / P5 위생
- [x] P4 본 문서를 구현 상태와 정렬(3상태 축소 모델 명시)
- [x] 마일스톤 2-①: 파이버 :gen_statem 4상태 프로세스 승격 — 23 passed
- [x] 마일스톤 2-②: 크래시 경로 committed view(정렬된 shutdown) — 24 passed, 25개 시드 0 실패
- [x] 마일스톤 2-③: 합류 동시성 검증 — 27 passed (경로 무관 정지 상태·동시 reconcile·스왑 중 동시 사용)
- [x] 마일스톤 2-④: Spark DSL 전면 — 30 passed (need/provide 선언, 조성 DSL, 회귀망 27개 유지)

## 13. 마일스톤 3 — 크리에이터 모드 (완료)

Dsh.Creator: 소스 문자열을 Code.compile_string -> BEAM :code 서버로 로드 -> 파이버로 마운트.
redefine은 논문 §5.2.2의 트랜잭션 HMR(컴파일 선행 -> 가드 통과 철수 -> 코드 교체 -> 실패 시 롤백).
테스트 3개(define/redefine/undefine 스토리, mount 크래시 격리, syntax error 무변화) — 33 passed.

## 12. 마일스톤 2 (후보)

- 파이버를 :gen_statem 프로세스로 승격(4상태) — 논문의 "미세 누산기 vs 프로세스 격리" 긴장을 실제로 시연
- 크래시 경로에서도 committed view 보장(정렬된 shutdown: 제공자 자원이 의존자 teardown 동안 생존)
- 합류(재구성 순서 무관)의 동시성 검증
- Spark DSL 전면: use Dsh.Plugin의 needs/provides + 조성 DSL(entry)
