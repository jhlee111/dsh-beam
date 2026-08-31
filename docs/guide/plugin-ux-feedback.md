# Plugin UX feedback (ElementSelect)

This page is the *agent-side* recipe for the creator-plugin feedback loop this
repository ships: a user points at the console UI, and the marker they produce
must resolve to code with zero guessing.

## The Pick seat

The composer toolbar has a **Pick** button (`DshBeam.Ui.Panel.ElementSelect`,
order 15 in `:composer_toolbar`). While active, clicking any element of the
console produces a structured marker that is injected into the composer draft.
The user then completes the request ("…의 색을 바꿔줘", "…을 ⋮ 메뉴 뒤로
숨겨줘") and the agent reads the marker.

## Anatomy of a pick marker

```
[요소 지적] button#composer-send .composer-send
슬롯: :composer_toolbar
플러그인: DshBeam.Ui.Panel.Command
소스: lib/dsh/ui/panel/command.ex
셀렉터: form.composer > .composer-actions > button.composer-send
내용: "send"
HTML: <button class="composer-send">send</button>
```

| Line | Meaning |
|---|---|
| `[요소 지적]` | the marker's key, searchable in session logs |
| `<tag>#<id> .<classes>` | the element's identity |
| `슬롯:` | the `ui_slot` the element renders into (`:sidebar`, `:conversation`, `:composer_toolbar`, `:details`, `:settings_section`) |
| `플러그인:` | the plugin module that rendered it |
| `소스:` | its source file — start here |
| `셀렉터:` / `내용:` / `HTML:` | locate the exact node inside that file |

Keyed slots add the key: `슬롯: :settings_section (key: plugins)`.

## Where things live in source

- **Console chrome** (frame, tabs, composer shell, settings/picker overlays):
  `lib/dsh_beam_web/layouts.ex` and `lib/dsh_beam_web/console_live.ex`.
- **Plugin panels**: `lib/dsh/ui/panel/*.ex`, each rendering into one `ui_slot`.
- **Slot composition**: `DshBeam.Ui.render_slot/3` (`lib/dsh/ui.ex`) wraps each
  contribution in a `data-dsh-region` marker — this is what the picker reads.

## Applying a change

1. Open `소스:`; match the `셀렉터:`/class inside the panel component.
2. Edit the panel's `~H"""…"""` (markup), its `<style>` block (scoped CSS), or
   its `<script data-phx-runtime-hook="…">` (client behaviour).
3. Apply live with `define_plugin` (new module) or `redefine_plugin` (same
   module name). Both are model-facing tools; `save_plugin` persists a reusable
   `.exs` under `~/.dsh/plugins`.
4. If the change touches a shell file (`console_live.ex`, `layouts.ex`), the
   console needs a restart — but every UI plugin change should stay inside the
   panel module.

## Working rules

- **Never** add a hook name to the static hooks map in `layouts.ex` — a plugin
  ships its own hook with `<script data-phx-runtime-hook="Name">…</script>` and
  `window.phx_hook_Name = () => ({…})`.
- Prefer scoped `<style>` inside the panel over editing the global layout
  stylesheet; use the `--dsw-*` design tokens, not hard-coded colors.
- Destructive actions (closing a session, removing a folder) belong behind a
  deliberate two-step path — see the workspace row ⋮ menu.
- Run `mix test` and keep the region marker payload backwards-compatible: it is
  a plain map of strings.
