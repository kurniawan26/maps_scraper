defmodule MapsScraper.Apify.Client do
  @moduledoc """
  Menjalankan actor Apify secara sinkron dan mengembalikan isi dataset-nya.

  Memakai `run-sync-get-dataset-items`, yang memotong run di 300 detik.
  """

  require Logger

  @max_sync_seconds 300

  def enabled? do
    config(:enabled, true) and is_binary(config(:token)) and config(:token) != ""
  end

  def run(actor, input, opts \\ []) do
    timeout_s = min(Keyword.get(opts, :timeout_s, config(:timeout_s, 120)), @max_sync_seconds)
    max_charge = Keyword.get(opts, :max_charge_usd, config(:max_charge_usd, 0.5))

    options =
      Keyword.merge(
        [
          json: input,
          auth: {:bearer, config(:token)},
          params: [timeout: timeout_s, maxTotalChargeUsd: max_charge],
          receive_timeout: (timeout_s + 30) * 1000,
          retry: false
        ],
        config(:req_options, [])
      )

    url = "#{base_url()}/v2/acts/#{actor}/run-sync-get-dataset-items"

    case Req.post(url, options) do
      {:ok, %Req.Response{status: status, body: items}}
      when status in [200, 201] and is_list(items) ->
        {:ok, items}

      {:ok, %Req.Response{status: 408}} ->
        failure(408, "apify_timeout", "Run Apify melewati #{timeout_s} detik")

      {:ok, %Req.Response{status: status, body: body}} ->
        failure(status, "apify_http_#{status}", message(body, "Apify menjawab #{status}"))

      {:error, %Req.TransportError{reason: :timeout}} ->
        failure(504, "apify_timeout", "Apify tidak menjawab dalam batas waktu")

      {:error, exception} ->
        Logger.error("apify tidak dapat dihubungi: #{Exception.message(exception)}")
        failure(503, "apify_unavailable", "Apify tidak dapat dihubungi")
    end
  end

  def failure(status, code, message),
    do: {:error, {:apify, status, %{"code" => code, "message" => message}}}

  defp message(%{"error" => %{"message" => message}}, _default) when is_binary(message),
    do: message

  defp message(_body, default), do: default

  defp base_url, do: config(:base_url, "https://api.apify.com") |> String.trim_trailing("/")

  defp config(key, default \\ nil) do
    :maps_scraper
    |> Application.get_env(:apify, [])
    |> Keyword.get(key, default)
  end
end
