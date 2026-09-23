defmodule MapsScraper.Validation.Cleaner do
  @moduledoc """
  Penyapuan terjadwal hasil validasi.

  Dijalankan `Oban.Plugins.Cron` sekali sehari. Tanpa ini, pembersihan hanya
  terjadi ketika batch baru masuk — dan justru pada masa sepi, saat tidak ada
  batch masuk sama sekali, data mengendap paling lama.

  Sesudah menghapus, berkasnya di-`VACUUM` supaya ruang disknya benar-benar
  kembali. Lihat `MapsScraper.Validation.Retention` untuk alasannya.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias MapsScraper.Validation.Retention

  @impl Oban.Worker
  def perform(_job) do
    sebelum = Retention.database_bytes()
    dihapus = Retention.sweep()

    # VACUUM mengunci database, jadi hanya dijalankan kalau memang ada yang
    # dihapus — menulis ulang berkas yang tidak berubah cuma membuang kunci.
    hasil = if dihapus > 0, do: Retention.vacuum(), else: {:ok, 0}

    sesudah = Retention.database_bytes()

    case hasil do
      {:ok, ms} ->
        Logger.info(
          "penyapuan: #{dihapus} batch dibuang, berkas #{mb(sebelum)} -> #{mb(sesudah)} " <>
            "(vacuum #{ms} ms)"
        )

      {:error, error} ->
        # Ruang disk tidak jadi kembali, tetapi datanya sudah terhapus. Bukan
        # alasan menggagalkan job.
        Logger.warning("penyapuan: #{dihapus} batch dibuang, vacuum gagal: #{inspect(error)}")
    end

    :ok
  end

  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 2)} MB"
end
