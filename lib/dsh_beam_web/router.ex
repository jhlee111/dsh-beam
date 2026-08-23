defmodule DshBeamWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", DshBeamWeb do
    pipe_through(:browser)

    live_session :console, root_layout: {DshBeamWeb.Layouts, :app} do
      live("/", ConsoleLive)
    end
  end
end
