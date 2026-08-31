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

  # Code reloading is on (see config/config.exs): the Phoenix.CodeReloader
  # recompiles changed modules on each request so a source edit applies
  # without restarting the console. Phoenix.CodeReloader is registered as a
  # Mix listener (mix.exs), so `mix run scripts/console.exs` sees the
  # recompiled code.
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

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
