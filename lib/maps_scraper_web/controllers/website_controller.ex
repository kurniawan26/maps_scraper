defmodule MapsScraperWeb.WebsiteController do
  use MapsScraperWeb, :controller

  alias MapsScraper.Website

  action_fallback MapsScraperWeb.FallbackController

  @doc """
  `GET /api/website?query=...` dan `POST /api/website` dengan body JSON.

  Keduanya menerima parameter yang sama dan mengembalikan bentuk JSON yang sama.
  """
  def index(conn, params) do
    with {:ok, payload} <- Website.lookup(params) do
      json(conn, payload)
    end
  end
end
