defmodule MapsScraperWeb.InstagramController do
  use MapsScraperWeb, :controller

  alias MapsScraper.Instagram

  action_fallback MapsScraperWeb.FallbackController

  @doc """
  `GET /api/instagram?query=...` dan `POST /api/instagram` dengan body JSON.

  Keduanya menerima parameter yang sama dan mengembalikan bentuk JSON yang sama.
  """
  def index(conn, params) do
    with {:ok, payload} <- Instagram.lookup(params) do
      json(conn, payload)
    end
  end
end
