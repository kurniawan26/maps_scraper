defmodule MapsScraper.Scraper.Client do
  @moduledoc """
  Pembungkus HTTP ke sidecar Playwright.

  Sidecar berjalan sebagai container terpisah (lihat `docker-compose.yml`) dan
  melayani satu endpoint per sumber data: `POST /scrape` untuk Google Maps,
  `POST /scrape/instagram` untuk profil Instagram. Keduanya berbagi browser,
  batas concurrency, dan bentuk error yang sama — karena itu berbagi klien ini
  juga. Yang berbeda hanya isi body dan berapa lama jawabannya ditunggu, dan itu
  ditentukan pemanggil.
  """

  require Logger

  @doc """
  Mengirim permintaan scrape ke sidecar.

  Mengembalikan `{:ok, payload}` berisi map hasil sidecar, atau
  `{:error, reason}` dengan `reason` berupa atom yang sudah dipetakan.
  """
  def post(path, body, receive_timeout) do
    options =
      Keyword.merge(
        [json: body, receive_timeout: receive_timeout, retry: false],
        req_options()
      )

    case Req.post(base_url() <> path, options) do
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
