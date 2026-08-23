defmodule DshBeamWeb.Endpoint do
  @moduledoc """
  The console's HTTP endpoint. It is owned by the DshBeam.Console plugin
  fiber — the UI is a plugin like any other — and is normally started with
  server: false (LiveView tests and the demo script drive it directly).
  """

  use Phoenix.Endpoint, otp_app: :dsh_beam

  socket("/live", Phoenix.LiveView.Socket)

  # Serve the vendored LiveView client bundles (priv/static/assets) so the
  # browser can open the /live websocket — without them, phx-submit forms
  # fall back to plain HTML GET and no events reach the LiveView.
  plug(Plug.Static,
    at: "/",
    from: :dsh_beam,
    gzip: false,
    only: ~w(assets favicon.ico)
  )

  # Code reloading is off (see config/config.exs): the Phoenix.CodeReloader
  # recompiles on request and can poison the VM on a config change or a
  # mid-edit compile error.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session,
    store: :cookie,
    key: "_dsh_beam_key",
    signing_salt: "dsh_beam_session"
  )

  plug(DshBeamWeb.Router)
end
