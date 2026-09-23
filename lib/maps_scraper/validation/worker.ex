defmodule MapsScraper.Validation.Worker do
  @moduledoc """
  Mengerjakan satu baris validasi.

  Satu baris = satu job Oban. Pembagian tanggung jawabnya: Oban memegang
  penjadwalan, retry, backoff, dan ketahanan terhadap restart; modul ini
  memutuskan bagaimana sebuah kegagalan harus diperlakukan.

  ## Tiga perlakuan terhadap kegagalan

    * **`{:snooze, _}`** — sidecar penuh (`busy`). Ini tekanan balik yang kita
      timbulkan sendiri, bukan masalah pada datanya. Oban mengembalikan hitungan
      percobaan saat job di-snooze, jadi kemacetan tidak pernah menghabiskan
      jatah retry milik kegagalan yang sesungguhnya. Inilah yang dulu membuat
      baris sehat divonis gagal ketika antrean menuntut lebih dari kapasitas
      sidecar.

    * **`{:error, _}`** — kegagalan sementara (timeout, sidecar mati, 5xx).
      Diulang dengan backoff sampai jatahnya habis.

    * **`{:cancel, _}`** — kegagalan permanen (parameter tidak valid, alamat
      internal). Mengulanginya tidak akan mengubah hasilnya.
  """

  use Oban.Worker, queue: :validation, max_attempts: 3

  import Ecto.Query

  alias MapsScraper.Failure
  alias MapsScraper.Repo
  alias MapsScraper.Validation.Batch
  alias MapsScraper.Validation.Row
  alias MapsScraper.Validation.Verdict

  # Sidecar mengirim `Retry-After: 5` saat penuh; angkanya disamakan.
  @busy_snooze_seconds 5

  @doc """
  Jeda sebelum percobaan ulang.

  Oban punya backoff-nya sendiri, tapi setelan `VALIDATION_BACKOFF_MS` dan
  `VALIDATION_MAX_BACKOFF_MS` sudah dipakai di deployment yang ada — jadi yang
  dihormati tetap keduanya. Satuan Oban adalah detik, dengan minimum 1.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    config = Application.get_env(:maps_scraper, :validation, [])
    base = Keyword.get(config, :backoff_ms, 1_000)
    ceiling = Keyword.get(config, :max_backoff_ms, 30_000)

    delay = min(trunc(base * :math.pow(2, attempt - 1)), ceiling)
    jitter = :rand.uniform(max(div(delay, 4), 1))

    max(div(delay + jitter, 1_000), 1)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    %{"batch_id" => batch_id, "index" => index} = args

    case load(batch_id, index) do
      # Batch-nya sudah dibuang sementara job masih mengantre. Bukan kegagalan;
      # tidak ada lagi yang perlu dikerjakan.
      nil -> :ok
      {row, batch} -> run(row, batch, attempt, max_attempts)
    end
  end

  defp load(batch_id, index) do
    case Repo.get_by(Row, batch_id: batch_id, index: index) do
      nil -> nil
      row -> {row, Repo.get(Batch, batch_id)}
    end
  end

  defp run(row, batch, attempt, max_attempts) do
    mark(row, status: "running", attempts: attempt)

    params = Map.merge(batch.opts, %{"query" => row.query, "source" => batch.source})

    case call(lookup(batch.source), params) do
      {:ok, payload} ->
        settle(row, batch,
          status: "ok",
          result: Verdict.summarize(payload, batch.source),
          error: nil
        )

        :ok

      {:error, reason} ->
        fail(row, batch, reason, attempt, max_attempts)
    end
  end

  defp fail(row, batch, reason, attempt, max_attempts) do
    cond do
      Failure.busy?(reason) ->
        # Barisnya dikembalikan ke status menunggu, bukan ditandai gagal.
        mark(row, status: "pending", error: Failure.describe(reason))
        {:snooze, @busy_snooze_seconds}

      Failure.retryable?(reason) and attempt < max_attempts ->
        mark(row, status: "pending", error: Failure.describe(reason))
        {:error, reason}

      true ->
        settle(row, batch, status: "error", error: Failure.describe(reason))
        {:cancel, Failure.describe(reason)["message"]}
    end
  end

  # Context yang meledak tidak boleh meninggalkan barisnya berstatus "running"
  # selamanya. Tanpa penangkapan ini, job yang mati membuat batch-nya tidak
  # pernah ditutup — Oban memang mengulang job-nya, tetapi kode yang menandai
  # barisnya tidak pernah sempat jalan.
  defp call(lookup, params) do
    lookup.lookup(params)
  catch
    kind, reason -> {:error, {:crashed, {kind, reason}}}
  end

  # ------------------------------------------------------------------
  # Penyimpanan
  # ------------------------------------------------------------------

  defp mark(row, fields) do
    fields = Keyword.put(fields, :updated_at, DateTime.utc_now())

    Repo.update_all(from(r in Row, where: r.id == ^row.id), set: fields)
  end

  # Baris yang sudah selesai bisa jadi yang terakhir; batch-nya ditutup pada
  # transaksi yang sama supaya `finished_at` tidak pernah tertinggal.
  defp settle(row, batch, fields) do
    Repo.transaction(fn ->
      mark(row, fields)
      close_if_settled(batch)
    end)
  end

  defp close_if_settled(%Batch{finished_at: nil} = batch) do
    unsettled =
      Repo.aggregate(
        from(r in Row, where: r.batch_id == ^batch.id and r.status not in ["ok", "error"]),
        :count
      )

    if unsettled == 0 do
      Repo.update_all(
        from(b in Batch, where: b.id == ^batch.id and is_nil(b.finished_at)),
        set: [finished_at: DateTime.utc_now()]
      )
    end
  end

  defp close_if_settled(_batch), do: :ok

  defp lookup(source) do
    config = Application.get_env(:maps_scraper, :validation, [])

    # `:lookup` menimpa seluruh sumber sekaligus — dipakai test untuk mengganti
    # seluruh jalur scraping dengan satu stub.
    config[:lookup] || Map.fetch!(MapsScraper.Validation.sources(), source)
  end
end
