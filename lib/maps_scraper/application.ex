defmodule MapsScraper.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MapsScraperWeb.Telemetry,
      MapsScraper.Repo,
      {DNSCluster, query: Application.get_env(:maps_scraper, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MapsScraper.PubSub},
      # Start a worker by calling: MapsScraper.Worker.start_link(arg)
      # {MapsScraper.Worker, arg},
      # Start to serve requests, typically the last entry
      MapsScraperWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MapsScraper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MapsScraperWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
