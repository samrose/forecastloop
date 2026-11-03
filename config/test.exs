import Config

config :forecast_loop, Oban, testing: :manual

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :forecast_loop, ForecastLoop.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "forecast_loop_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :forecast_loop, ForecastLoopWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8K6aZZ68+YVanhHTxuF9s6v/jNiF//Y2n4dDxjMEi1GSbqaAA2Vo6BMmlR07edXj",
  server: false

# In test we don't send emails
config :forecast_loop, ForecastLoop.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# HTTP CSV sources call a Req.Test stub in tests instead of the network.
config :forecast_loop, :http_csv_req_options, plug: {Req.Test, ForecastLoop.Sources.HTTPCSV}
