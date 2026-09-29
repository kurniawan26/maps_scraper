defmodule MapsScraper.Fallback do
  @moduledoc """
  Mengalihkan permintaan ke Apify ketika sidecar diblokir target.

  Hanya kode "diblokir/tidak terbaca" milik sumbernya yang memicu fallback.
  `busy`, timeout, dan sidecar mati tidak — itu masalah kapasitas atau
  infrastruktur kita, bukan IP yang diblokir.

  Kalau Apify juga gagal, galat asli sidecar yang dikembalikan, ditambah
  `fallback_error`, supaya kegagalannya tetap diulang antrean.
  """

  require Logger

  alias MapsScraper.Apify.Client
  alias MapsScraper.Failure

  @triggers %{
    instagram: ~w(instagram_blocked instagram_unreadable),
    tiktok: ~w(tiktok_blocked tiktok_unreadable),
    maps: ~w(maps_blocked maps_unreadable)
  }

  def triggers, do: @triggers

  def run(source, primary, fallback) when is_function(primary, 0) and is_function(fallback, 0) do
    case primary.() do
      {:ok, payload} ->
        {:ok, Map.put_new(payload, "provider", "sidecar")}

      {:error, {:scraper, _status, %{"code" => code}} = reason} = error ->
        if code in Map.fetch!(@triggers, source) and Client.enabled?() do
          attempt(source, code, reason, fallback)
        else
          error
        end

      error ->
        error
    end
  end

  defp attempt(source, code, {:scraper, status, detail}, fallback) do
    Logger.info("fallback #{source}: sidecar menjawab #{code}, beralih ke Apify")

    case fallback.() do
      {:ok, payload} ->
        {:ok, payload |> Map.put("provider", "apify") |> Map.put("fallback_from", code)}

      {:error, reason} ->
        Logger.warning("fallback #{source} gagal: #{inspect(reason)}")
        {:error, {:scraper, status, Map.put(detail, "fallback_error", Failure.describe(reason))}}
    end
  end
end
