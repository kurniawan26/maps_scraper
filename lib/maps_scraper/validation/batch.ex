defmodule MapsScraper.Validation.Batch do
  @moduledoc """
  Satu batch validasi beserta status tiap barisnya.

  Dulu struktur ini hidup di memori sebuah GenServer dan ikut hilang setiap
  aplikasi di-restart. Sekarang tersimpan di SQLite, jadi batch yang sedang
  berjalan saat deploy dilanjutkan, bukan dibuang.
  """

  use Ecto.Schema

  alias MapsScraper.Validation.Batch
  alias MapsScraper.Validation.Row

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "validation_batches" do
    field(:source, :string)
    field(:opts, :map, default: %{})
    field(:total, :integer)
    field(:finished_at, :utc_datetime_usec)

    has_many(:rows, Row, foreign_key: :batch_id, preload_order: [asc: :index])

    timestamps()
  end

  @doc "Id acak yang cukup pendek untuk disalin, cukup panjang untuk tidak ditebak."
  def generate_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc "Batch selesai ketika tidak ada lagi baris yang menunggu atau sedang berjalan."
  def settled?(%Batch{rows: rows}) when is_list(rows) do
    Enum.all?(rows, &(&1.status in ["ok", "error"]))
  end

  def counts(%Batch{rows: rows}) do
    Enum.reduce(rows, %{pending: 0, running: 0, ok: 0, error: 0}, fn row, acc ->
      Map.update!(acc, String.to_existing_atom(row.status), &(&1 + 1))
    end)
  end

  @doc """
  Rekap vonis seluruh baris.

  `match` sudah cukup meyakinkan tanpa penilaian lanjutan, `review` perlu
  dinilai di luar service ini, `no_match` tidak punya kandidat yang layak
  dinilai. Baris yang gagal di-scrape tidak masuk hitungan mana pun; lihat
  `counts/1` untuk itu.
  """
  def verdicts(%Batch{rows: rows}) do
    Enum.reduce(rows, %{match: 0, review: 0, no_match: 0}, fn row, acc ->
      case row do
        %Row{status: "ok", result: %{"verdict" => verdict}}
        when verdict in ["match", "review", "no_match"] ->
          Map.update!(acc, String.to_existing_atom(verdict), &(&1 + 1))

        _ ->
          acc
      end
    end)
  end

  @doc """
  Bentuk JSON sebuah batch.

  Sengaja identik dengan bentuk yang disajikan antrean in-memory sebelumnya —
  pemanggil yang sudah ada (n8n, skrip) tidak perlu diubah.
  """
  def to_map(%Batch{} = batch) do
    %{
      job_id: batch.id,
      source: batch.source,
      status: if(batch.finished_at, do: :done, else: :running),
      total: batch.total,
      counts: counts(batch),
      verdicts: verdicts(batch),
      inserted_at: batch.inserted_at,
      finished_at: batch.finished_at,
      results: Enum.map(batch.rows, &Row.to_map/1)
    }
  end
end
