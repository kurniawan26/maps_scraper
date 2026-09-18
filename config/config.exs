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

config :maps_scraper, :scraper,
  base_url: "http://localhost:3000",
  timeout: 45_000,
  detail_budget_ms: 60_000

config :maps_scraper, :validation,
  concurrency: 3,
  max_attempts: 3,
  backoff_ms: 1_000,
  max_backoff_ms: 30_000,
  max_batch: 500,
  job_ttl_ms: 900_000,
  max_jobs: 1_000,
  max_candidates: 5,
  match_threshold: 0.8,
  review_threshold: 0.3,
  ambiguity_margin: 0.1

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
