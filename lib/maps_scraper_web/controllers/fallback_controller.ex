defmodule MapsScraperWeb.FallbackController do
  @moduledoc """
  Menerjemahkan tuple error dari context menjadi response JSON.
  """
  use MapsScraperWeb, :controller

  # Parameter request tidak lolos validasi.
  def call(conn, {:error, {:invalid, field, message}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_params", field: field, message: message}})
  end

  # Sidecar menjawab, tapi dengan error — teruskan status dan pesannya apa adanya.
  def call(conn, {:error, {:scraper, status, error}}) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: Map.get(error, "code", "scrape_failed"),
        message: Map.get(error, "message", "Gagal mengambil data dari Google Maps")
      }
    })
  end

  def call(conn, {:error, :timeout}) do
    conn
    |> put_status(:gateway_timeout)
    |> json(%{
      error: %{code: "timeout", message: "Scraping melebihi batas waktu, coba persempit query"}
    })
  end

  def call(conn, {:error, :unavailable}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        code: "scraper_unavailable",
        message:
          "Layanan scraper tidak dapat dihubungi. Pastikan `docker compose up` sudah jalan."
      }
    })
  end
end
