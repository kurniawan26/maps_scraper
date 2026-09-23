defmodule MapsScraperWeb.Router do
  use MapsScraperWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MapsScraperWeb do
    pipe_through :api

    get "/places", PlaceController, :index
    post "/places", PlaceController, :index

    get "/instagram", InstagramController, :index
    post "/instagram", InstagramController, :index

    post "/validations", ValidationController, :create
    get "/validations", ValidationController, :index
    get "/validations/:id", ValidationController, :show

    get "/health", PlaceController, :health
  end
end
