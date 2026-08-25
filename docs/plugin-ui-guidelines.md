# dsh-beam 플러그인 UI — 동적 주입 가이드라인

> "플러그인만으로 UI를 낀다"는 원칙을 지키면서, 어떤 플러그인 UI를 어떤
> 방식으로 동적으로 주입할지 결정하는 기준. (dsh-phx-demo 회고 후속)

## 1. 핵심 제약 (하네스 구조)

플러그인은 `ui_slot(:name, kind:, component: {M, :panel, []})`로 슬롯을 선언하고,
호스트 LiveView(콘솔)가 `DshBeam.Ui.render_slot/3`으로 합성한다.

- 슬롯 `component`는 **함수 컴포넌트**(`{M, :fun, []}` 또는 1-arity fun).
- `render_slot`은 컴포넌트를 호출해 얻은 `Phoenix.LiveView.Rendered`를
  리스트로 반환한다. 호스트는 반드시 `for` 컴프리헨션으로 인라인해야 한다:

  ```heex
  <%= for rendered <- DshBeam.Ui.render_slot(:details, assigns) do %>
    <%= rendered %>
  <% end %>
  ```

- **`to_iodata`로 평탄화하면 안 된다.** `Phoenix.LiveView.Rendered.to_iodata`는
  중첩된 `Component`(LiveComponent)를 만나면 예외를 던지고, `phx-*`/훅/이벤트
  바인딩이 끊긴다.

## 2. 결정 기준 (UI 종류별 권장 경로)

| 플러그인 UI | 권장 경로 | 이유 |
|---|---|---|
| **정적 표시** (목록·설명·배지) | 함수 컴포넌트 (`~H`) | 상태/이벤트 불필요 |
| **서버 상태 + 이벤트** (폼·카운터·셀렉트) | **LiveComponent** (`.live_component`) | 자체 `handle_event`/`mount`. 호스트 콘솔 수정 불필요 |
| **클라이언트 상태·상호작용** (계산기·로컬 캐시) | **Web Component** (`class X extends HTMLElement`) | 서버 왕복 0, Shadow DOM 격리 |
| **완전 격리** (외부 앱·별도 런타임) | `<iframe>` | 경계 명확, 서버 상태는 별도 채널 |

## 3. LiveComponent 경로 (방향 A — 이번에 열림)

`render_slot`이 `Rendered`를 반환하도록 바꿔서, 플러그인이 **자체 상태 +
자체 이벤트**를 가진 완결형 LiveComponent를 슬롯에 넣을 수 있게 됐다.

```elixir
defmodule MyPlugin do
  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:details, kind: :list, order: 1, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <section>
      <.live_component module={MyPlugin.Widget} id="my-widget" />
    </section>
    """
  end
end

defmodule MyPlugin.Widget do
  use Phoenix.LiveComponent

  def mount(socket), do: {:ok, assign(socket, count: 0)}

  def handle_event("inc", _p, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}

  def render(assigns) do
    ~H"""
    <div>
      <span>count: <%= @count %></span>
      <button type="button" phx-click="inc" phx-target={@myself}>+</button>
    </div>
    """
  end
end
```

- `phx-target={@myself}`로 이벤트를 **LiveComponent 자신**에게 보낸다.
- 콘솔(호스트)의 `handle_event`를 건드리지 않는다.
- POC 테스트: `test/dsh/ui_live_component_test.exs` (렌더 + 이벤트 검증 통과).

## 4. Web Component 경로 (클라이언트 상태)

- **반드시 `class X extends HTMLElement`** — 프로토타입 방식은 업그레이드 실패.
- 데이터는 **JSON 속성**으로 주입.
- 상호작용은 Shadow DOM 안에서, 상태는 `localStorage`/메모리.
- 스크립트는 `<script data-phx-runtime-hook="...">` + `window.__init` 가드.

## 5. 금지 (anti-patterns)

1. 슬롯에서 `.live_component` 결과를 `to_iodata`로 직렬화 (예외).
2. 슬롯에 `phx-*` 이벤트를 붙이되 호스트 `handle_event`가 없음 (미처리).
3. 프로토타입 방식 커스텀 엘리먼트 (`function X(){ HTMLElement.call(this) }`).
4. JS 본문에 `</script>` 문자열.
5. `phx-update="ignore"`에 `id` 누락.
6. 호스트(콘솔) 수정을 전제로 한 플러그인 UI.

## 6. 동적 플러그인(런타임 컴파일) 주의

`Code.compile_string`으로 만든 플러그인은 `Plugin.Inventory.installed()`가
`:code.all_loaded()`로 발견하므로, 저장본(`~/.dsh/plugins/*.exs`)과 라이브
주입(`define_plugin`) 타이밍이 다르면 슬롯/툴이 안 보인다.

- 저장본 수정 → **콘솔 재시작**(또는 `redefine_plugin`) 후 새로고침.
- 라이브 주입 → 같은 세션에서 즉시 반영, 저장본과 어긋나면 재시작 시 소실.
