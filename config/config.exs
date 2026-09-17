# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure the endpoint
config :maps_scraper, MapsScraperWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MapsScraperWeb.ErrorJSON], layout: false],
  pubsub_server: MapsScraper.PubSub

# Sidecar Playwright yang melakukan scraping Google Maps (lihat docker-compose.yml)
config :maps_scraper, :scraper,
  base_url: "http://localhost:3000",
  timeout: 45_000

# Antrean validasi massal (MapsScraper.Validation.Queue)
config :maps_scraper, :validation,
  # berapa query diproses bersamaan; jangan melebihi kapasitas sidecar
  concurrency: 3,
  # termasuk percobaan pertama, jadi 3 berarti 1 kali jalan + 2 kali ulang
  max_attempts: 3,
  backoff_ms: 1_000,
  max_backoff_ms: 30_000,
  max_batch: 500

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
