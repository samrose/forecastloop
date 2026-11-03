defmodule ForecastLoopWeb.PageController do
  use ForecastLoopWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
