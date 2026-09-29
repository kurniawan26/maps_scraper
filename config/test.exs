import Config

config :maps_scraper, MapsScraper.Repo,
  database: Path.expand("../priv/maps_scraper_test.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :maps_scraper, MapsScraperWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "2kOnIk+rMVfTVQ36Akv/b3+Ql0QZYIS4bBx32dogzcCQrzqtUxIEXak7POMPwhjS",
  server: false

config :maps_scraper, :scraper,
  base_url: "http://sidecar.test",
  timeout: 5_000,
  req_options: [plug: {Req.Test, MapsScraper.Scraper.Client}]

config :maps_scraper, :apify,
  token: nil,
  base_url: "http://apify.test",
  req_options: [plug: {Req.Test, MapsScraper.Apify.Client}]

config :maps_scraper, Oban, testing: :manual

config :maps_scraper, rescue_orphans_on_boot: false

config :maps_scraper, :validation,
  max_attempts: 3,
  max_batch: 10,
  lookup: MapsScraper.ValidationStub

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix,
  sort_verified_routes_query_params: true
