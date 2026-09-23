defmodule MapsScraper.Marketplace.Client do
  @moduledoc """
  Permintaan verifikasi toko ke sidecar.

  Pengiriman HTTP-nya ditangani `MapsScraper.Scraper.Client`, yang dipakai
  bersama sumber lain.
  """

  alias MapsScraper.Scraper.Client

  @scrape_path "/scrape/marketplace"

  # Shopee dibaca dua kali ketika jawabannya menunjukkan toko tidak ada —
  # konfirmasi yang menjaga gangguan sesaat tidak terbaca sebagai "tidak ada".
  # Kelonggarannya harus menampung dua kali muat halaman.
  @slack_ms 30_000

  def scrape(query, opts \\ %{}) do
    page_timeout = Map.get(opts, :timeout) || config(:timeout, 45_000)
    body = Map.merge(opts, %{query: query, timeout: page_timeout})

    Client.post(@scrape_path, body, page_timeout + @slack_ms)
  end

  defp config(key, default) do
    :maps_scraper
    |> Application.get_env(:marketplace, [])
    |> Keyword.get(key, default)
  end
end
