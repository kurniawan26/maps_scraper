defmodule MapsScraper.Release do
  @moduledoc """
  Tugas yang dijalankan di dalam OTP release, tempat Mix tidak tersedia.

  Migrasi dijalankan otomatis saat aplikasi start (lihat `:auto_migrate` pada
  `config/prod.exs`). Untuk deployment satu node dengan SQLite itu pilihan yang
  tepat: tidak ada langkah terpisah yang bisa terlupa, dan tidak ada dua
  instance yang mungkin bermigrasi bersamaan.
  """

  @app :maps_scraper

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Mengembalikan job yang tertinggal berstatus `executing` ke antrean.

  Saat aplikasi mati mendadak — OOM, SIGKILL, mesin padam — job yang sedang
  dikerjakan tertinggal di keadaan itu. `Oban.Plugins.Lifeline` memang
  membebaskannya, tetapi baru setelah `rescue_after` lewat; selama itu barisnya
  menggantung tanpa dikerjakan siapa pun.

  Di sini hal itu tidak perlu ditunggu. Deployment ini satu node dengan SQLite
  lokal, jadi pada saat start **tidak mungkin** ada job yang sah sedang berjalan:
  apa pun yang berstatus `executing` pasti milik proses yang sudah mati. Lifeline
  tetap dipasang sebagai jaring pengaman untuk pekerja yang mati saat aplikasi
  lain-lainnya masih hidup.

  Perlakuannya menyalin Lifeline: job yang jatahnya masih ada dikembalikan ke
  antrean, yang sudah habis ditandai gagal — bukan diulang selamanya.
  """
  def rescue_orphans(repo \\ MapsScraper.Repo) do
    import Ecto.Query

    now = DateTime.utc_now()

    # Hanya `state` yang diubah. `attempted_at` dan `attempted_by` berstatus NOT
    # NULL pada skema Oban, dan lagi pula akan ditimpa sendiri saat job berikutnya
    # benar-benar dijalankan.
    {kembali, _} =
      repo.update_all(
        from(j in "oban_jobs", where: j.state == "executing" and j.attempt < j.max_attempts),
        set: [state: "available"]
      )

    {menyerah, _} =
      repo.update_all(
        from(j in "oban_jobs", where: j.state == "executing" and j.attempt >= j.max_attempts),
        set: [state: "discarded", discarded_at: now]
      )

    {kembali, menyerah}
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.load(@app)
end
