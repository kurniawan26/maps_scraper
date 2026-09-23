defmodule MapsScraper.Failure do
  @moduledoc """
  Menerjemahkan kegagalan internal menjadi bentuk yang bisa dikirim ke pemanggil,
  dan memutuskan mana yang layak diulang.

  Dipakai bersama antrean (`MapsScraper.Validation.Worker`) dan pintu gabungan
  (`MapsScraper.Subject`) supaya satu kode error berarti hal yang sama di mana
  pun ia muncul.
  """

  @doc """
  Apakah kegagalan ini layak diulang.

  Kegagalan sementara layak; kesalahan parameter dan alamat internal tidak akan
  pernah berubah hasilnya betapa pun sering dicoba.
  """
  def retryable?(:timeout), do: true
  def retryable?(:unavailable), do: true
  def retryable?({:crashed, _reason}), do: true
  def retryable?({:scraper, status, _error}) when status >= 500, do: true
  def retryable?(_reason), do: false

  @doc "Apakah kegagalan ini karena sidecar sedang penuh."
  def busy?({:scraper, _status, %{"code" => "busy"}}), do: true
  def busy?(_reason), do: false

  @doc "Bentuk JSON sebuah kegagalan. Kuncinya string karena ikut disimpan sebagai JSON."
  def describe(:timeout), do: %{"code" => "timeout", "message" => "Scraping melebihi batas waktu"}

  def describe(:unavailable),
    do: %{"code" => "scraper_unavailable", "message" => "Sidecar tidak dapat dihubungi"}

  def describe({:crashed, reason}),
    do: %{"code" => "crashed", "message" => "Task berhenti: #{inspect(reason)}"}

  def describe({:scraper, _status, error}),
    do: %{
      "code" => Map.get(error, "code", "scrape_failed"),
      "message" => Map.get(error, "message", "Gagal mengambil data")
    }

  def describe({:invalid, field, message}),
    do: %{"code" => "invalid_params", "field" => field, "message" => message}

  def describe({:blocked, host}),
    do: %{
      "code" => "blocked_address",
      "field" => "query",
      "message" => "#{host} mengarah ke alamat internal"
    }

  def describe(other), do: %{"code" => "unknown", "message" => inspect(other)}
end
