defmodule DshBeam.Ui.Panel.ElementSelect do
  @moduledoc """
  Element select — the composer "Pick" seat (the reference ui-element-select,
  built here as one of the harness's creator-plugin packages).

  The harness's superpower is authoring plugins at runtime, from inside the
  console itself. For UI plugins, though, the author's feedback is fuzzy:
  "this button", "move it here, not there", "make that row darker". This seat
  turns that fuzzy pointer into a precise one — click **Pick**, then click any
  element of the dsh-beam console. The seat collects the element's **CSS
  selector, HTML snippet and visible text** and injects a structured marker
  straight into the composer draft:

      [요소 지적] button#composer-send .composer-send
      슬롯: :composer_toolbar
      플러그인: DshBeam.Ui.Panel.Command
      소스: lib/dsh/ui/panel/command.ex
      셀렉터: form.composer > .composer-actions > button.composer-send
      내용: "send"
      HTML: <button class="composer-send">send</button>

  The user then completes the request ("…의 색을 바꿔줘") and the agent reads
  the marker to locate the exact element in source (the `prompt_section` below
  teaches it how: slot → owning plugin → panel component/layout). That is the
  creator-plugin feedback loop this package exists for.

  Everything the seat needs lives in this module — the slot registration, the
  seat markup, its CSS, and the picker JS (a Phoenix LiveView runtime hook
  declared via `data-phx-runtime-hook`, so the shell's static hooks map never
  has to change). The only shell contract is the `element_pick` LiveView event,
  which appends the marker to `@chat_text`.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:composer_toolbar, kind: :list, order: 15, component: {__MODULE__, :panel, []})

  prompt_section(:element_select,
    order: 120,
    text:
      "UI element feedback (ElementSelect): the user can point at any element of this console via the composer's Pick toolbar button. A pick arrives as a structured marker in the user message: [요소 지적] <tag>#<id> .<classes>, a CSS selector, the element's visible text, its outerHTML, and the owning-region context (슬롯: the ui_slot it renders into; 플러그인: the plugin module that rendered it; 소스: its source file). To act on it, locate the element in source: console chrome lives in lib/dsh_beam_web/layouts.ex and lib/dsh_beam_web/console_live.ex; plugin-rendered UI lives in lib/dsh/ui/panel/*.ex and renders into a ui_slot (sidebar / conversation / composer_toolbar / details / settings_section). Match the selector/class, find the owning plugin, edit that plugin's panel component or the layout, then define_plugin/redefine_plugin to apply it live. This is the creator-plugin feedback channel: a precise pointer from the user's eyes to the code."
  )

  @doc "Build the agent-readable marker text from the JS pick payload."
  def marker(%{"selector" => selector} = p) do
    tag = p["tag"] || "element"
    id = if p["id"] in [nil, ""], do: "", else: "##{p["id"]}"
    classes = p["classes"] || ""
    text = p["text"] || ""
    html = p["html"] || ""

    ([
       "[요소 지적] #{tag}#{id}#{if classes == "", do: "", else: " .#{classes}"}",
       "셀렉터: #{selector}"
     ] ++
       region_lines(p) ++
       [
         if(text == "", do: nil, else: "내용: #{inspect(String.slice(text, 0, 200))}"),
         if(html == "", do: nil, else: "HTML: #{String.slice(html, 0, 600)}")
       ])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def marker(_), do: "[요소 지적] unknown element"

  # Owning-region context: which slot the element renders into, which plugin
  # rendered it, and its source file — so the agent can jump to the code
  # instead of reverse-engineering it from the HTML snippet.
  defp region_lines(%{"region" => region}) when is_map(region) do
    plugin = region["plugin"] || ""

    if plugin == "" do
      []
    else
      slot = region["slot"] || ""
      key = region["key"] || ""
      source = region["source"] || ""

      [
        "슬롯: :#{slot}" <> if(key == "", do: "", else: " (key: #{key})"),
        "플러그인: #{plugin}",
        if(source == "", do: nil, else: "소스: #{source}")
      ]
      |> Enum.reject(&is_nil/1)
    end
  end

  defp region_lines(_), do: []

  def panel(assigns) do
    ~H"""
    <div class="element-select-seat" id="element-select-seat" phx-hook="ElementSelect">
      <button
        type="button"
        class="element-select-trigger"
        aria-label="select an element of this UI to tell the agent about"
        disabled={@chat_busy}
      >
        <span class="element-select-icon">⛏</span>
        <span class="element-select-label">Pick</span>
      </button>

      <style>
        .element-select-seat { position: relative; display: inline-flex; }
        .element-select-trigger {
          display: inline-flex; align-items: center; gap: 4px; height: 28px;
          padding: 0 10px; border-radius: 24px;
          border: 1px solid var(--dsw-alias-border-l2);
          background: transparent; color: var(--dsw-alias-label-secondary);
          font-size: 13px; line-height: 20px; font-weight: 500; cursor: pointer;
        }
        .element-select-trigger:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover); }
        .element-select-trigger:disabled { color: var(--dsw-alias-label-dimmed); cursor: default; }
        .element-select-seat.active .element-select-trigger {
          color: var(--dsw-static-deepseek-400, #679efe);
          border-color: var(--dsw-static-deepseek-400, #679efe);
        }
        .dsh-element-select-picking, .dsh-element-select-picking * { cursor: crosshair !important; }
        .dsh-element-select-hint {
          position: fixed; top: 12px; right: 12px; z-index: 9999;
          padding: 8px 12px; border-radius: 8px; pointer-events: none;
          background: var(--dsw-static-neutral-bluish-850, #161a21);
          border: 1px solid var(--dsw-static-deepseek-400, #679efe);
          color: var(--dsw-alias-label-primary); font-size: 12px;
          box-shadow: var(--dsw-shadow-lv2, 0 4px 12px rgba(0, 0, 0, .4));
        }
        .dsh-element-select-highlight {
          position: fixed; z-index: 9998; pointer-events: none;
          outline: 2px solid var(--dsw-static-deepseek-400, #679efe);
          outline-offset: 1px; background: rgba(103, 158, 254, .12);
        }
      </style>

      <script data-phx-runtime-hook="ElementSelect">
        window.phx_hook_ElementSelect = () => ({
          mounted() {
            this.active = false;
            this.hint = null;
            this.highlight = null;
            this.hoverEl = null;
            this.suppressToggle = false;

            this.enter = () => {
              if (this.active) return;
              this.active = true;
              document.body.classList.add('dsh-element-select-picking');
              this.hint = document.createElement('div');
              this.hint.className = 'dsh-element-select-hint';
              this.hint.textContent = 'click any element to tell the agent about it · esc to cancel';
              document.body.appendChild(this.hint);
              this.highlight = document.createElement('div');
              this.highlight.className = 'dsh-element-select-highlight';
              document.body.appendChild(this.highlight);
              this.el.classList.add('active');
            };

            this.exit = () => {
              if (!this.active) return;
              this.active = false;
              document.body.classList.remove('dsh-element-select-picking');
              if (this.hint) { this.hint.remove(); this.hint = null; }
              if (this.highlight) { this.highlight.remove(); this.highlight = null; }
              this.el.classList.remove('active');
              this.hoverEl = null;
            };

            this.onToggle = (e) => {
              e.preventDefault();
              e.stopPropagation();
              if (this.suppressToggle) { this.suppressToggle = false; return; }
              if (this.active) { this.exit(); } else { this.enter(); }
            };

            this.cssPath = (el) => {
              const parts = [];
              let node = el;
              while (node && node.nodeType === 1 && node.tagName.toLowerCase() !== 'html') {
                let part = node.tagName.toLowerCase();
                if (node.id) { parts.unshift(part + '#' + node.id); break; }
                if (node.classList && node.classList.length) {
                  part += '.' + Array.from(node.classList).slice(0, 3).join('.');
                }
                const parent = node.parentElement;
                if (parent) {
                  const sibs = Array.from(parent.children).filter((s) => s.tagName === node.tagName);
                  if (sibs.length > 1) part += ':nth-of-type(' + (sibs.indexOf(node) + 1) + ')';
                }
                parts.unshift(part);
                node = parent;
                if (parts.length >= 6) break;
              }
              return parts.join(' > ');
            };

            this.onMove = (e) => {
              if (!this.active) return;
              const el = document.elementFromPoint(e.clientX, e.clientY);
              if (!el || el === this.hoverEl) return;
              this.hoverEl = el;
              if (this.highlight) {
                const r = el.getBoundingClientRect();
                this.highlight.style.left = r.left + 'px';
                this.highlight.style.top = r.top + 'px';
                this.highlight.style.width = r.width + 'px';
                this.highlight.style.height = r.height + 'px';
              }
            };

            this.onPick = (e) => {
              if (!this.active) return;
              e.preventDefault();
              e.stopPropagation();
              e.stopImmediatePropagation();
              const el = this.hoverEl || e.target;
              if (el && el.closest && el.closest('.element-select-seat')) {
                this.suppressToggle = true;
                this.exit();
                return;
              }
              if (el && el.nodeType === 1) {
                const regionEl = el.closest('[data-dsh-region]');
                const region = regionEl ? {
                  slot: regionEl.getAttribute('data-dsh-slot') || '',
                  plugin: regionEl.getAttribute('data-dsh-plugin') || '',
                  source: regionEl.getAttribute('data-dsh-source') || '',
                  key: regionEl.getAttribute('data-dsh-key') || ''
                } : null;
                const payload = {
                  tag: el.tagName.toLowerCase(),
                  id: el.id || '',
                  classes: Array.from(el.classList || []).join(' '),
                  selector: this.cssPath(el),
                  text: (el.innerText || el.textContent || '').trim().slice(0, 200),
                  html: (el.outerHTML || '').slice(0, 600),
                  region: region
                };
                this.pushEvent('element_pick', payload);
                this.exit();
              }
            };

            this.onKey = (e) => { if (e.key === 'Escape' && this.active) this.exit(); };

            this.el.addEventListener('click', this.onToggle);
            document.addEventListener('mousemove', this.onMove, { passive: true });
            document.addEventListener('click', this.onPick, { capture: true });
            document.addEventListener('keydown', this.onKey);
          },
          destroyed() {
            this.el.removeEventListener('click', this.onToggle);
            document.removeEventListener('mousemove', this.onMove);
            document.removeEventListener('click', this.onPick, { capture: true });
            document.removeEventListener('keydown', this.onKey);
            this.exit();
          }
        });
      </script>
    </div>
    """
  end
end
