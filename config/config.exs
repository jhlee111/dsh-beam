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
  # Code reloading is ON so a source edit (layout/panel/handler) applies on
  # the next browser request — the dev-server workflow the user asked for.
  # A mid-edit compile error is handled by the watchdog (dsh-console.sh
  # restarts the console within ~5s), and a config change still needs a full
  # restart (Phoenix raises "restart your server" — the console script
  # re-reads config at boot, so a restart covers it).
  code_reloader: true

config :phoenix, :json_library, Jason

# Never log credential/key parameters: mask them in the request log.
config :phoenix, :filter_parameters, ["credential_value", "password", "api_key"]
