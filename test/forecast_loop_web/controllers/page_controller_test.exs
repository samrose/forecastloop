defmodule ForecastLoopWeb.PageControllerTest do
  use ForecastLoopWeb.ConnCase

  test "GET / explains the loop and credits the framework's author", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Forecast Integrity Protocol"
    assert html =~ "Peter Rothman"
    assert html =~ "Computational Futurology"
  end
end
