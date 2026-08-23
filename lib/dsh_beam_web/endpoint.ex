defmodule DshBeamWeb.Endpoint do
  @moduledoc """
  The console's HTTP endpoint. It is owned by the DshBeam.Console plugin
  fiber — the UI is a plugin like any other — and is normally started with
  server: false (LiveView tests and the demo script drive it directly).
  """

  use Phoenix.Endpoint, otp_app: :dsh_beam

  socket("/live", Phoenix.LiveView.Socket)

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
