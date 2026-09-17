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
      lookup: opts[:lookup] || config[:lookup] || MapsScraper.Maps
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
      %{state | jobs: Map.put(state.jobs, job.id, %{job | status: :running}), pending: pending}
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
        lookup = state.lookup

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
      Job.update_item(job, index, &%{&1 | status: :ok, result: summarize(payload), error: nil})

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
    job =
      if Job.settled?(job) and job.status != :done do
        %{job | status: :done, finished_at: DateTime.utc_now()}
      else
        job
      end

    %{state | jobs: Map.put(state.jobs, job.id, job)}
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

  # Jawaban validasi dipadatkan: cukup ketemu/tidak, seberapa cocok, dan satu
  # tempat teratas sebagai buktinya.
  defp summarize(payload) do
    place = payload |> Map.get("results", []) |> List.first()

    %{
      found: Map.get(payload, "found"),
      best_match: Map.get(payload, "best_match"),
      type: Map.get(payload, "type"),
      input_type: Map.get(payload, "input_type"),
      count: Map.get(payload, "count"),
      place: place && summarize_place(place)
    }
  end

  # Payload sidecar berkunci string; di sini disalin ke kunci atom agar seluruh
  # isi job konsisten. Daftar kuncinya tetap (tidak dibuat dari data), jadi tidak
  # ada risiko membuat atom baru dari masukan luar.
  defp summarize_place(place) do
    %{
      name: place["name"],
      address: place["address"],
      maps_url: place["maps_url"],
      place_id: place["place_id"],
      latitude: place["latitude"],
      longitude: place["longitude"]
    }
  end
end
