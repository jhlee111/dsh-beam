import Config

# The live web console (DshBeam.Console) owns the endpoint. No :server key
# here: Phoenix merges the app env over start options, so the listener flag
# must flow through the plugin's Endpoint.start_link(server: ...) instead
# (false in tests, true in the demo script).
config :dsh_beam, DshBeamWeb.Endpoint,
  url: [host: "localhost"],
  # Default console port. Override at boot with DSH_BEAM_PORT if it
  # collides with another dev server (e.g. DSH_BEAM_PORT=5000 mix run
  # scripts/console.exs). DshBeam.Console resolves the port at mount.
  http: [ip: {127, 0, 0, 1}, port: 4888],
  secret_key_base: "rU3TXZC/i6qAxccsnzuurTbjrtBiHIN8jytbq9qJ2QdOC5UbIvSHiC2KNRo7sIPG",
  live_view: [signing_salt: "dsh_beam_lv"],
  check_origin: false,
  pubsub_server: DshBeam.PubSub,
  # Code reloading is intentionally OFF for the console demo. Phoenix 1.8's
  # CodeReloader recompiles changed modules on each request, but it cannot
  # recover from a config change (it raises "restart your server") and, on a
  # mid-edit compile error, it leaves the running VM serving a poisoned
  # CompileError page that kills the LiveView socket. For a stable demo we
  # prefer an explicit restart after an edit, so we also omit the
  # Phoenix.CodeReloader plug and the Mix :listeners entry.
  code_reloader: false

config :phoenix, :json_library, Jason

# Never log credential/key parameters: mask them in the request log.
config :phoenix, :filter_parameters, ["credential_value", "password", "api_key"]
