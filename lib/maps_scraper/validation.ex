defmodule MapsScraper.Validation do
  @moduledoc """
  Validasi massal: mengirim banyak query sekaligus untuk diperiksa
  keberadaannya.

  Satu batch memeriksa satu sumber, dipilih lewat `"source"`. Mencampur sumber
  dalam satu batch sengaja tidak didukung: opsi tiap sumber berbeda, dan yang
  memanggil endpoint ini biasanya sedang memeriksa satu kolom dari satu tabel.

  Pekerjaan sesungguhnya dijalankan `MapsScraper.Validation.Queue`; modul ini
  memvalidasi masukan dari request sebelum masuk antrean.
  """

  alias MapsScraper.Instagram
  alias MapsScraper.Maps
  alias MapsScraper.Validation.Queue

  @default_max_batch 500
  @query_max_length 512

  @default_source "maps"

  @sources %{"maps" => Maps, "instagram" => Instagram}

  # Opsi yang boleh diteruskan ke antrean, per sumber. Disaring di sini supaya
  # kolom asing dari body request tidak ikut tersimpan di dalam job.
  @option_keys %{
    "maps" => ~w(limit detail lang country),
    "instagram" => ~w(lang country name)
  }

  @doc """
  Memasukkan batch query ke antrean.

  Params yang dikenali sama dengan `lookup/1` milik context sumbernya, ditambah:

    * `"queries"` — daftar string, wajib
    * `"source"` — `"maps"` (default) atau `"instagram"`

  Opsi berlaku untuk seluruh baris dalam batch.
  """
  def enqueue(params) when is_map(params) do
    # Sumber, baris, dan opsi divalidasi di sini, bukan hanya saat tiap baris
    # dikerjakan. Tanpa ini `{"queries": [...], "limit": "abc"}` dijawab 202
    # lebih dulu, lalu seluruh barisnya gagal satu per satu — klien baru tahu
    # batch-nya sia-sia setelah polling.
    with {:ok, source} <- fetch_source(params),
         {:ok, queries} <- fetch_queries(params, source),
         {:ok, _opts} <- context(source).validate_options(params) do
      opts =
        params
        |> Map.take(Map.fetch!(@option_keys, source))
        |> Map.put("source", source)

      Queue.enqueue(queries, opts)
    end
  end

  @doc "Mengambil status job. `:error` kalau id-nya tidak dikenal."
  def fetch(job_id) when is_binary(job_id), do: Queue.fetch(job_id)

  def stats, do: Queue.stats()

  @doc "Daftar sumber yang dikenali, dipetakan ke context-nya."
  def sources, do: @sources

  def max_batch do
    Application.get_env(:maps_scraper, :validation, [])
    |> Keyword.get(:max_batch, @default_max_batch)
  end

  defp context(source), do: Map.fetch!(@sources, source)

  defp fetch_source(params) do
    case Map.get(params, "source") do
      nil ->
        {:ok, @default_source}

      value when is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()

        cond do
          normalized == "" -> {:ok, @default_source}
          Map.has_key?(@sources, normalized) -> {:ok, normalized}
          true -> {:error, {:invalid, "source", "harus salah satu dari: #{known_sources()}"}}
        end

      _ ->
        {:error, {:invalid, "source", "harus berupa teks"}}
    end
  end

  defp known_sources, do: @sources |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp fetch_queries(params, source) do
    case Map.get(params, "queries") do
      list when is_list(list) -> validate_queries(list, source)
      nil -> {:error, {:invalid, "queries", "wajib diisi"}}
      _ -> {:error, {:invalid, "queries", "harus berupa daftar"}}
    end
  end

  defp validate_queries([], _source), do: {:error, {:invalid, "queries", "tidak boleh kosong"}}

  defp validate_queries(list, source) do
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
            validate_rows(trimmed, source)
        end
    end
  end

  # Instagram menunjuk satu akun secara pasti, jadi baris yang bukan username
  # maupun URL profil tidak akan pernah berhasil betapa pun sering diulang.
  # Menolaknya sekarang lebih baik daripada memulangkannya satu per satu
  # sebagai kegagalan permanen setelah klien mengira batch-nya diterima.
  defp validate_rows(queries, "instagram") do
    case Enum.find(queries, &match?({:error, _}, Instagram.normalize_username(&1))) do
      nil -> {:ok, queries}
      invalid -> {:error, {:invalid, "queries", "#{inspect(invalid)} bukan akun Instagram"}}
    end
  end

  defp validate_rows(queries, _source), do: {:ok, queries}
end
