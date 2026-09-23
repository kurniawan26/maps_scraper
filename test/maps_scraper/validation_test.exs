defmodule MapsScraper.ValidationTest do
  # Beberapa test menimpa konfigurasi aplikasi, jadi tidak boleh paralel.
  use MapsScraper.DataCase, async: false

  alias MapsScraper.Validation
  alias MapsScraper.Validation.Batch
  alias MapsScraper.Validation.Row
  alias MapsScraper.ValidationStub

  setup do
    ValidationStub.reset()
    :ok
  end

  defp enqueue!(queries, opts \\ %{}) do
    {:ok, batch} = Validation.enqueue(Map.put(opts, "queries", queries))
    batch
  end

  # Menjalankan antrean sampai kosong, lalu mengambil keadaan akhirnya.
  defp run!(batch) do
    drain()
    {:ok, done} = Validation.fetch(batch.id)
    done
  end

  defp results(batch), do: Batch.to_map(batch).results

  defp with_config(overrides, fun) do
    previous = Application.get_env(:maps_scraper, :validation, [])
    Application.put_env(:maps_scraper, :validation, Keyword.merge(previous, overrides))

    try do
      fun.()
    after
      Application.put_env(:maps_scraper, :validation, previous)
    end
  end

  describe "pemrosesan batch" do
    test "mengerjakan seluruh baris dan merangkum hasilnya" do
      batch = enqueue!(["ok:Monas", "ok:Plaza Indonesia", "notfound:Tempat Fiktif"])
      assert batch.total == 3
      refute batch.finished_at

      done = run!(batch)
      map = Batch.to_map(done)

      assert map.status == :done
      assert map.counts == %{pending: 0, running: 0, ok: 3, error: 0}
      # notfound tidak dihitung cocok walaupun scraping-nya sendiri berhasil
      assert map.verdicts == %{match: 2, review: 0, no_match: 1}

      [first | _] = map.results
      assert first.status == :ok
      assert first.found == true
      assert first.verdict == :match
      assert [%{name: "Monas"}] = first.candidates
    end

    test "urutan hasil mengikuti urutan query yang dikirim" do
      queries = ["ok:A", "ok:B", "ok:C", "ok:D", "ok:E"]
      done = queries |> enqueue!() |> run!()

      assert Enum.map(results(done), & &1.query) == queries
      assert Enum.map(results(done), & &1.index) == [0, 1, 2, 3, 4]
    end

    test "batch yang belum selesai tidak punya finished_at" do
      batch = enqueue!(["ok:A"])
      {:ok, belum} = Validation.fetch(batch.id)

      assert Batch.to_map(belum).status == :running
      assert Batch.to_map(run!(batch)).status == :done
    end
  end

  describe "ketahanan terhadap restart" do
    test "baris tersimpan di database, bukan di memori proses" do
      # Inti pindah ke Oban: dulu seluruh batch hidup di state sebuah GenServer
      # dan ikut hilang setiap aplikasi di-restart.
      batch = enqueue!(["ok:Monas", "ok:Plaza"])

      tersimpan = Repo.all(from(r in Row, where: r.batch_id == ^batch.id, order_by: r.index))
      assert Enum.map(tersimpan, & &1.query) == ["ok:Monas", "ok:Plaza"]
      assert Enum.all?(tersimpan, &(&1.status == "pending"))

      # Job-nya pun tersimpan, bukan sekadar pesan yang melayang di antrean.
      assert Repo.aggregate(from(j in "oban_jobs", where: j.queue == "validation"), :count) >= 2
    end
  end

  describe "sidecar penuh" do
    test "busy tidak menghabiskan jatah percobaan" do
      # Ini yang dulu merusak: dengan antrean lama, lima kali `busy` berturut-turut
      # membuat baris yang datanya sehat divonis gagal setelah percobaan ketiga.
      # Oban mengembalikan hitungan percobaan saat job di-snooze, jadi kemacetan
      # yang kita timbulkan sendiri tidak lagi menghapus data yang valid.
      done = enqueue!(["busy:5:Monas"]) |> run!()

      [result] = results(done)
      assert result.status == :ok
      assert result.attempts == 1
      assert [%{name: "Monas"}] = result.candidates
    end

    test "busy berulang tidak pernah menjadi vonis gagal" do
      done = enqueue!(["busy:8:Monas", "ok:Lain"]) |> run!()

      assert Batch.counts(done) == %{pending: 0, running: 0, ok: 2, error: 0}
    end
  end

  describe "vonis dan kandidat" do
    test "kandidat diurutkan dari yang paling cocok, bukan urutan Google" do
      done = enqueue!(["multi:Monas"]) |> run!()
      [result] = results(done)

      assert Enum.map(result.candidates, & &1.name) == ["Monas", "Mirip B", "Mirip A"]
      assert Enum.map(result.candidates, & &1.match) == [1, 0.5, 0.2]
      assert result.verdict == :match
    end

    test "kandidat dipotong sesuai max_candidates" do
      with_config([max_candidates: 2], fn ->
        done = enqueue!(["multi:Monas"]) |> run!()
        [result] = results(done)
        assert Enum.map(result.candidates, & &1.name) == ["Monas", "Mirip B"]
      end)
    end

    test "kandidat teratas yang berimpit tetap dinilai di luar walau skornya penuh" do
      done = enqueue!(["ambigu:Apotek Gambir"]) |> run!()
      [result] = results(done)

      assert result.best_match == 1
      assert Enum.map(result.candidates, & &1.match) == [1, 1, 0.25]
      assert result.verdict == :review
    end

    test "batas keberimpitan dapat disetel" do
      with_config([ambiguity_margin: 0.6], fn ->
        done = enqueue!(["multi:Monas"]) |> run!()
        assert [%{verdict: :review}] = results(done)
      end)
    end

    test "ambang vonis dapat disetel" do
      with_config([match_threshold: 0.4, review_threshold: 0.1], fn ->
        done = enqueue!(["review:Entah", "weak:Entah"]) |> run!()
        assert Batch.verdicts(done) == %{match: 1, review: 0, no_match: 1}
      end)
    end

    test "hasil dengan best_match rendah divonis tidak cocok" do
      done = enqueue!(["ok:Monas", "weak:Entah"]) |> run!()

      assert Batch.counts(done).ok == 2
      assert Batch.verdicts(done) == %{match: 1, review: 0, no_match: 1}
    end

    test "tanpa skor kemiripan tidak lolos otomatis" do
      done = enqueue!(["nomatch:Entah"]) |> run!()
      [result] = results(done)

      assert result.best_match == nil
      assert result.verdict == :review
    end

    test "kandidat membawa ketiga identitas yang mungkin" do
      done = enqueue!(["ok:Monas"]) |> run!()
      [%{candidates: [candidate]}] = results(done)

      assert candidate.place_id == "ChIJMonas"
      assert candidate.cid == "4407571450964851912"
      assert candidate.ftid == "0x2e69f5d2e764b12d:0x3d2ad6e1e0e9bcc8"
      assert candidate.maps_url =~ "google.com/maps/place/"
    end

    test "baris yang gagal di-scrape tidak masuk rekap vonis" do
      done = enqueue!(["ok:Monas", "timeout"]) |> run!()

      assert Batch.verdicts(done) == %{match: 1, review: 0, no_match: 0}
      assert Batch.counts(done) == %{pending: 0, running: 0, ok: 1, error: 1}
    end
  end

  describe "retry" do
    test "kegagalan sementara diulang sampai berhasil" do
      done = enqueue!(["flaky:2:Monas"]) |> run!()
      [result] = results(done)

      assert result.status == :ok
      assert result.attempts == 3
      assert [%{name: "Monas"}] = result.candidates
    end

    test "berhenti setelah max_attempts dan menandai barisnya gagal" do
      done = enqueue!(["timeout"]) |> run!()
      [result] = results(done)

      assert result.status == :error
      assert result.attempts == 3
      assert result.error.code == "timeout"
    end

    test "sidecar mati juga termasuk kegagalan sementara" do
      done = enqueue!(["unavailable", "server_error"]) |> run!()

      for result <- results(done) do
        assert result.status == :error
        assert result.attempts == 3
      end
    end

    test "parameter tidak valid tidak diulang" do
      done = enqueue!(["invalid"]) |> run!()
      [result] = results(done)

      assert result.status == :error
      assert result.attempts == 1
      assert result.error.code == "invalid_params"
    end

    test "context yang meledak tidak meninggalkan baris menggantung" do
      # Tanpa penangkapan di worker, barisnya tetap berstatus "running" selamanya
      # dan batch-nya tidak pernah ditutup.
      done = enqueue!(["crash", "ok:Monas"]) |> run!()

      hasil = Map.new(results(done), &{&1.query, &1})
      assert hasil["crash"].status == :error
      assert hasil["crash"].error.code == "crashed"
      assert hasil["ok:Monas"].status == :ok
      assert Batch.to_map(done).status == :done
    end

    test "satu baris gagal tidak menggagalkan baris lain" do
      done = enqueue!(["ok:A", "timeout", "ok:B"]) |> run!()

      counts = Batch.counts(done)
      assert counts.ok == 2
      assert counts.error == 1
    end
  end

  describe "sumber data" do
    test "defaultnya maps kalau tidak disebutkan" do
      assert enqueue!(["ok:Monas"]).source == "maps"
    end

    test "batch instagram dirangkum sebagai akun" do
      done = enqueue!(["ok.kournicloud"], %{"source" => "instagram"}) |> run!()
      [result] = results(done)

      assert result.verdict == :match
      assert [%{username: "kournicloud", followers: 710}] = result.candidates
      refute Map.has_key?(hd(result.candidates), :place_id)
    end

    test "batch website dirangkum sebagai halaman" do
      done = enqueue!(["https://ok.contoh.invalid/"], %{"source" => "website"}) |> run!()
      [result] = results(done)

      assert result.verdict == :match
      assert [%{url: "https://ok.contoh.invalid/", status: 200}] = result.candidates
      refute Map.has_key?(hd(result.candidates), :username)
    end

    test "batch marketplace dirangkum sebagai toko" do
      done =
        enqueue!(["https://www.tokopedia.com/oksamsung"], %{"source" => "marketplace"}) |> run!()

      [result] = results(done)

      assert result.verdict == :match

      assert [%{platform: "tokopedia", slug: "oksamsung", store_name: "Toko oksamsung"}] =
               result.candidates

      refute Map.has_key?(hd(result.candidates), :username)
    end

    test "toko yang tidak ada divonis tidak cocok" do
      done =
        enqueue!(["https://www.tokopedia.com/notfoundtoko"], %{"source" => "marketplace"})
        |> run!()

      [result] = results(done)
      assert result.found == false
      assert result.verdict == :no_match
    end

    test "penolakan Shopee diulang, bukan divonis toko tidak ada" do
      done =
        enqueue!(["https://shopee.co.id/blockedtoko"], %{"source" => "marketplace"}) |> run!()

      [result] = results(done)

      assert result.status == :error
      assert result.attempts == 3
      assert result.error.code == "shopee_blocked"
      assert Batch.verdicts(done) == %{match: 0, review: 0, no_match: 0}
    end

    test "baris marketplace tanpa host ditolak di depan" do
      # "samsung" ada di kedua platform sebagai toko yang berbeda.
      assert {:error, {:invalid, "queries", _}} =
               Validation.enqueue(%{"queries" => ["samsung"], "source" => "marketplace"})

      assert {:error, {:invalid, "queries", _}} =
               Validation.enqueue(%{
                 "queries" => ["bukalapak.com/samsung"],
                 "source" => "marketplace"
               })
    end

    test "penolakan Instagram diulang, bukan divonis akun tidak ada" do
      done = enqueue!(["blocked"], %{"source" => "instagram"}) |> run!()
      [result] = results(done)

      assert result.status == :error
      assert result.attempts == 3
      assert result.error.code == "instagram_blocked"
      assert Batch.verdicts(done) == %{match: 0, review: 0, no_match: 0}
    end
  end

  describe "validasi masukan" do
    test "menolak batch kosong, bukan daftar, atau melebihi batas" do
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{})
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{"queries" => []})
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{"queries" => "monas"})
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{"queries" => ["a", 1]})

      assert {:error, {:invalid, "queries", _}} =
               Validation.enqueue(%{"queries" => ["ok:A", " "]})

      terlalu_banyak = for i <- 1..11, do: "ok:#{i}"

      assert {:error, {:invalid, "queries", _}} =
               Validation.enqueue(%{"queries" => terlalu_banyak})
    end

    test "opsi yang keliru ditolak sebelum batch diterima" do
      assert {:error, {:invalid, "limit", _}} =
               Validation.enqueue(%{"queries" => ["ok:A"], "limit" => "abc"})

      assert {:error, {:invalid, "detail", _}} =
               Validation.enqueue(%{"queries" => ["ok:A"], "detail" => "mungkin"})

      assert {:ok, _} = Validation.enqueue(%{"queries" => ["ok:A"], "limit" => "5"})
    end

    test "sumber yang tidak dikenal ditolak" do
      assert {:error, {:invalid, "source", _}} =
               Validation.enqueue(%{"queries" => ["ok:A"], "source" => "tiktok"})
    end

    test "baris yang bukan akun Instagram ditolak di depan" do
      assert {:error, {:invalid, "queries", _}} =
               Validation.enqueue(%{
                 "queries" => ["https://www.instagram.com/p/ABC/"],
                 "source" => "instagram"
               })
    end

    test "baris website yang menunjuk alamat internal ditolak di depan" do
      assert {:error, {:invalid, "queries", pesan}} =
               Validation.enqueue(%{
                 "queries" => ["https://ok.contoh.invalid/", "http://127.0.0.1:4000/"],
                 "source" => "website"
               })

      assert pesan =~ "alamat internal"
    end

    test "batch yang tidak dikenal mengembalikan :error" do
      assert Validation.fetch("tidak-ada") == :error
    end
  end

  describe "retensi" do
    test "batch selesai yang paling tua dibuang saat melewati max_jobs" do
      with_config([max_jobs: 2, job_ttl_ms: 0], fn ->
        [pertama, kedua, ketiga] =
          for nama <- ["ok:A", "ok:B", "ok:C"] do
            batch = enqueue!([nama])
            run!(batch)
            batch
          end

        assert Validation.fetch(pertama.id) == :error
        assert {:ok, _} = Validation.fetch(kedua.id)
        assert {:ok, _} = Validation.fetch(ketiga.id)
      end)
    end

    test "batch yang masih berjalan tidak pernah dikorbankan" do
      with_config([max_jobs: 1, job_ttl_ms: 0], fn ->
        berjalan = enqueue!(["ok:A"])
        berikutnya = enqueue!(["ok:B"])

        assert {:ok, _} = Validation.fetch(berjalan.id)
        assert {:ok, _} = Validation.fetch(berikutnya.id)
      end)
    end

    test "batch selesai dibuang setelah TTL-nya lewat" do
      with_config([job_ttl_ms: 1, max_jobs: 0], fn ->
        lama = enqueue!(["ok:A"])
        run!(lama)
        Process.sleep(20)

        # Pembersihan terjadi saat batch baru masuk, bukan lewat timer yang ikut
        # hilang saat restart.
        enqueue!(["ok:B"])
        assert Validation.fetch(lama.id) == :error
      end)
    end
  end

  describe "stats/0" do
    test "melaporkan konfigurasi antrean" do
      stats = Validation.stats()
      assert stats.max_attempts == 3
      assert is_integer(stats.concurrency)
    end
  end
end
