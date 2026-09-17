defmodule MapsScraper.Validation do
  @moduledoc """
  Validasi massal: mengirim banyak query sekaligus untuk diperiksa
  keberadaannya di Google Maps.

  Pekerjaan sesungguhnya dijalankan `MapsScraper.Validation.Queue`; modul ini
  memvalidasi masukan dari request sebelum masuk antrean.
  """

  alias MapsScraper.Validation.Queue

  @default_max_batch 500
  @query_max_length 512

  @doc """
  Memasukkan batch query ke antrean.

  Params yang dikenali sama dengan `MapsScraper.lookup/1`, ditambah `"queries"`
  berupa daftar string. Opsi (`limit`, `detail`, `lang`, `country`) berlaku untuk
  seluruh baris dalam batch.
  """
  def enqueue(params) when is_map(params) do
    with {:ok, queries} <- fetch_queries(params) do
      Queue.enqueue(queries, Map.take(params, ~w(limit detail lang country)))
    end
  end

  @doc "Mengambil status job. `:error` kalau id-nya tidak dikenal."
  def fetch(job_id) when is_binary(job_id), do: Queue.fetch(job_id)

  def stats, do: Queue.stats()

  def max_batch do
    Application.get_env(:maps_scraper, :validation, [])
    |> Keyword.get(:max_batch, @default_max_batch)
  end

  defp fetch_queries(params) do
    case Map.get(params, "queries") do
      list when is_list(list) -> validate_queries(list)
      nil -> {:error, {:invalid, "queries", "wajib diisi"}}
      _ -> {:error, {:invalid, "queries", "harus berupa daftar"}}
    end
  end

  defp validate_queries([]), do: {:error, {:invalid, "queries", "tidak boleh kosong"}}

  defp validate_queries(list) do
    max = max_batch()

    cond do
      length(list) > max ->
        {:error, {:invalid, "queries", "maksimal #{max} baris per batch"}}

      not Enum.all?(list, &is_binary/1) ->
        {:error, {:invalid, "queries", "semua baris harus berupa teks"}}

      true ->
        trimmed = Enum.map(list, &String.trim/1)

        cond do
          Enum.any?(trimmed, &(&1 == "")) ->
            {:error, {:invalid, "queries", "ada baris yang kosong"}}

          Enum.any?(trimmed, &(byte_size(&1) > @query_max_length)) ->
            {:error, {:invalid, "queries", "ada baris melebihi #{@query_max_length} karakter"}}

          true ->
            {:ok, trimmed}
        end
    end
  end
end
