defmodule ForecastLoop.Repo do
  use Ecto.Repo,
    otp_app: :forecast_loop,
    adapter: Ecto.Adapters.Postgres
end
