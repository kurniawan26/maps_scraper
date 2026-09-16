defmodule MapsScraperWeb.PageController do
  use MapsScraperWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
