defmodule MapsScraper.TikTok.Client do
  @moduledoc """
  Permintaan verifikasi akun TikTok ke sidecar.

  Pengiriman HTTP-nya ditangani `MapsScraper.Scraper.Client`, yang dipakai
  bersama sumber lain.
  """

  alias MapsScraper.Scraper.Client

  @scrape_path "/scrape/tiktok"

  # Satu halaman, satu pembacaan — sama dengan Instagram. Kelonggarannya supaya
  # pesan error sidecar sempat sampai sebelum koneksi diputus.
  @slack_ms 15_000

  def scrape(query, opts \\ %{}) do
    page_timeout = Map.get(opts, :timeout) || config(:timeout, 45_000)
    body = Map.merge(opts, %{query: query, timeout: page_timeout})

    Client.post(@scrape_path, body, page_timeout + @slack_ms)
  end

  defp config(key, default) do
    :maps_scraper
    |> Application.get_env(:tiktok, [])
    |> Keyword.get(key, default)
  end
end
