defmodule MapsScraperWeb.TikTokController do
  use MapsScraperWeb, :controller

  alias MapsScraper.TikTok

  action_fallback MapsScraperWeb.FallbackController

  @doc """
  `GET /api/tiktok?query=...` dan `POST /api/tiktok` dengan body JSON.

  Keduanya menerima parameter yang sama dan mengembalikan bentuk JSON yang sama.
  """
  def index(conn, params) do
    with {:ok, payload} <- TikTok.lookup(params) do
      json(conn, payload)
    end
  end
end
