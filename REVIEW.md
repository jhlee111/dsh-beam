# 코드 리뷰 기록 (마일스톤 1)

두 독립 리뷰어(A: Elixir 공식 문서 기준, B: 정확성·동시성)의 병합 기록.
리뷰는 코드 수정 없이 실행된 검증 3종 위에 수행됨.

## 검증 기준선

- mix format --check-formatted → 통과
- mix compile --warnings-as-errors → 통과 (경고 0)
- mix test → 15 passed

## 리뷰어 A — Elixir best practice / 공식 문서 안티패턴

### [높음] H1 — GenServer 재진입/교착 + 활성·비활성 비대칭 (Dsh.Context)

- 파일: lib/dsh/context.ex — reactivate/2 (246–273), do_unload/2 (277–290), deactivate_dependents/2 (297–310)
- 문제: unload의 handle_call 처리 중 소비자에게 동기 GenServer.call({:dsh_deactivate, ...}) → 소비자가
  Context로 콜백하면 상호 대기 교착. 반면 활성화는 send({:dsh_activate, ...}) 비동기 + 확인 없이 :active 표시.
  활성=비동기·비확인 / 비활성=동기·블록킹의 비대칭.
- 근거: hexdocs GenServer(재진입 주의), process-anti-patterns "Non-atomic operations"
- 제안: 비활성화를 2-Phase(메시지 + ack 수집)로, 또는 활성/비활성을 동일한 비동기 규약으로 통일.

### [높음] H2 — 감독이 desired state를 유지하지 않음 → 수렴 실패 (Dsh.Runtime)

- 파일: lib/dsh/runtime.ex — start_entry/2 (79–98), stop_entry/2 (100–118), handle_info DOWN (56–59)
- 문제: restart: :temporary + 시작 실패를 pid: nil로 기록하고 Logger.warning만 → 이후 같은 entry를
  다시 요청해도 Loader.diff가 "같음"으로 보고 재시도하지 않음(영구 부재). 크래시 시 DOWN 핸들러는
  entry 삭제만. 원하는 조성과 실제가 어긋나도 :ok 보고.
- 근거: process-anti-patterns "Unsupervised processes", hexdocs DynamicSupervisor/Supervisor
- 제안: 실패를 loud하게(:error 반환) 하거나 재시도/재주입으로 수렴 보장.

### [중간] M1 — @behaviour Dsh.Session 콜백이 사코드 + 이중 경로

- 파일: lib/dsh/session.ex 25–29, memory.ex 15–21, file.ex 16–22
- 문제: seam(Dsh.Session.append/all/count)은 GenServer.call 메시지 dispatch인데 provider의
  @behaviour 구현 append/all/count는 어디서도 호출 안 됨(grep 0회) → 죽은 코드 + 이중 경로.
- 근거: code-anti-patterns "Keeping dead code" / "Accidental double calls"
- 제안: behaviour 콜백을 실제 dispatch 경로로 사용하거나(seam이 provider 함수 호출), 콜백을 버리고
  메시지 프로토콜 계약으로만 선언.

### [중간] M2 — 고정 이름 ETS + :public

- 파일: lib/dsh/session/memory.ex 25
- 문제: :ets.new(:dsh_session_memory, [:ordered_set, :public]) → 두 Memory provider 동시 존재 시
  badarg 충돌. 현재 테스트는 위상(비동기 격리·링크 정리) 덕에 우연히 통과.
- 근거: hexdocs :ets (이름 유일성/소유권/접근권)
- 제안: 익명 테이블(:protected)로 바꾸고 소유자 state가 tid 보관.

### [중간] M3 — terminate에서 catch :exit로 unload (예외를 제어 흐름으로)

- 파일: lib/dsh/provider.ex 42–50, consumer.ex 63–71, session/plugin.ex 39–50
- 문제: terminate/2는 :kill 시 미호출이며, shutdown cascade 중 동기 GenServer.call은 취약.
  catch :exit, _ -> :ok가 사유를 삼킴. 동일 로직 3중 복붙.
- 근거: code-anti-patterns "Using exceptions for control flow", hexdocs GenServer(terminate 제약)
- 제안: monitor 안전망(owner death → do_unload)에 일임하고 terminate unload 제거, 또는 공용 헬퍼 추출.

### [중간] M4 — "durable" 주장 vs fsync 없음·append마다 open/close·O(n)

