defmodule MapsScraper.Website.Client do
  @moduledoc """
  Permintaan verifikasi halaman web ke sidecar.

  Pengiriman HTTP-nya ditangani `MapsScraper.Scraper.Client`, yang dipakai
  bersama sumber lain.
  """

  alias MapsScraper.Scraper.Client

  @scrape_path "/scrape/website"

  # Sidecar menyelesaikan rantai pengalihan lebih dulu di luar browser, jadi
  # satu permintaan bisa berisi beberapa lompatan sebelum halamannya dibuka.
  # Kelonggarannya lebih besar daripada Instagram karena itu.
  @slack_ms 20_000

  def scrape(query, opts \\ %{}) do
    page_timeout = Map.get(opts, :timeout) || config(:timeout, 45_000)
    body = Map.merge(opts, %{query: query, timeout: page_timeout})

    Client.post(@scrape_path, body, page_timeout + @slack_ms)
  end

  defp config(key, default) do
    :maps_scraper
    |> Application.get_env(:website, [])
    |> Keyword.get(key, default)
  end
end
