defmodule MapsScraper.Validation.RetentionTest do
  use MapsScraper.DataCase, async: false

  alias MapsScraper.Validation
  alias MapsScraper.Validation.Batch
  alias MapsScraper.Validation.Cleaner
  alias MapsScraper.Validation.Retention
  alias MapsScraper.Validation.Row
  alias MapsScraper.ValidationStub

  setup do
    ValidationStub.reset()
    :ok
  end

  defp with_config(overrides, fun) do
    previous = Application.get_env(:maps_scraper, :validation, [])
    Application.put_env(:maps_scraper, :validation, Keyword.merge(previous, overrides))

    try do
      fun.()
    after
      Application.put_env(:maps_scraper, :validation, previous)
    end
  end

  defp selesai!(queries) do
    {:ok, batch} = Validation.enqueue(%{"queries" => queries})
    drain()
    batch
  end

  # Dipisah dari `selesai!/1` dengan sengaja: `Validation.enqueue/1` ikut
  # menyapu, jadi batch yang ditua-kan lebih dulu bisa lenyap saat batch
  # berikutnya dimasukkan — dan test-nya mengukur hal yang salah.
  defp tuakan!(batch, umur_detik, kolom \\ :finished_at) do
    waktu = DateTime.add(DateTime.utc_now(), -umur_detik, :second)
    Repo.update_all(from(b in Batch, where: b.id == ^batch.id), set: [{kolom, waktu}])
    batch
  end

  describe "sweep/1" do
    test "membuang batch selesai yang sudah lewat masa simpannya" do
      with_config([job_ttl_ms: :timer.hours(1), max_jobs: 0], fn ->
        lama = selesai!(["ok:A"])
        baru = selesai!(["ok:B"])
        tuakan!(lama, 7200)

        assert Retention.sweep() == 1
        assert Validation.fetch(lama.id) == :error
        assert {:ok, _} = Validation.fetch(baru.id)
      end)
    end

    test "baris ikut terhapus bersama batch-nya" do
      with_config([job_ttl_ms: :timer.hours(1), max_jobs: 0], fn ->
        batch = selesai!(["ok:A", "ok:B", "ok:C"]) |> tuakan!(7200)
        assert Repo.aggregate(from(r in Row, where: r.batch_id == ^batch.id), :count) == 3

        Retention.sweep()

        assert Repo.aggregate(from(r in Row, where: r.batch_id == ^batch.id), :count) == 0
      end)
    end

    test "batch yang masih berjalan tidak pernah dikorbankan" do
      with_config([job_ttl_ms: 1, max_jobs: 1], fn ->
        {:ok, berjalan} = Validation.enqueue(%{"queries" => ["ok:A"]})

        Retention.sweep()

        assert {:ok, _} = Validation.fetch(berjalan.id)
      end)
    end

    test "membuang batch yang tidak pernah selesai setelah ambang jauh terlewat" do
      # Jaring pengaman: pekerjanya hilang atau job-nya dibuang sebelum sempat
      # menandai barisnya. Tanpa ini batch seperti itu mengendap selamanya.
      with_config([job_ttl_ms: :timer.hours(1), max_jobs: 0], fn ->
        {:ok, batch} = Validation.enqueue(%{"queries" => ["ok:A"]})

        tuakan!(batch, 30 * 24 * 3600, :inserted_at)

        assert Retention.sweep() == 1
        assert Validation.fetch(batch.id) == :error
      end)
    end

    test "headroom menyediakan tempat untuk batch yang sedang masuk" do
      with_config([job_ttl_ms: 0, max_jobs: 2], fn ->
        for nama <- ["ok:A", "ok:B"], do: selesai!([nama])

        # Tanpa headroom, dua batch masih muat.
        assert Retention.sweep() == 0
        # Dengan headroom 1, satu harus dibuang agar ada ruang.
        assert Retention.sweep(headroom: 1) == 1
      end)
    end

    test "TTL nol mematikan penghapusan berbasis umur" do
      with_config([job_ttl_ms: 0, max_jobs: 0], fn ->
        batch = selesai!(["ok:A"]) |> tuakan!(999_999)

        assert Retention.sweep() == 0
        assert {:ok, _} = Validation.fetch(batch.id)
      end)
    end
  end

  describe "Cleaner" do
    test "menyapu dan tetap selesai walau vacuum tidak bisa dijalankan" do
      # Di dalam test, seluruhnya berjalan pada satu transaksi sandbox — dan
      # VACUUM memang tidak boleh berada di dalam transaksi. Justru itu yang
      # membuat kasus ini berguna: kegagalan vacuum tidak boleh menggagalkan
      # penyapuannya, karena datanya sudah terlanjur terhapus.
      with_config([job_ttl_ms: :timer.hours(1), max_jobs: 0], fn ->
        lama = selesai!(["ok:A"]) |> tuakan!(7200)

        assert :ok = perform_job(Cleaner, %{})
        assert Validation.fetch(lama.id) == :error
      end)
    end
  end

  describe "database_bytes/0" do
    test "melaporkan ukuran berkas dari halamannya" do
      assert Retention.database_bytes() > 0
    end
  end

  defp perform_job(worker, args) do
    worker.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 1})
  end
end
