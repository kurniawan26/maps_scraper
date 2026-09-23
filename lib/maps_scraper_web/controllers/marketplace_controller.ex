defmodule MapsScraperWeb.MarketplaceController do
  use MapsScraperWeb, :controller

  alias MapsScraper.Marketplace

  action_fallback MapsScraperWeb.FallbackController

  @doc """
  `GET /api/marketplace?query=...` dan `POST /api/marketplace` dengan body JSON.

  Keduanya menerima parameter yang sama dan mengembalikan bentuk JSON yang sama.
  """
  def index(conn, params) do
    with {:ok, payload} <- Marketplace.lookup(params) do
      json(conn, payload)
    end
  end
end
