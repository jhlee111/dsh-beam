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
  pubsub_server: DshBeam.PubSub

config :phoenix, :json_library, Jason
