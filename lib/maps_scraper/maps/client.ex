defmodule MapsScraper.Maps.Client do
  @moduledoc """
  Pembungkus HTTP ke sidecar Playwright.

  Sidecar berjalan sebagai container terpisah (lihat `docker-compose.yml`) dan
  hanya punya satu endpoint, `POST /scrape`, yang menerima query berupa kata
  kunci maupun URL Google Maps.
  """

  require Logger

  @doc """
  Mengirim permintaan scrape ke sidecar.

  Mengembalikan `{:ok, payload}` berisi map hasil sidecar, atau
  `{:error, reason}` dengan `reason` berupa atom yang sudah dipetakan.
  """
  def scrape(query, opts \\ %{}) do
    body = Map.merge(%{query: query}, opts)

    # Timeout HTTP harus lebih longgar dari timeout browser, kalau tidak
    # koneksi putus duluan dan kita kehilangan pesan error aslinya.
    receive_timeout = Map.get(opts, :timeout, config(:timeout)) + 15_000

    options =
      Keyword.merge(
        [json: body, receive_timeout: receive_timeout, retry: false],
        req_options()
      )

    case Req.post(base_url() <> "/scrape", options) do
      {:ok, %Req.Response{status: 200, body: payload}} ->
        {:ok, payload}

      {:ok, %Req.Response{status: status, body: %{"error" => error}}} ->
        {:error, {:scraper, status, error}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:scraper, status, %{"code" => "unknown", "message" => "Sidecar gagal"}}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, exception} ->
        Logger.error("sidecar tidak dapat dihubungi: #{Exception.message(exception)}")
        {:error, :unavailable}
    end
  end

  def health do
    options = Keyword.merge([receive_timeout: 5_000, retry: false], req_options())

    case Req.get(base_url() <> "/health", options) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:scraper, status, %{}}}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp base_url, do: config(:base_url) |> String.trim_trailing("/")

  # Dipakai test untuk menyuntikkan stub Req.Test menggantikan sidecar sungguhan.
  defp req_options do
    :maps_scraper
    |> Application.get_env(:scraper, [])
    |> Keyword.get(:req_options, [])
  end

  defp config(key) do
    :maps_scraper
    |> Application.get_env(:scraper, [])
    |> Keyword.fetch!(key)
  end
end
