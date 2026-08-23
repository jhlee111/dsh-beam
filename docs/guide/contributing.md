# Contributing

## The workflow

1. Pick a guarantee or a gap (see PLAN.md's milestone list).
2. Write the failing test first (`test/dsh/<area>_test.exs`) — the suite is
   "one test per paper guarantee".
3. Implement in `lib/dsh/...`.
4. Run the four gates and fix everything.

## Adding a plugin

Create `lib/dsh/<name>.ex`:

```elixir
defmodule DshBeam.<Name> do
  use DshBeam.Plugin

  need :<dependency>          # if it depends on another capability
  provide :<key>, value: ...  # if it provides one
  # setting / tool / ui_slot as needed
end
```

If it has runtime work (starts a resource), override `mount/3` with `@impl`.
If it answers tool calls, implement `handle_dsh_tool_call/3`.

## Adding a tool

```elixir
tool :my_tool,
  description: "what it does",
  parameters: %{"type" => "object", "properties" => %{...}},
  timeout_ms: 10_000   # optional cooperative budget (ADR-0000 guards)

@impl DshBeam.Plugin
def handle_dsh_tool_call(:my_tool, args, state), do: {:ok, "..."}
```

The Tool registry discovers it automatically; the agent loop sends it to the
model when its `need`s are satisfied.

## Adding a UI panel

```elixir
use DshBeam.Plugin
import Phoenix.Component

ui_slot :panels, kind: :list, order: 30, component: {__MODULE__, :panel, []}

def panel(assigns) do
  ~H"""
  <section><h2>my panel</h2>…</section>
  """
end
```

See ADR-0013 and `DshBeam.Ui.render_slot/3` for the four `kind`s.

## Adding an ADR

Any non-obvious decision gets an ADR. Copy `docs/adr/template.md`, fill it in,
and add an index row — see `docs/adr/README.md`.

## Style

- `mix format` is the formatter; do not hand-format.
- Comments explain *why*, not *what*.
- English only (docs, comments, commit messages).
- Commit subjects: lowercase, imperative, conventional (`feat:`, `fix:`,
  `docs:`, `test:`, `chore:`, `ci:`).

## CI

`.github/workflows/ci.yml` runs, in order:

```yaml
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
```

The distributed tests skip in CI (no epmd/cookie); run them locally to cover
`dist_test.exs`.