- 파일: lib/dsh/session/file.ex (moduledoc 2–6, append 40–44, all 47–50, count 53–55)
- 문제: durable이라 선언했지만 :sync/fsync 없음(OS 버퍼). 매 append open/close, all/count는 전체 재스트리밍.
- 근거: writing-documentation, code-anti-patterns "Comments over use" / "Speculative assumptions"
- 제안: fsync 정책 명시하거나 표현을 정확히("fsync 전까지 OS 캐시"), 커서/카운터 도입.

### [중간] M5 — PLAN이 약속한 :gen_statem 4상태 파이버 미실현

- 파일: PLAN.md §3/§4 vs lib/dsh/fiber.ex 10–11(2상태), context.ex(맵 레코드)
- 문제: 파이버가 독립 프로세스가 아니고 조정 상태가 단일 Context GenServer에 집중 →
  "파이버 단위 미세 누산기 vs 프로세스 격리"라는 논문의 중앙 긴장이 실제로 시연되지 않음.
- 근거: code-anti-patterns "Comments over use", hexdocs :gen_statem
- 제안: (a) 파이버를 실제 :gen_statem/감독 프로세스로 승격, 또는 (b) 문서를 "2상태 맵 레코드 축소 모델"로 정정.

### [중간] M6 — check-then-act 비원자성, 대상 소멸 시 Context 크래시

- 파일: lib/dsh/context.ex 300–302
- 문제: dep.state 검사 후 GenServer.call 사이 대상이 죽으면 call이 exit → Context 전체 사망(트랩 없음).
- 근거: process-anti-patterns "Non-atomic operations"
- 제안: call을 catch하거나 monitor 기반 정리로 교체, 비활성화를 비동기화.

### [낮음] L1–L5

- L1 context.ex — 실패 표현 불일치(:error / {:unknown, %{}} / :unknown) → 하나로 통일.
- L2 context.ex 217–230 — put_monitor O(n) 스캔 → %{pid => ref} 역인덱스.
- L3 loader.ex 29–43 — 키워드 순서 민감 비교(스퓨리어스 restart) → Map.new 정규화. DynamicSupervisor strategy 명시 불필요.
- L4 테스트 — wait_until 폴링·고정 타임아웃·링크 정리 의존 → start_supervised!/on_exit 명시 정리.
- L5 README 기본 템플릿("TODO: Add description") + erl_crash.dump 잔재.

## 리뷰어 A 총평

논문의 기질(복구 정확성·committed view·L-Unload 가드·monitor 안전망)은 테스트 15개로 잘 고정됨.
그러나 조정을 단일 Dsh.Context에 몰고 파이버를 독립 프로세스로 만들지 않아 논문의 핵심 보증
(교환성·고장 격리)이 실제로는 우회됐으며, 코디네이터 재진입/비원자성과 :temporary 감독의 수렴
실패가 관용구를 벗어난 주 지점. 다음 마일스톤에서 파이버를 프로세스로 승격하거나 문서를 축소
모델로 정정하고 H1·H2를 먼저 해소할 것.

## 리뷰어 B — 정확성·동시성 (보고 대기 중)

## 리뷰어 B — 정확성·동시성·자원 관리

검증: mix test 15 passed, mix compile --warnings-as-errors 통과. 3건 실측 재현(소스 미수정).

### [높음] H1 — 비계약 의존자가 Context 전체를 크래시

- context.ex:302의 동기 GenServer.call — deps만 선언하고 {:dsh_deactivate, _}를 구현하지 않은
  플러그인이 하나라도 있으면 call이 exit -> Context 전체 사망. plugin.ex:14 behaviour는 start_link만 선언.
- 재현: /tmp/noncontract_repro2.exs

### [높음] H2 — deactivate 핸들러의 Context 재진입 = 순환 대기

- handle_call(:unload)/handle_info(:DOWN) 안에서 의존자에 동기 블로킹 -> 핸들러가 Context를 다시
  호출하면 상호 대기(5초 후 크래시). 재현: /tmp/deadlock_repro.exs

### [높음] H3 — provide+register 혼용 시 register가 fiber 덮어써 이전 inverse 유실

- context.ex register가 소유자 fiber를 통째로 교체 -> provide가 쌓은 inverses 유실 ->
  unload 후에도 바인딩 잔류(복구 정확성 붕괴). 재현: /tmp/provide_register_repro.exs

### [중간] M1~M5

- M1 reactive coeffect의 제공-의존 계층 불일치
- M2 teardown 전역 블로킹 -> 고장 격리 약화
- M3 크래시 경로(:kill)에서 committed view 미보장(provider가 링크로 함께 사망)
- M4 시작 실패 시 상태 일관성
- M5 합류(재구성 순서 무관)의 동시성 미검증

