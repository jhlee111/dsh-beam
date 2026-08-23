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
      {:plug, "~> 1.0"}
    ]
  end
end
