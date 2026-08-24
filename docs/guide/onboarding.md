# Onboarding

## Prerequisites

- Elixir 1.20.2 / OTP 28 (pinned in `.tool-versions`; asdf recommended)
- git submodules enabled (the reference harness)

## First run

```bash
git submodule update --init            # initialize reference/deepseek-harness
mix deps.get
mix test                                # 120+ tests, all paper guarantees
```

The four CI gates (also in `.github/workflows/ci.yml`):

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
```

## The live console

```bash
DEEPSEEK_API_KEY=sk-... mix console   # http://127.0.0.1:4888
DSH_BEAM_PORT=5000 mix console        # DSH_BEAM_PORT overrides the default port
```

`mix console` is an alias for `mix run scripts/console.exs`.

- The page seeds the full agent composition (`session`, `llm`, `shell`, `bash`,
  `fs`, `todo`, `loop`) automatically.
- Enter the API key in **llm settings** (or set `DEEPSEEK_API_KEY`); a literal
  key lives in the fiber's memory and is lost on restart.
- The **chat** pane drives the agent loop (multi-turn, real-time tool trace).
- The **todo** panel shows the agent's plan (a session projection).
- The **creator / sandbox** pane defines plugins from source; **export plugin
  (.exs)** persists the composition + source as a deployable script.

## Offline demo (no network / no key)

```bash
mix run scripts/agent_demo.exs
```

Runs the loop end-to-end against a deterministic scripted adapter (emits one
bash tool call), so the whole model → tool → result → answer path is visible
without an API key.

## Running the distributed tests

`test/dsh/dist_test.exs` needs `epmd` and `~/.erlang.cookie`:

```bash
epmd -daemon
mix test test/dsh/dist_test.exs
```

They skip gracefully without them (CI also skips them).