### [낮음] L1~L4

- L1 history 무한 성장 / L2 타임아웃 산재·고정 / L3 DOWN·명시 unload 레이스 멱등성 미검증 /
  L4 Session.Plugin에 handle_info 캐치올 부재

### 4대 보증 판정

1. 복구 정확성 — 부분 성립: 정상 경로 성립, provide+register 혼용 시 깨짐(H3).
2. L-Unload 가드 — 정상 경로 성립, 크래시 경로(:kill) 불성립(view가 dead pid).
3. 합류 — 순차 경로 약 성립, 동시성 미검증.
4. 고장 격리 — 부분 성립: 파이버 단위 복구 성립, 비계약 의존자(H1)와 teardown 전역 블로킹(M2)으로 약화.

### A의 M2 정정 (B가 반박 — B가 맞음)

- A-M2(고정 이름 ETS 충돌)는 오진. memory.ex의 :dsh_session_memory는 :named_table 옵션이 없는
  식별자 이름이라 전역 등록이 아니고, 두 테이블 공존 시에도 충돌 없음. 익명 테이블은 소유자 사망 시
  자동 삭제 + terminate의 :ets.delete로 양 경로 정리됨. -> A-M2 기각.
- 동적 원자 생성 없음(결함 아님).

## 병합 판정 및 수정 계획

두 리뷰가 교차하는 핵심: (1) Context가 handle_call 안에서 의존자에 동기 call = 교착·전역 크래시의
단일 원인, (2) :temporary + 실패 삼킴 = 수렴 실패, (3) 문서(PLAN)와 구현의 격차, (4) 크래시 경로의
가드 미보장은 문서화된 긴장이지만 명시 필요.

수정 순서(TDD: 회귀 테스트 먼저):

- P1 (정확성, 최우선): register가 기존 fiber를 병합(덮어쓰기 제거) — H3 회귀 테스트부터.
  [완료: 회귀 테스트 red→green, 16 passed, --warnings-as-errors 클린]
- P2 (교착·전역 크래시): 비활성화를 비동기 2-phase로(메시지 + ack 수집, 타임아웃 폴백),
  use Dsh.Plugin 매크로로 activate/deactivate/terminate 기본 구현 주입 + behaviour 계약 컴파일 강제 —
  A-H1/B-H1/B-H2/A-M3 동시 해소. 재현 스크립트 2개를 테스트로 옮김.
  [완료: C' 설계(하단 정정 참조)로 구현. use Dsh.Plugin 매크로 + pending-unload 상태 머신 +
  {:dsh_withdraw}/{:dsh_deactivated} 프로토콜. B-H1/B-H2 회귀 테스트 red→green, 18 passed,
  --warnings-as-errors 클린. 1.20 타입 체커가 죽은 {:stop} 분기 2건을 잡아 계약을 {:ok, state} 단일형으로 단순화.]
- P3 (수렴): Runtime — 시작 실패를 :error로 반환, DOWN 시 spec 재주입으로 자가 치유 — A-H2.
  [완료: reconcile이 {:error, errors} 반환, 크래시 재주입 @max_restarts 3 후 :crash_loop 기록, 회귀 테스트 2개 red→green]
- P4 (문서·구현 정렬): PLAN/moduledoc을 "2상태 맵 레코드 축소 모델"로 정정하고,
  파이버 :gen_statem 프로세스 승격을 마일스톤 2로 명시 — A-M5.
  [완료: PLAN §3/§4/§10/§11을 구현과 정렬, §12 마일스톤 2 후보 정의]
- P5 (위생): seam 사코드 제거(A-M1), API 반환형 통일(L1), monitor 역인덱스(L2), diff 정규화(L3),
  history 상한, Session.Plugin 캐치올, README 작성, erl_crash.dump 삭제.
  [완료: session seam은 호출 표면+프로토콜로 단일화, get은 {:ok,v}|:not_found, monitors %{owner=>ref},
  diff는 Map.new 정규화, history @max_history 200, README 작성, crash dump 삭제]
- 마일스톤 2로: 크래시 경로 committed view 보장(정렬된 shutdown), 파이버 프로세스 승격, 합류 동시성 검증.

### P2 설계 정정 — C' (exit-신호 형태, keep-alive 전달)

