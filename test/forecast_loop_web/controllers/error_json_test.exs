defmodule ForecastLoopWeb.ErrorJSONTest do
  use ForecastLoopWeb.ConnCase, async: true

  test "renders 404" do
    assert ForecastLoopWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert ForecastLoopWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
