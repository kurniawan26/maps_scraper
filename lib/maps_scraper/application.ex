defmodule MapsScraper.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
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
          {Oban, Application.fetch_env!(:maps_scraper, Oban)},
          MapsScraperWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: MapsScraper.Supervisor]
    Supervisor.start_link(children, opts)
  end

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

  @impl true
  def config_change(changed, _new, removed) do
    MapsScraperWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
