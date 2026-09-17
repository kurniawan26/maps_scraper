defmodule MapsScraperWeb.PlaceController do
  use MapsScraperWeb, :controller

  alias MapsScraper.Maps
  alias MapsScraper.Maps.Client

  action_fallback MapsScraperWeb.FallbackController

  @doc """
  `GET /api/places?query=...` dan `POST /api/places` dengan body JSON.

  Keduanya menerima parameter yang sama dan mengembalikan bentuk JSON yang sama.
  """
  def index(conn, params) do
    with {:ok, payload} <- Maps.lookup(params) do
      json(conn, payload)
    end
  end

  def health(conn, _params) do
    case Client.health() do
      {:ok, body} ->
        json(conn, %{status: "ok", scraper: body})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "degraded", scraper: nil})
    end
  end
end
