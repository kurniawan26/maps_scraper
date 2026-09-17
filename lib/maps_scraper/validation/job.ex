defmodule MapsScraper.Validation.Job do
  @moduledoc """
  Satu batch validasi beserta status tiap barisnya.

  Struktur ini murni data — seluruh perubahan status dilakukan
  `MapsScraper.Validation.Queue`, dan hanya di dalam proses GenServer-nya.
  """

  alias MapsScraper.Validation.Job

  @enforce_keys [:id, :queries, :opts, :items, :inserted_at]
  defstruct [:id, :queries, :opts, :items, :inserted_at, :finished_at, status: :queued]

  @type item_status :: :pending | :running | :ok | :error
  @type t :: %Job{}

  @doc "Membuat job baru dengan semua baris berstatus `:pending`."
  def new(queries, opts) do
    items =
      queries
      |> Enum.with_index()
      |> Map.new(fn {query, index} ->
        {index, %{query: query, status: :pending, attempts: 0, result: nil, error: nil}}
      end)

    %Job{
      id: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      queries: queries,
      opts: opts,
      items: items,
      inserted_at: DateTime.utc_now(),
      status: :queued
    }
  end

  def get_item(%Job{items: items}, index), do: Map.fetch!(items, index)

  def update_item(%Job{items: items} = job, index, fun) do
    %{job | items: Map.update!(items, index, fun)}
  end

  @doc "Job selesai ketika tidak ada lagi baris yang menunggu atau sedang berjalan."
  def settled?(%Job{items: items}) do
    Enum.all?(items, fn {_index, item} -> item.status in [:ok, :error] end)
  end

  def counts(%Job{items: items}) do
    Enum.reduce(items, %{pending: 0, running: 0, ok: 0, error: 0}, fn {_index, item}, acc ->
      Map.update!(acc, item.status, &(&1 + 1))
    end)
  end

  @doc """
  Bentuk JSON sebuah job.

  Baris yang sudah selesai hanya membawa jawaban validasinya — `found`,
  `best_match`, dan satu tempat teratas. Daftar lengkap tiap query bukan tujuan
  endpoint massal ini; untuk itu gunakan `/api/places`.
  """
  def to_map(%Job{} = job) do
    counts = counts(job)

    %{
      job_id: job.id,
      status: job.status,
      total: map_size(job.items),
      counts: counts,
      valid_count: count_valid(job),
      inserted_at: job.inserted_at,
      finished_at: job.finished_at,
      results:
        job.items
        |> Enum.sort_by(fn {index, _item} -> index end)
        |> Enum.map(fn {index, item} -> item_to_map(index, item) end)
    }
  end

  defp item_to_map(index, item) do
    base = %{
      index: index,
      query: item.query,
      status: item.status,
      attempts: item.attempts
    }

    case item do
      %{status: :ok, result: result} ->
        Map.merge(base, result)

      %{status: :error, error: error} ->
        Map.put(base, :error, error)

      # Baris yang sedang menunggu giliran ulang membawa penyebab kegagalan
      # terakhirnya, supaya yang memantau tahu kenapa job belum selesai.
      %{error: error} when not is_nil(error) ->
        Map.put(base, :last_error, error)

      _ ->
        base
    end
  end

  # "Valid" di sini berarti Google mengembalikan tempat DAN hasilnya benar-benar
  # cocok dengan query. Lihat catatan best_match di README.
  defp count_valid(%Job{items: items}) do
    Enum.count(items, fn {_index, item} ->
      match?(%{status: :ok, result: %{found: true}}, item) and valid_match?(item.result)
    end)
  end

  defp valid_match?(%{best_match: nil}), do: true
  defp valid_match?(%{best_match: score}) when is_number(score), do: score >= 0.5
  defp valid_match?(_), do: false
end
