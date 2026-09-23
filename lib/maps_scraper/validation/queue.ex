defmodule MapsScraper.Validation.Queue do
  @moduledoc """
  Antrean validasi massal.

  GenServer ini memegang seluruh job di dalam state-nya dan menjalankan paling
  banyak `:concurrency` permintaan scraping sekaligus. Tiap baris dikerjakan oleh
  task terpisah di bawah `Task.Supervisor`, disambungkan dengan `async_nolink/3`
  supaya task yang mati tidak ikut menjatuhkan antrean — kematiannya sampai ke
  sini sebagai `:DOWN` dan diperlakukan sebagai kegagalan yang bisa diulang.

  Kegagalan sementara (timeout, sidecar mati, error 5xx) diulang sampai
  `:max_attempts` kali dengan jeda yang menggandakan diri. Kegagalan permanen
  (parameter tidak valid) langsung ditandai gagal tanpa pengulangan.

  Catatan: state ini ada di memori. Kalau aplikasi di-restart, job yang belum
  selesai ikut hilang. Selama fase development itu sepadan dengan
  kesederhanaannya; untuk produksi, job perlu dipindahkan ke Postgres.

  Supaya state tidak tumbuh tanpa batas, job yang sudah selesai dibuang setelah
  `:job_ttl_ms` lewat, dan jumlah job yang disimpan dibatasi `:max_jobs` —
  yang dibuang selalu job selesai yang paling tua.
  """

  use GenServer

  require Logger

  alias MapsScraper.Validation.Job

  @task_supervisor MapsScraper.Validation.TaskSupervisor

  # ------------------------------------------------------------------
  # API
  # ------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Mendaftarkan batch query dan langsung mulai mengerjakannya."
  def enqueue(server \\ __MODULE__, queries, opts) do
    GenServer.call(server, {:enqueue, queries, opts})
  end

  @doc "Mengambil job beserta status tiap barisnya."
  def fetch(server \\ __MODULE__, job_id) do
    GenServer.call(server, {:fetch, job_id})
  end

  @doc "Ringkasan antrean: berapa job, berapa baris menunggu, berapa berjalan."
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # ------------------------------------------------------------------
  # Callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:maps_scraper, :validation, [])

    state = %{
      jobs: %{},
      # {job_id, index} yang menunggu giliran
      pending: :queue.new(),
      # ref task -> {job_id, index}
      running: %{},
      concurrency: opts[:concurrency] || config[:concurrency] || 3,
      max_attempts: opts[:max_attempts] || config[:max_attempts] || 3,
      backoff_ms: opts[:backoff_ms] || config[:backoff_ms] || 1_000,
      max_backoff_ms: opts[:max_backoff_ms] || config[:max_backoff_ms] || 30_000,
      # Berapa lama job yang sudah selesai masih bisa diambil sebelum dibuang.
      job_ttl_ms: opts[:job_ttl_ms] || config[:job_ttl_ms] || 900_000,
      # Batas keras jumlah job tersimpan, untuk deret job yang datang lebih cepat
      # daripada TTL-nya lewat. Isi 0 untuk mematikan salah satunya.
      max_jobs: opts[:max_jobs] || config[:max_jobs] || 1_000,
      max_candidates: opts[:max_candidates] || config[:max_candidates] || 5,
      match_threshold: opts[:match_threshold] || config[:match_threshold] || 0.8,
      review_threshold: opts[:review_threshold] || config[:review_threshold] || 0.3,
      ambiguity_margin: opts[:ambiguity_margin] || config[:ambiguity_margin] || 0.1,
      # Context yang mengerjakan satu baris, dipilih dari sumber job-nya.
      lookups: opts[:lookups] || config[:lookups] || MapsScraper.Validation.sources(),
      # Kalau diisi, menimpa seluruh sumber sekaligus. Dipakai test untuk
      # mengganti seluruh jalur scraping dengan satu stub.
      lookup: opts[:lookup] || config[:lookup]
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, queries, opts}, _from, state) do
    job = Job.new(queries, opts)

    pending =
      job.items
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(state.pending, fn index, acc -> :queue.in({job.id, index}, acc) end)

    state =
      state
      |> enforce_max_jobs()
      |> Map.update!(:jobs, &Map.put(&1, job.id, %{job | status: :running}))
      |> Map.put(:pending, pending)
      |> dispatch()

    {:reply, {:ok, Map.fetch!(state.jobs, job.id)}, state}
  end

  def handle_call({:fetch, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} -> {:reply, {:ok, job}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      jobs: map_size(state.jobs),
      pending: :queue.len(state.pending),
      running: map_size(state.running),
      concurrency: state.concurrency,
      max_attempts: state.max_attempts
    }

    {:reply, stats, state}
  end

  # Task selesai dengan hasil.
  @impl true
  def handle_info({ref, outcome}, state) when is_reference(ref) do
    # Hasil sudah diterima; :DOWN yang menyusul tidak perlu diproses lagi.
    Process.demonitor(ref, [:flush])

    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {{job_id, index}, running} ->
        state =
          %{state | running: running}
          |> settle(job_id, index, outcome)
          |> dispatch()

        {:noreply, state}
    end
  end

  # Task mati sebelum sempat membalas — diperlakukan sebagai kegagalan sementara.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {{job_id, index}, running} ->
        Logger.error("task validasi mati: #{inspect(reason)}")

        state =
          %{state | running: running}
          |> settle(job_id, index, {:error, {:crashed, reason}})
          |> dispatch()

        {:noreply, state}
    end
  end

  # Giliran ulang setelah jeda backoff.
  def handle_info({:retry, job_id, index}, state) do
    if Map.has_key?(state.jobs, job_id) do
      state =
        %{state | pending: :queue.in({job_id, index}, state.pending)}
        |> dispatch()

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Job yang sudah selesai dibuang setelah TTL-nya lewat. Tanpa ini state
  # GenServer hanya pernah bertambah dan proses akan kehabisan memori.
  def handle_info({:expire, job_id}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, job_id)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Penjadwalan
  # ------------------------------------------------------------------

  # Mengisi slot yang kosong dari antrean sampai batas concurrency.
  defp dispatch(state) do
    if map_size(state.running) >= state.concurrency do
      state
    else
      case :queue.out(state.pending) do
        {:empty, _pending} ->
          state

        {{:value, {job_id, index}}, pending} ->
          state
          |> Map.put(:pending, pending)
          |> start_task(job_id, index)
          |> dispatch()
      end
    end
  end

  defp start_task(state, job_id, index) do
    case Map.fetch(state.jobs, job_id) do
      :error ->
        state

      {:ok, job} ->
        item = Job.get_item(job, index)
        params = Map.merge(job.opts, %{"query" => item.query})
        lookup = lookup_for(state, job.source)

        task =
          Task.Supervisor.async_nolink(@task_supervisor, fn ->
            lookup.lookup(params)
          end)

        job = Job.update_item(job, index, &%{&1 | status: :running, attempts: &1.attempts + 1})

        %{
          state
          | jobs: Map.put(state.jobs, job_id, job),
            running: Map.put(state.running, task.ref, {job_id, index})
        }
    end
  end

  defp lookup_for(%{lookup: lookup}, _source) when not is_nil(lookup), do: lookup
  defp lookup_for(state, source), do: Map.fetch!(state.lookups, source)

  # ------------------------------------------------------------------
  # Hasil dan pengulangan
  # ------------------------------------------------------------------

  defp settle(state, job_id, index, outcome) do
    case Map.fetch(state.jobs, job_id) do
      :error -> state
      {:ok, job} -> settle_job(state, job, index, outcome)
    end
  end

  defp settle_job(state, job, index, {:ok, payload}) do
    job =
      Job.update_item(
        job,
        index,
        &%{&1 | status: :ok, result: summarize(payload, state, job.source), error: nil}
      )

    put_job(state, job)
  end

  defp settle_job(state, job, index, {:error, reason}) do
    item = Job.get_item(job, index)

    if retryable?(reason) and item.attempts < state.max_attempts do
      schedule_retry(state, job.id, index, item.attempts)

      job = Job.update_item(job, index, &%{&1 | status: :pending, error: describe(reason)})
      put_job(state, job)
    else
      job = Job.update_item(job, index, &%{&1 | status: :error, error: describe(reason)})
      put_job(state, job)
    end
  end

  defp put_job(state, job) do
    just_finished? = Job.settled?(job) and job.status != :done

    job =
      if just_finished? do
        %{job | status: :done, finished_at: DateTime.utc_now()}
      else
        job
      end

    if just_finished? and state.job_ttl_ms > 0 do
      Process.send_after(self(), {:expire, job.id}, state.job_ttl_ms)
    end

    %{state | jobs: Map.put(state.jobs, job.id, job)}
  end

  # Membuang job selesai yang paling tua sampai jumlahnya kembali di bawah batas.
  # Job yang masih berjalan tidak pernah dibuang — kehilangan pekerjaan yang
  # sedang jalan lebih buruk daripada sesaat melewati batas.
  defp enforce_max_jobs(state) do
    excess = map_size(state.jobs) - state.max_jobs + 1

    if state.max_jobs <= 0 or excess <= 0 do
      state
    else
      finished =
        state.jobs
        |> Enum.filter(fn {_id, job} -> job.status == :done end)
        |> Enum.sort_by(fn {_id, job} -> job.finished_at end, DateTime)
        |> Enum.take(excess)

      if length(finished) < excess do
        Logger.warning(
          "antrean validasi menyimpan #{map_size(state.jobs)} job, melewati batas " <>
            "#{state.max_jobs}; tidak ada job selesai yang bisa dibuang"
        )
      end

      Enum.reduce(finished, state, fn {id, _job}, acc ->
        %{acc | jobs: Map.delete(acc.jobs, id)}
      end)
    end
  end

  # Jeda menggandakan diri, dengan sedikit acak supaya percobaan ulang beberapa
  # baris tidak menghantam sidecar pada detik yang sama.
  defp schedule_retry(state, job_id, index, attempts) do
    delay =
      state.backoff_ms
      |> Kernel.*(2 ** (attempts - 1))
      |> round()
      |> min(state.max_backoff_ms)

    jitter = :rand.uniform(max(div(delay, 4), 1))
    Process.send_after(self(), {:retry, job_id, index}, delay + jitter)
  end

  # Kegagalan sementara layak diulang; kesalahan parameter tidak akan pernah
  # berubah hasilnya, jadi langsung ditandai gagal.
  defp retryable?(:timeout), do: true
  defp retryable?(:unavailable), do: true
  defp retryable?({:crashed, _reason}), do: true
  defp retryable?({:scraper, status, _error}) when status >= 500, do: true
  defp retryable?(_reason), do: false

  defp describe(:timeout), do: %{code: "timeout", message: "Scraping melebihi batas waktu"}

  defp describe(:unavailable),
    do: %{code: "scraper_unavailable", message: "Sidecar tidak dapat dihubungi"}

  defp describe({:crashed, reason}),
    do: %{code: "crashed", message: "Task berhenti: #{inspect(reason)}"}

  defp describe({:scraper, _status, error}),
    do: %{
      code: Map.get(error, "code", "scrape_failed"),
      message: Map.get(error, "message", "Gagal mengambil data")
    }

  defp describe({:invalid, field, message}),
    do: %{code: "invalid_params", field: field, message: message}

  defp describe(other), do: %{code: "unknown", message: inspect(other)}

  defp summarize(payload, state, source) do
    found = Map.get(payload, "found")
    best_match = Map.get(payload, "best_match")

    candidates =
      payload
      |> Map.get("results", [])
      |> sort_by_match()
      |> Enum.take(state.max_candidates)
      |> Enum.map(&summarize_candidate(&1, source))

    %{
      found: found,
      best_match: best_match,
      verdict: verdict(found, best_match, candidates, state),
      type: Map.get(payload, "type"),
      input_type: Map.get(payload, "input_type"),
      count: Map.get(payload, "count"),
      candidates: candidates
    }
  end

  defp sort_by_match(results) do
    if Enum.all?(results, &is_nil(&1["match"])) do
      results
    else
      Enum.sort_by(results, &(&1["match"] || -1), :desc)
    end
  end

  defp verdict(_found, _best_match, [], _state), do: :no_match
  defp verdict(found, _best_match, _candidates, _state) when found != true, do: :no_match
  defp verdict(_found, nil, _candidates, _state), do: :review

  defp verdict(_found, score, candidates, state) when is_number(score) do
    cond do
      score < state.review_threshold -> :no_match
      score < state.match_threshold -> :review
      ambiguous?(candidates, state) -> :review
      true -> :match
    end
  end

  defp verdict(_found, _best_match, _candidates, _state), do: :review

  defp ambiguous?([%{match: first}, %{match: second} | _], state)
       when is_number(first) and is_number(second) do
    first - second <= state.ambiguity_margin
  end

  defp ambiguous?(_candidates, _state), do: false

  # Kandidat dipangkas ke kolom yang dibutuhkan penilai di luar service ini.
  # Bentuknya berbeda per sumber: identitas stabil sebuah tempat adalah
  # place_id/cid/ftid, sedangkan sebuah akun Instagram cukup username-nya.
  defp summarize_candidate(place, "instagram") do
    %{
      username: place["username"],
      full_name: place["full_name"],
      profile_url: place["profile_url"],
      followers: place["followers"],
      verified: place["verified"],
      private: place["private"],
      match: place["match"]
    }
  end

  defp summarize_candidate(place, _source) do
    %{
      name: place["name"],
      address: place["address"],
      maps_url: place["maps_url"],
      place_id: place["place_id"],
      cid: place["cid"],
      ftid: place["ftid"],
      latitude: place["latitude"],
      longitude: place["longitude"],
      match: place["match"]
    }
  end
end
