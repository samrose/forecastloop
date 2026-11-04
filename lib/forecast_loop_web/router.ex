defmodule ForecastLoopWeb.Router do
  use ForecastLoopWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ForecastLoopWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ForecastLoopWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/queue", QueueLive
    live "/questions", QuestionsLive
    live "/questions/:id", QuestionLive
    live "/calibration", CalibrationLive
    live "/signals", SignalsLive
    live "/knowledge", KnowledgeLive
    live "/packs", PacksLive
    live "/packs/:name", PackLive
    live "/runs", RunsLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ForecastLoopWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:forecast_loop, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ForecastLoopWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
