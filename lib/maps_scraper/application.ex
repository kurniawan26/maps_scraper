defmodule MapsScraper.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Berkas SQLite bisa saja baru dibuat container yang barusan menyala, jadi
    # skemanya disiapkan lebih dulu — sebelum Repo dan Oban ikut start.
    if Application.get_env(:maps_scraper, :auto_migrate, false) do
      MapsScraper.Release.migrate()
    end

    children =
      [
        MapsScraperWeb.Telemetry,
        MapsScraper.Repo,
        {DNSCluster, query: Application.get_env(:maps_scraper, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: MapsScraper.PubSub}
      ] ++
        rescue_child() ++
        [
          # Antrean validasi. Job-nya tersimpan di SQLite, jadi batch yang sedang
          # berjalan saat aplikasi berhenti dilanjutkan, bukan dibuang.
          {Oban, Application.fetch_env!(:maps_scraper, Oban)},
          # Start to serve requests, typically the last entry
          MapsScraperWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MapsScraper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Harus berjalan setelah Repo dan sebelum Oban: sesudahnya, job yang sudah
  # terlanjur diambil pekerja baru akan ikut tersapu.
  defp rescue_child do
    if Application.get_env(:maps_scraper, :rescue_orphans_on_boot, true) do
      [
        %{
          id: :rescue_orphans,
          start: {Task, :start_link, [&rescue_orphans/0]},
          restart: :transient
        }
      ]
    else
      []
    end
  end

  # Ini percepatan, bukan syarat jalan: kalau gagal, Oban.Plugins.Lifeline tetap
  # membebaskan job yatim setelah `rescue_after`. Karena itu kegagalannya dicatat
  # dan ditelan — aplikasi yang menolak menyala gara-gara ini jauh lebih buruk
  # daripada pemulihan yang tertunda beberapa menit.
  defp rescue_orphans do
    case MapsScraper.Release.rescue_orphans() do
      {0, 0} ->
        :ok

      {kembali, menyerah} ->
        Logger.info(
          "job tertinggal dari proses sebelumnya: #{kembali} dikembalikan ke antrean, " <>
            "#{menyerah} ditandai gagal karena jatah percobaannya sudah habis"
        )
    end
  rescue
    error ->
      Logger.warning(
        "gagal membebaskan job yatim: #{Exception.message(error)}; " <>
          "Lifeline akan menanganinya"
      )

      :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MapsScraperWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
