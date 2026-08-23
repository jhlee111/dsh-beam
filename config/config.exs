import Config

# The live web console (DshBeam.Console) owns the endpoint. No :server key
# here: Phoenix merges the app env over start options, so the listener flag
# must flow through the plugin's Endpoint.start_link(server: ...) instead
# (false in tests, true in the demo script).
config :dsh_beam, DshBeamWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4001],
  secret_key_base: "dsh_beam_dev_secret_do_not_use_in_production",
  live_view: [signing_salt: "dsh_beam_lv"],
  check_origin: false,
  pubsub_server: DshBeam.PubSub,
  # Recompile + reload changed modules on each request in dev, so the console
  # demo (mix run, not mix phx.server) reflects edits without a restart.
  code_reloader: config_env() == :dev

config :phoenix, :json_library, Jason

# Never log credential/key parameters: mask them in the request log.
config :phoenix, :filter_parameters, ["credential_value", "password", "api_key"]
