defmodule MapsScraper.Validation.QueueTest do
  # Antrean adalah proses tunggal milik aplikasi, jadi test-nya tidak boleh paralel.
  use ExUnit.Case, async: false

  alias MapsScraper.Validation
  alias MapsScraper.Validation.Job
  alias MapsScraper.Validation.Queue
  alias MapsScraper.ValidationStub

  setup do
    ValidationStub.reset()
    :ok
  end

  # Menunggu job selesai, tanpa membuat test menggantung kalau ada yang salah.
  defp await_done(job_id, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(job_id, deadline)
  end

  defp poll(job_id, deadline) do
    {:ok, job} = Validation.fetch(job_id)

    cond do
      job.status == :done ->
        job

      System.monotonic_time(:millisecond) > deadline ->
        flunk("job #{job_id} tidak selesai: #{inspect(Job.counts(job))}")

      true ->
        Process.sleep(10)
        poll(job_id, deadline)
    end
  end

  defp enqueue!(queries, opts \\ %{}) do
    {:ok, job} = Validation.enqueue(Map.put(opts, "queries", queries))
    job
  end

  describe "pemrosesan batch" do
    test "mengerjakan seluruh baris dan merangkum hasilnya" do
      job = enqueue!(["ok:Monas", "ok:Plaza Indonesia", "notfound:Tempat Fiktif"])
      assert job.status == :running

      done = await_done(job.id)
      assert done.status == :done
      assert Job.counts(done) == %{pending: 0, running: 0, ok: 3, error: 0}

      map = Job.to_map(done)
      assert map.total == 3
      # notfound tidak dihitung valid walaupun scraping-nya sendiri berhasil
      assert map.valid_count == 2

      [first | _] = map.results
      assert first.status == :ok
      assert first.found == true
      assert first.place.name == "Monas"
    end

    test "hasil dengan best_match rendah tidak dihitung valid" do
      job = enqueue!(["ok:Monas", "weak:Entah"]) |> Map.fetch!(:id) |> await_done()

      assert Job.counts(job).ok == 2
      assert Job.to_map(job).valid_count == 1
    end

    test "urutan hasil mengikuti urutan query yang dikirim" do
      queries = ["ok:A", "ok:B", "ok:C", "ok:D", "ok:E"]
      job = enqueue!(queries) |> Map.fetch!(:id) |> await_done()

      assert Enum.map(Job.to_map(job).results, & &1.query) == queries
      assert Enum.map(Job.to_map(job).results, & &1.index) == [0, 1, 2, 3, 4]
    end
  end

  describe "retry" do
    test "kegagalan sementara diulang sampai berhasil" do
      job = enqueue!(["flaky:2:Monas"]) |> Map.fetch!(:id) |> await_done()

      [result] = Job.to_map(job).results
      assert result.status == :ok
      # gagal dua kali, berhasil pada percobaan ketiga
      assert result.attempts == 3
      assert result.place.name == "Monas"
    end

    test "berhenti setelah max_attempts dan menandai barisnya gagal" do
      job = enqueue!(["timeout"]) |> Map.fetch!(:id) |> await_done()

      [result] = Job.to_map(job).results
      assert result.status == :error
      assert result.attempts == 3
      assert result.error.code == "timeout"
    end

    test "sidecar mati juga termasuk kegagalan sementara" do
      job = enqueue!(["unavailable", "server_error"]) |> Map.fetch!(:id) |> await_done()

      for result <- Job.to_map(job).results do
        assert result.status == :error
        assert result.attempts == 3
      end
    end

    test "parameter tidak valid tidak diulang" do
      job = enqueue!(["invalid"]) |> Map.fetch!(:id) |> await_done()

      [result] = Job.to_map(job).results
      assert result.status == :error
      assert result.attempts == 1
      assert result.error.code == "invalid_params"
    end

    test "task yang mati tidak menjatuhkan antrean dan barisnya diulang" do
      queue = Process.whereis(MapsScraper.Validation.Queue)

      job = enqueue!(["crash", "ok:Monas"]) |> Map.fetch!(:id) |> await_done()

      assert Process.whereis(MapsScraper.Validation.Queue) == queue
      assert Process.alive?(queue)

      results = Map.new(Job.to_map(job).results, &{&1.query, &1})
      assert results["crash"].status == :error
      assert results["crash"].attempts == 3
      assert results["ok:Monas"].status == :ok
    end

    test "satu baris gagal tidak menggagalkan baris lain" do
      job = enqueue!(["ok:A", "timeout", "ok:B"]) |> Map.fetch!(:id) |> await_done()

      counts = Job.counts(job)
      assert counts.ok == 2
      assert counts.error == 1
      assert job.status == :done
    end
  end

  describe "validasi masukan" do
    test "menolak batch kosong, bukan daftar, atau melebihi batas" do
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{})
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{"queries" => []})
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{"queries" => "monas"})
      assert {:error, {:invalid, "queries", _}} = Validation.enqueue(%{"queries" => ["a", 1]})

      assert {:error, {:invalid, "queries", _}} =
               Validation.enqueue(%{"queries" => ["ok:A", "  "]})

      terlalu_banyak = for i <- 1..11, do: "ok:#{i}"

      assert {:error, {:invalid, "queries", _}} =
               Validation.enqueue(%{"queries" => terlalu_banyak})
    end

    test "opsi yang keliru ditolak sebelum job diterima" do
      # Batas 202-nya tidak diberikan: kalau lolos, seluruh baris baru gagal
      # satu per satu setelah klien mengira batch-nya diterima.
      assert {:error, {:invalid, "limit", _}} =
               Validation.enqueue(%{"queries" => ["ok:A"], "limit" => "abc"})

      assert {:error, {:invalid, "detail", _}} =
               Validation.enqueue(%{"queries" => ["ok:A"], "detail" => "mungkin"})

      assert {:error, {:invalid, "country", _}} =
               Validation.enqueue(%{"queries" => ["ok:A"], "country" => "Indonesia"})

      assert {:ok, _job} = Validation.enqueue(%{"queries" => ["ok:A"], "limit" => "5"})
    end

    test "job yang tidak dikenal mengembalikan :error" do
      assert Validation.fetch("tidak-ada") == :error
    end
  end

  describe "retensi job" do
    # Antrean global dipakai test lain, jadi retensi diuji pada instance sendiri
    # dengan setelan yang jauh lebih ketat.
    defp start_queue(opts) do
      name = :"queue_#{System.unique_integer([:positive])}"
      {:ok, pid} = start_supervised({Queue, Keyword.put(opts, :name, name)})
      pid
    end

    defp await_done_on(server, job_id, timeout \\ 3_000) do
      deadline = System.monotonic_time(:millisecond) + timeout

      Stream.repeatedly(fn ->
        case Queue.fetch(server, job_id) do
          {:ok, %Job{status: :done}} -> :done
          _ -> Process.sleep(10)
        end
      end)
      |> Enum.find(fn
        :done -> true
        _ -> System.monotonic_time(:millisecond) > deadline and flunk("job tidak selesai")
      end)
    end

    test "job yang selesai dibuang setelah TTL-nya lewat" do
      queue = start_queue(job_ttl_ms: 60, max_jobs: 0)

      {:ok, job} = Queue.enqueue(queue, ["ok:Monas"], %{})
      await_done_on(queue, job.id)

      # Masih bisa diambil selama TTL belum lewat.
      assert {:ok, %Job{status: :done}} = Queue.fetch(queue, job.id)

      Process.sleep(150)
      assert Queue.fetch(queue, job.id) == :error
      assert Queue.stats(queue).jobs == 0
    end

    test "job selesai yang paling tua dibuang saat melewati max_jobs" do
      queue = start_queue(job_ttl_ms: 0, max_jobs: 2)

      [first, second, third] =
        for name <- ["ok:A", "ok:B", "ok:C"] do
          {:ok, job} = Queue.enqueue(queue, [name], %{})
          await_done_on(queue, job.id)
          job
        end

      assert Queue.stats(queue).jobs == 2
      assert Queue.fetch(queue, first.id) == :error
      assert {:ok, _} = Queue.fetch(queue, second.id)
      assert {:ok, _} = Queue.fetch(queue, third.id)
    end

    test "job yang masih berjalan tidak ikut dibuang" do
      queue = start_queue(job_ttl_ms: 0, max_jobs: 1)

      {:ok, running} = Queue.enqueue(queue, ["timeout"], %{})
      {:ok, next} = Queue.enqueue(queue, ["ok:Monas"], %{})

      # Batasnya terlampaui, tapi tidak ada job selesai yang bisa dikorbankan.
      assert {:ok, _} = Queue.fetch(queue, running.id)
      assert {:ok, _} = Queue.fetch(queue, next.id)
    end
  end

  describe "stats/0" do
    test "melaporkan konfigurasi antrean" do
      stats = Validation.stats()
      assert stats.concurrency == 2
      assert stats.max_attempts == 3
    end
  end
end
