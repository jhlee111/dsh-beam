defmodule DshBeamWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  def app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={csrf_token()} />
        <title>dsh-beam console</title>
        <link rel="stylesheet" href="/assets/dsw-base.css" />
        <link rel="stylesheet" href="/assets/dsw-design-platform.css" />
        <style>
          /* Component layout only — every color/type value comes from the
             DSH design-platform tokens (--dsw-*), not hard-coded here. */
          body {
            font-family: var(--dsw-font-family, ui-monospace, monospace);
            font-size: 13px;
            margin: 0;
            background: var(--dsw-static-neutral-bluish-950, #0f1115);
            color: var(--dsw-static-neutral-bluish-50, #d7dae0);
          }
          /* Two-pane app: persistent sidebar (workspace) + main (chat). */
          .app { display: flex; height: 100vh; }
          aside.sidebar {
            width: 280px; flex-shrink: 0; padding: 10px;
            border-right: 1px solid var(--dsw-alias-border-l1, #232a36);
            overflow-y: auto;
          }
          aside.sidebar .brand {
            font-weight: 600; letter-spacing: .04em; text-transform: uppercase;
            margin: 0 0 10px; color: var(--dsw-static-blue-300, #8fa3bf);
          }
          main.main { flex: 1; display: flex; flex-direction: column; min-width: 0; }
          .topbar {
            display: flex; justify-content: space-between; align-items: center;
            padding: 8px 12px; border-bottom: 1px solid var(--dsw-alias-border-l1, #232a36);
          }
          .content { flex: 1; padding: 12px; overflow-y: auto; }

          /* Settings modal overlay. */
          .settings-overlay {
            position: fixed; inset: 0; z-index: 100;
            background: rgba(0, 0, 0, .6);
            display: flex; align-items: center; justify-content: center;
          }
          .settings-panel {
            display: flex; width: min(760px, 92vw); max-height: 84vh;
            background: var(--dsw-static-neutral-bluish-850, #161a21);
            border: 1px solid var(--dsw-alias-border-l1, #232a36);
            border-radius: 8px; overflow: hidden;
          }
          nav.settings-nav { width: 170px; border-right: 1px solid var(--dsw-alias-border-l1, #232a36); padding: 10px; }
          .settings-nav-item {
            display: block; width: 100%; text-align: left; margin: 2px 0;
            background: transparent; border-color: transparent;
          }
          .settings-nav-item.active { border-color: var(--dsw-static-blue-500, #4b5b75); background: var(--dsw-static-neutral-bluish-900, #0c0f14); }
          .settings-content { flex: 1; padding: 12px; overflow-y: auto; }

          section {
            background: var(--dsw-static-neutral-bluish-850, #161a21);
            border: 1px solid var(--dsw-alias-border-l1, #232a36);
            border-radius: 6px;
            padding: 10px;
          }
          main.main section { margin-bottom: 12px; }
          h2 {
            font-size: 13px; margin: 0 0 8px; text-transform: uppercase; letter-spacing: .06em;
            color: var(--dsw-static-blue-300, #8fa3bf);
          }
          table { width: 100%; border-collapse: collapse; }
          th, td { text-align: left; padding: 3px 6px; border-bottom: 1px solid var(--dsw-alias-border-l1, #20262f); vertical-align: top; }
          th { color: var(--dsw-static-neutral-bluish-500, #6b7a90); font-weight: normal; }
          code, pre { color: var(--dsw-static-blue-300, #9ecbff); }
          .muted { color: var(--dsw-static-neutral-bluish-500, #6b7a90); }
          .state-inactive { color: var(--dsw-static-amber-400, #f0b429); }
          .state-active { color: var(--dsw-static-green-500, #34d399); }
          .state-reloading { color: var(--dsw-static-blue-400, #60a5fa); }
          .state-unloading { color: var(--dsw-static-red-400, #fb7185); }
          .state-gone { color: var(--dsw-static-neutral-bluish-500, #6b7a90); }
          textarea, input, select, button {
            background: var(--dsw-static-neutral-bluish-900, #0c0f14);
            color: var(--dsw-static-neutral-bluish-50, #d7dae0);
            border: 1px solid var(--dsw-alias-border-l3, #2b3442);
            border-radius: 4px; padding: 5px 8px; font-family: inherit; font-size: 12px;
          }
          textarea { width: 100%; min-height: 130px; resize: vertical; }
          button { cursor: pointer; }
          button:hover { border-color: var(--dsw-static-blue-500, #4b5b75); }
          form.row { display: flex; gap: 6px; align-items: center; }
          ul { margin: 0; padding-left: 16px; }
          li { margin: 2px 0; }
          .pill { display: inline-block; padding: 1px 6px; border-radius: 8px; border: 1px solid var(--dsw-alias-border-l3, #2b3442); }
          /* Tall content scrolls inside its panel instead of stretching the
             whole page past the fold — the composition table, plugin list, and
             trajectory are the offenders. */
          .scroll { max-height: 400px; overflow-y: auto; }
          .events { max-height: 200px; overflow-y: auto; }
          .chat { max-height: 260px; overflow-y: auto; }

          /* Models provider card (mirrors the reference models section). */
          .provider-card {
            border: 1px solid var(--dsw-alias-border-l3, #2b3442);
            border-radius: 6px; padding: 8px; margin-bottom: 8px;
          }
          .provider-head {
            display: flex; align-items: center; gap: 8px; margin-bottom: 8px;
          }
          .provider-name { font-weight: 600; }
          .credential-dot {
            display: inline-block; padding: 1px 6px; border-radius: 8px;
            border: 1px solid var(--dsw-alias-border-l3, #2b3442);
            font-size: 11px;
          }
          .credential-dot.configured { color: var(--dsw-static-green-500, #34d399); }
          .credential-dot.missing { color: var(--dsw-static-amber-400, #f0b429); }
          .key-row { display: flex; gap: 6px; align-items: center; }
          .key-row input { flex: 1; }
          details { margin: 6px 0; }
          summary { cursor: pointer; color: var(--dsw-static-blue-300, #8fa3bf); }
          details label { display: block; margin-top: 6px; }
          details input { width: 100%; }
          .provider-actions { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/assets/phoenix.js"></script>
        <script src="/assets/phoenix_live_view.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            params: { _csrf_token: csrfToken }
          });
          liveSocket.connect();
          window.addEventListener("phx:page-loading-stop", () => liveSocket.enableDebug());
        </script>
      </body>
    </html>
    """
  end

  defp csrf_token, do: Plug.CSRFProtection.get_csrf_token()
end
