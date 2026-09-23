defmodule MapsScraper.Validation.Row do
  @moduledoc """
  Satu query di dalam batch, beserta hasil atau kegagalannya.

  Satu baris di sini setara satu job Oban. Pemisahan itu disengaja: retry,
  backoff, dan penjadwalan ulang adalah urusan Oban, sedangkan tabel ini yang
  menyimpan jawaban yang dibaca pemanggil lewat API.
  """

  use Ecto.Schema

  alias MapsScraper.Validation.Batch
  alias MapsScraper.Validation.Row

  @timestamps_opts [type: :utc_datetime_usec]

  schema "validation_rows" do
    belongs_to(:batch, Batch, type: :string)
    field(:index, :integer)
    field(:query, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:result, :map)
    field(:error, :map)

    timestamps()
  end

  def to_map(%Row{} = row) do
    base = %{
      index: row.index,
      query: row.query,
      status: String.to_existing_atom(row.status),
      attempts: row.attempts
    }

    case row do
      %Row{status: "ok", result: result} when is_map(result) ->
        Map.merge(base, atomize_result(result))

      %Row{status: "error", error: error} when is_map(error) ->
        Map.put(base, :error, atomize(error))

      # Baris yang sedang menunggu giliran ulang membawa penyebab kegagalan
      # terakhirnya, supaya yang memantau tahu kenapa batch belum selesai.
      %Row{error: error} when is_map(error) ->
        Map.put(base, :last_error, atomize(error))

      _ ->
        base
    end
  end

  # Hasil disimpan sebagai JSON, jadi kuncinya kembali sebagai string. Dikembalikan
  # ke atom di sini supaya bentuk response-nya persis sama dengan sebelumnya.
  defp atomize_result(result) do
    %{
      found: result["found"],
      best_match: result["best_match"],
      verdict: to_atom(result["verdict"]),
      type: result["type"],
      input_type: result["input_type"],
      count: result["count"],
      candidates: Enum.map(result["candidates"] || [], &atomize/1)
    }
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp to_atom(nil), do: nil
  defp to_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
