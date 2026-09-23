defmodule MapsScraper.Validation.Retention do
  @moduledoc """
  Membuang hasil validasi yang sudah lewat masa simpannya.

  Dipanggil dari dua arah, dan keduanya perlu:

    * **saat batch baru masuk** — membersihkan tepat ketika ruang dibutuhkan
    * **terjadwal, sekali sehari** — karena yang pertama tidak pernah jalan
      kalau trafiknya berhenti, dan justru di masa sepi itulah data mengendap
      paling lama

  ## Menghapus baris tidak mengecilkan berkasnya

  SQLite di sini berjalan dengan `auto_vacuum = NONE`, jadi halaman bekas baris
  yang dihapus masuk ke freelist dan dipakai ulang — berkasnya berhenti di
  ukuran tertinggi yang pernah dicapai, tidak pernah menyusut. Satu batch besar
  sekali saja cukup untuk membuatnya besar selamanya.

  Karena itu penyapuan terjadwal diikuti `VACUUM`, yang menulis ulang berkasnya
  tanpa halaman kosong. `VACUUM` mengunci database selama berjalan dan tidak
  boleh berada di dalam transaksi — keduanya alasan ia hanya dijalankan pada
  penyapuan terjadwal, bukan pada tiap batch yang masuk.
  """

  import Ecto.Query

  require Logger

  alias MapsScraper.Repo
  alias MapsScraper.Validation.Batch

  @default_ttl_ms :timer.hours(24)
  @default_max_jobs 1_000

  # Jaring pengaman untuk batch yang tidak pernah selesai — pekerjanya hilang,
  # atau job-nya dibuang Oban sebelum sempat menandai barisnya. Tanpa ini,
  # batch seperti itu tidak pernah memenuhi syarat penghapusan mana pun.
  @abandoned_multiplier 7

  @doc """
  Membuang batch yang kedaluwarsa.

  Mengembalikan jumlah batch yang dihapus. Baris-barisnya ikut terhapus lewat
  `on_delete: :delete_all` pada foreign key.
  """
  def sweep(opts \\ []) do
    ttl_ms = config(:job_ttl_ms, @default_ttl_ms)
    max_jobs = config(:max_jobs, @default_max_jobs)
    headroom = Keyword.get(opts, :headroom, 0)

    expired = delete_expired(ttl_ms)
    abandoned = delete_abandoned(ttl_ms)
    excess = enforce_cap(max_jobs, headroom)

    expired + abandoned + excess
  end

  @doc """
  Menulis ulang berkas database tanpa halaman kosong.

  Tidak boleh dipanggil dari dalam transaksi. Aman kalau gagal — kegagalannya
  berarti ruang disk tidak jadi dikembalikan, bukan data hilang.
  """
  def vacuum do
    {microseconds, hasil} = :timer.tc(fn -> Repo.query("VACUUM") end)

    case hasil do
      {:ok, _} -> {:ok, div(microseconds, 1000)}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Ukuran berkas database dalam byte, dihitung dari halamannya."
  def database_bytes do
    with %{rows: [[pages]]} <- Repo.query!("PRAGMA page_count"),
         %{rows: [[size]]} <- Repo.query!("PRAGMA page_size") do
      pages * size
    end
  end

  # ------------------------------------------------------------------

  defp delete_expired(ttl_ms) when ttl_ms > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_ms, :millisecond)

    {count, _} =
      Repo.delete_all(
        from(b in Batch, where: not is_nil(b.finished_at) and b.finished_at < ^cutoff)
      )

    count
  end

  defp delete_expired(_ttl_ms), do: 0

  defp delete_abandoned(ttl_ms) when ttl_ms > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_ms * @abandoned_multiplier, :millisecond)

    {count, _} =
      Repo.delete_all(from(b in Batch, where: is_nil(b.finished_at) and b.inserted_at < ^cutoff))

    if count > 0 do
      Logger.warning("#{count} batch dibuang karena tidak pernah selesai")
    end

    count
  end

  defp delete_abandoned(_ttl_ms), do: 0

  # Batas keras untuk deret batch yang datang lebih cepat daripada TTL-nya lewat.
  # Yang dibuang selalu batch selesai yang paling tua; batch yang masih berjalan
  # tidak pernah dikorbankan.
  defp enforce_cap(max_jobs, headroom) when max_jobs > 0 do
    excess = Repo.aggregate(Batch, :count) - max_jobs + headroom

    if excess > 0 do
      doomed =
        from(b in Batch,
          where: not is_nil(b.finished_at),
          order_by: [asc: b.finished_at],
          limit: ^excess,
          select: b.id
        )
        |> Repo.all()

      {count, _} = Repo.delete_all(from(b in Batch, where: b.id in ^doomed))
      count
    else
      0
    end
  end

  defp enforce_cap(_max_jobs, _headroom), do: 0

  defp config(key, default) do
    :maps_scraper
    |> Application.get_env(:validation, [])
    |> Keyword.get(key, default)
  end
end