승인된 C(exit 신호 + DOWN)를 세부 설계하다 발견한 문제: exit 신호는 의존자를 죽여서
(a) 논문의 "파이버는 비활성화 후에도 생존·재활성화"와 어긋나고 (b) provider 스왑 시
소비자 재활성화가 불가능해짐. 따라서 C의 형태(Context는 절대 의존자에 블로킹 call을
하지 않고 handle_info에서 완료를 수집, pid 상관)를 유지하되, 전달은 exit 신호가 아니라
일반 메시지 {:dsh_withdraw, keys}로, 완료는 {:dsh_deactivated, pid, keys} ack(또는 :DOWN,
또는 타임아웃)로. 의존자는 살아남아 :inactive가 되고 재활성화 가능.

- B-H1: ack 없는 의존자 -> 타임아웃으로 강행(Context 생존)
- B-H2: teardown 중 Context 재호출 -> Context가 handle_info에서 자유로워 교착 불가
- 제공자 terminate는 {:dsh_unloaded}를 기다렸다 반환 -> 자원이 의존자 teardown 동안 생존

## 마일스톤 2 진행 기록

### 2-① 파이버 :gen_statem 프로세스 승격 (완료)

- use Dsh.Plugin이 :gen_statem 4상태(:inactive/:reloading/:active/:unloading) 파이버를 생성.
- 모든 전이가 {:dsh_fiber_state, pid, state}를 Context에 보고 — 미러는 그래프 계산용, 파이버가 권위.
- 비즈니스 훅이 전이에 연결(ready/activate/withdraw), 활성화 중 뷰 변경 시 재커밋(L-Divert 축소판).

### 2-② 크래시 경로 committed view — 정렬된 shutdown (완료)

- 자원(세션 서버)을 unlinked로 시작하고, "자원 해제"를 Dsh.Context.effect의 역으로 누산기에 등록.
  철수 프로토콜(의존자 drain) 후에만 역이 실행되므로, 제공자가 :kill로 죽어도 의존자의 teardown
  중에는 자원이 살아 있다. 크래시 경로도 동일한 ordered_withdraw를 통과.
- 세션 서버 종료 폴백: Session.Plugin.terminate가 super 후 잔존 시 정리(앱 전체 종료 대비).

### TDD가 잡아낸 것 2건

- start_link가 반환된 후에야 파이버가 등록되는 비동기 초기화 레이스 — 등록을 init에서 동기화.
- "바인딩 부재"를 기다리는 테스트가 등록 전/철수 후를 구분 못 하던 설계 오류 — 등록 완료를 먼저 대기 후 크래시 유발.

### 알려진 한계 (마일스톤 2 후보로)

- Runtime의 크래시 재주입(P3)이 "철수 진행 중인 바인딩"에 :already_provided로 실패 —
  재주입에 백오프/재시도가 필요. (의도적 kill과 크래시를 구분하지 못함)

### 2-④ Spark DSL 전면 (완료)

- {:spark, "~> 2.6"} 추가 (2.7.2 해석). Dsh.Plugin.Dsl: need/provide 섹션(top_level),
  Dsh.Composition: entry 섹션(Def 74의 id/plugin/config/disabled). Spark Builder API로 정의,
  컴파일타임 스키마 검증 + Spark.Dsl.Extension.get_entities introspection(cordis_inspect의 기질).
- use Dsh.Plugin이 기본 mount를 DSL에서 생성(need 목록 + provide value/via), 사용자 mount는
  defoverridable로 재정의. 조성 모듈의 entries/1이 Runtime 입력으로 직결.
- 테스트 3개: need/provide → mount 계약 컴파일, via MFA 값 계산, 조성 DSL → Runtime 부팅·재구성.
- 기존 27개 테스트가 DSL 위에서 그대로 통과(회귀망 성립).

## 마일스톤 3 — 크리에이터 모드 (완료)

- Dsh.Creator: define(compile->load->mount) / redefine(트랜잭션 HMR: 컴파일 선행, 가드 통과 철수,
  :code.purge/delete + load_binary, 실패 시 롤백) / undefine(철수 + 코드 언로드).
- BEAM :code 서버 = 논문 §6.4의 런타임 모듈 레지스트리(도입·퇴출이 1급). Node ESM은 퇴출 불가.
- 트러블슈팅 기록: Code.compile_string은 모듈을 "Elixir." 접두 원자로 반환 -> Module.concat/1로 정렬.
  문법 오류는 diagnostics 대신 raise -> SyntaxError/TokenMissingError rescue. :code.load_binary는
  {:module, mod}를 반환.
- 알려진 한계: 크리에이터 소스는 신뢰(원자 생성 + 인프로세스 실행). §6.3 실행 경계(샌드박스)는 미래 작업.
