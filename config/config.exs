import Config

config :maps_scraper, ecto_repos: [MapsScraper.Repo]

config :maps_scraper, MapsScraper.Repo,
  database: Path.expand("../priv/maps_scraper_dev.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool_size: 5

config :maps_scraper, MapsScraperWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MapsScraperWeb.ErrorJSON], layout: false],
  pubsub_server: MapsScraper.PubSub

config :maps_scraper, :scraper,
  base_url: "http://localhost:3000",
  timeout: 45_000,
  detail_budget_ms: 60_000

config :maps_scraper, :instagram,
  provider: MapsScraper.Instagram.Provider.Playwright,
  timeout: 45_000

config :maps_scraper, :tiktok, timeout: 45_000

config :maps_scraper, :apify,
  enabled: true,
  token: nil,
  base_url: "https://api.apify.com",
  timeout_s: 120,
  max_charge_usd: 0.5,
  maps_max_places: 5

config :maps_scraper, :website, timeout: 45_000

config :maps_scraper, Oban,
  engine: Oban.Engines.Lite,
  repo: MapsScraper.Repo,
  queues: [validation: 3, maintenance: 1],
  plugins: [
    {Oban.Plugins.Lifeline, rescue_after: {5, :minutes}},
    {Oban.Plugins.Pruner, max_age: {1, :day}},
    {Oban.Plugins.Cron, crontab: [{"0 20 * * *", MapsScraper.Validation.Cleaner}]}
  ]

config :maps_scraper, :marketplace, timeout: 45_000

config :maps_scraper, :subject, max_concurrency: 4

config :maps_scraper, :validation,
  concurrency: 3,
  max_attempts: 3,
  backoff_ms: 1_000,
  max_backoff_ms: 30_000,
  max_batch: 500,
  job_ttl_ms: 86_400_000,
  max_jobs: 1_000,
  max_candidates: 5,
  match_threshold: 0.8,
  review_threshold: 0.3,
  ambiguity_margin: 0.1

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
