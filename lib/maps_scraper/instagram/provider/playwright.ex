defmodule MapsScraper.Instagram.Provider.Playwright do
  @moduledoc """
  Penyedia bawaan: sidecar Playwright milik proyek ini.

  Tidak memerlukan login maupun cookie sesi. Halaman profil publik memang
  menampilkan modal ajakan mendaftar di atas kontennya, tetapi itu hanya lapisan
  — data profilnya tetap ada di DOM.
  """

  @behaviour MapsScraper.Instagram.Provider

  alias MapsScraper.Scraper.Client

  @scrape_path "/scrape/instagram"

  # Tidak ada fase detail seperti pada Maps: seluruh kolom profil datang dari
  # satu halaman yang sama, jadi batas waktunya cukup timeout halaman ditambah
  # kelonggaran supaya pesan error sidecar sempat sampai sebelum koneksi putus.
  @slack_ms 15_000

  @impl true
  def fetch(query, opts) do
    page_timeout = Map.get(opts, :timeout) || config(:timeout, 45_000)
    body = Map.merge(opts, %{query: query, timeout: page_timeout})

    Client.post(@scrape_path, body, page_timeout + @slack_ms)
  end

  defp config(key, default) do
    :maps_scraper
    |> Application.get_env(:instagram, [])
    |> Keyword.get(key, default)
  end
end
