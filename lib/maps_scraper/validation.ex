defmodule MapsScraper.Validation do
  @moduledoc """
  Validasi massal: mengirim banyak query sekaligus untuk diperiksa
  keberadaannya.

  Satu batch memeriksa satu sumber, dipilih lewat `"source"`. Mencampur sumber
  dalam satu batch sengaja tidak didukung: opsi tiap sumber berbeda, dan yang
  memanggil endpoint ini biasanya sedang memeriksa satu kolom dari satu tabel.

  Pekerjaan sesungguhnya dijalankan `MapsScraper.Validation.Worker` di atas
  Oban; modul ini memvalidasi masukan dari request sebelum masuk antrean.

  ## Kenapa Oban, bukan GenServer

  Versi sebelumnya menahan seluruh batch di memori sebuah GenServer. Dua
  akibatnya: batch yang sedang berjalan hilang setiap aplikasi di-restart, dan
  baris yang kebetulan bertemu sidecar penuh (`busy`) menghabiskan jatah
  retry-nya lalu divonis gagal — padahal datanya tidak bermasalah. Keduanya
  hilang dengan antrean yang persisten dan bisa menunda job tanpa menghitungnya
  sebagai percobaan.
  """

  import Ecto.Query

  alias MapsScraper.Instagram
  alias MapsScraper.Maps
  alias MapsScraper.Marketplace
  alias MapsScraper.Repo
  alias MapsScraper.Validation.Batch
  alias MapsScraper.Validation.Retention
  alias MapsScraper.Validation.Row
  alias MapsScraper.Validation.Worker
  alias MapsScraper.Website

  @default_max_batch 500
  @query_max_length 512

  @default_source "maps"

  @sources %{
    "maps" => Maps,
    "instagram" => Instagram,
    "website" => Website,
    "marketplace" => Marketplace
  }

  # Opsi yang boleh diteruskan ke antrean, per sumber. Disaring di sini supaya
  # kolom asing dari body request tidak ikut tersimpan.
  @option_keys %{
    "maps" => ~w(limit detail lang country name),
    "instagram" => ~w(lang country name),
    "website" => ~w(lang country name),
    "marketplace" => ~w(lang country name)
  }

  @doc """
  Memasukkan batch query ke antrean.

  Params yang dikenali sama dengan `lookup/1` milik context sumbernya, ditambah:

    * `"queries"` — daftar string, wajib
    * `"source"` — `"maps"` (default), `"instagram"`, atau `"website"`

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
      opts = Map.take(params, Map.fetch!(@option_keys, source))

      insert_batch(source, queries, opts)
    end
  end

  @doc "Mengambil status batch. `:error` kalau id-nya tidak dikenal."
  def fetch(batch_id) when is_binary(batch_id) do
    case Repo.get(Batch, batch_id) do
      nil -> :error
      batch -> {:ok, Repo.preload(batch, :rows)}
    end
  end

  @doc "Ringkasan antrean."
  def stats do
    row_counts =
      Repo.all(from(r in Row, group_by: r.status, select: {r.status, count(r.id)}))
      |> Map.new()

    %{
      jobs: Repo.aggregate(Batch, :count),
      pending: Map.get(row_counts, "pending", 0),
      running: Map.get(row_counts, "running", 0),
      concurrency: concurrency(),
      max_attempts: max_attempts()
    }
  end

  @doc "Daftar sumber yang dikenali, dipetakan ke context-nya."
  def sources, do: @sources

  def max_batch, do: validation_config(:max_batch, @default_max_batch)

  def max_attempts, do: validation_config(:max_attempts, 3)

  def concurrency do
    :maps_scraper
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> Keyword.get(:validation, 0)
  end

  # ------------------------------------------------------------------
  # Penyimpanan
  # ------------------------------------------------------------------

  defp insert_batch(source, queries, opts) do
    now = DateTime.utc_now()
    id = Batch.generate_id()

    rows =
      queries
      |> Enum.with_index()
      |> Enum.map(fn {query, index} ->
        %{
          batch_id: id,
          index: index,
          query: query,
          status: "pending",
          attempts: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    jobs =
      Enum.map(rows, fn row ->
        Worker.new(%{batch_id: id, index: row.index}, max_attempts: max_attempts())
      end)

    {:ok, batch} =
      Repo.transaction(fn ->
        # headroom: 1 menyediakan tempat untuk batch yang sedang dimasukkan ini.
        Retention.sweep(headroom: 1)

        batch =
          Repo.insert!(%Batch{
            id: id,
            source: source,
            opts: opts,
            total: length(queries),
            inserted_at: now
          })

        Repo.insert_all(Row, rows)
        Oban.insert_all(jobs)

        Repo.preload(batch, :rows)
      end)

    {:ok, batch}
  end

  # ------------------------------------------------------------------
  # Validasi masukan
  # ------------------------------------------------------------------

  defp context(source), do: Map.fetch!(@sources, source)

  defp validation_config(key, default) do
    :maps_scraper
    |> Application.get_env(:validation, [])
    |> Keyword.get(key, default)
  end

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

  # Sama alasannya, ditambah satu: baris yang menunjuk alamat internal ditolak
  # sekarang, bukan setelah 500 baris terlanjur masuk antrean.
  defp validate_rows(queries, "website") do
    Enum.reduce_while(queries, {:ok, queries}, fn query, acc ->
      case Website.normalize_url(query) do
        {:ok, uri} ->
          case Website.ensure_public(uri) do
            :ok ->
              {:cont, acc}

            {:error, {:blocked, host}} ->
              {:halt, {:error, {:invalid, "queries", "#{host} mengarah ke alamat internal"}}}
          end

        {:error, _reason} ->
          {:halt, {:error, {:invalid, "queries", "#{inspect(query)} bukan URL maupun domain"}}}
      end
    end)
  end

  # Nama toko telanjang ambigu — "samsung" ada di kedua platform sebagai toko
  # yang berbeda — jadi baris wajib menyebut host, dan yang tidak menyebutnya
  # ditolak sekarang, bukan setelah batch terlanjur diterima.
  defp validate_rows(queries, "marketplace") do
    case Enum.find(queries, &match?({:error, _}, Marketplace.normalize_store(&1))) do
      nil -> {:ok, queries}
      invalid -> {:error, {:invalid, "queries", "#{inspect(invalid)} bukan URL toko"}}
    end
  end

  defp validate_rows(queries, _source), do: {:ok, queries}
end
