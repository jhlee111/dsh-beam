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
        <style>
          body { font-family: ui-monospace, monospace; font-size: 13px; margin: 0; background: #0f1115; color: #d7dae0; }
          main { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; padding: 12px; }
          section { background: #161a21; border: 1px solid #232a36; border-radius: 6px; padding: 10px; }
          h2 { font-size: 13px; margin: 0 0 8px; color: #8fa3bf; text-transform: uppercase; letter-spacing: .06em; }
          table { width: 100%; border-collapse: collapse; }
          th, td { text-align: left; padding: 3px 6px; border-bottom: 1px solid #20262f; vertical-align: top; }
          th { color: #6b7a90; font-weight: normal; }
          code, pre { color: #9ecbff; }
          .muted { color: #6b7a90; }
          .state-inactive { color: #f0b429; }
          .state-active { color: #34d399; }
          .state-reloading { color: #60a5fa; }
          .state-unloading { color: #fb7185; }
          .state-gone { color: #6b7a90; }
          textarea, input, select, button { background: #0c0f14; color: #d7dae0; border: 1px solid #2b3442; border-radius: 4px; padding: 5px 8px; font-family: inherit; font-size: 12px; }
          textarea { width: 100%; min-height: 130px; resize: vertical; }
          button { cursor: pointer; }
          button:hover { border-color: #4b5b75; }
          form.row { display: flex; gap: 6px; align-items: center; }
          ul { margin: 0; padding-left: 16px; }
          li { margin: 2px 0; }
          .pill { display: inline-block; padding: 1px 6px; border-radius: 8px; border: 1px solid #2b3442; }
          .events { max-height: 180px; overflow-y: auto; }
          .chat { max-height: 220px; overflow-y: auto; }
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
