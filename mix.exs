defmodule DshBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :dsh_beam,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Compile the changed modules on each request so a source edit applies
      # without a console restart (dev-server workflow). Phoenix 1.8 requires
      # its reloader to be a Mix listener (not the alias name): the listener
      # tracks compilation from the `mix run` VM, and the CodeReloader plug
      # picks the recompiled modules up per request.
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # "mix console" = `mix run scripts/console.exs` (the live console demo).
  # DEEPSEEK_API_KEY / DSH_BEAM_PORT pass through as env vars, which is what
  # the script reads, so no extra plumbing is needed. The single-string form
  # (like "run priv/repo/seeds.exs") is how Mix aliases pass args to a task.
  defp aliases do
    [
      console: ["run scripts/console.exs"]
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
      # Markdown → HTML for assistant chat messages (the reference renders
      # assistant output as markdown too).
      {:earmark, "~> 1.4"},
      # LiveViewTest's DOM backend (LiveView 1.2). Pinned to 0.1.11: 0.1.12
      # ships no precompiled NIF for aarch64-apple-darwin and this machine
      # has no cmake for a source build.
      {:lazy_html, "0.1.11", only: :test},
      # Static analysis: bug-catching checks only. Elixir 1.18+'s built-in type
      # checker already covers undefined/unused via --warnings-as-errors, so
      # Credo is scoped to what that checker does not see.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
