defmodule MapsScraper.Maps.Client do
  @moduledoc """
  Permintaan scrape Google Maps ke sidecar.

  Pengiriman HTTP-nya sendiri ditangani `MapsScraper.Scraper.Client`, yang
  dipakai bersama sumber data lain. Yang tinggal di sini adalah yang khas Maps:
  bagaimana batas waktu HTTP dihitung ketika `detail: true` membuat satu
  permintaan membuka banyak halaman.
  """

  alias MapsScraper.Scraper.Client

  @scrape_path "/scrape"

  @doc """
  Mengirim permintaan scrape ke sidecar.

  Mengembalikan `{:ok, payload}` berisi map hasil sidecar, atau
  `{:error, reason}` dengan `reason` berupa atom yang sudah dipetakan.
  """
  def scrape(query, opts \\ %{}) do
    page_timeout = Map.get(opts, :timeout, config(:timeout))

    # Timeout dikirim eksplisit, bukan dibiarkan sidecar memakai bawaannya —
    # kalau tidak, kedua sisi memegang angka sendiri-sendiri.
    body = Map.merge(opts, %{query: query, timeout: page_timeout})

    Client.post(@scrape_path, body, receive_timeout(opts, page_timeout))
  end

  defdelegate health, to: Client

  # Timeout HTTP harus lebih longgar dari yang dipakai browser, kalau tidak
  # koneksi putus duluan dan pesan error aslinya hilang.
  #
  # `timeout` di sidecar berlaku per halaman, bukan per permintaan. Dengan
  # `detail: true` sidecar membuka tiap hasil satu per satu, jadi lamanya
  # bertambah sebesar anggaran fase detail — angka yang sama dengan
  # DETAIL_BUDGET_MS di sidecar. Tanpa memperhitungkannya, permintaan detail
  # selalu diputus dari sisi sini padahal sidecar masih bekerja.
  defp receive_timeout(opts, page_timeout) do
    detail_budget =
      if Map.get(opts, :detail, false), do: config(:detail_budget_ms, 60_000), else: 0

    page_timeout + detail_budget + 15_000
  end

  defp config(key) do
    :maps_scraper
    |> Application.get_env(:scraper, [])
    |> Keyword.fetch!(key)
  end

  defp config(key, default) do
    :maps_scraper
    |> Application.get_env(:scraper, [])
    |> Keyword.get(key, default)
  end
end
