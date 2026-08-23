defmodule DshBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :dsh_beam,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # DSL sections/entities with compile-time validation and introspection.
      {:spark, "~> 2.6"},
      # HTTP client for the LLM provider adapter (OpenAI-compatible APIs).
      {:req, "~> 0.5"},
      # Req.Test.json mocking (and Phoenix later) build on Plug.Conn.
      {:plug, "~> 1.0"},
      # The live web console (milestone 4): the UI is a plugin too.
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:plug_cowboy, "~> 2.7"},
      # LiveViewTest's DOM backend (LiveView 1.2). Pinned to 0.1.11: 0.1.12
      # ships no precompiled NIF for aarch64-apple-darwin and this machine
      # has no cmake for a source build.
      {:lazy_html, "0.1.11", only: :test}
    ]
  end
end
