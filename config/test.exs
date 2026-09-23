import Config

# Tiap partisi test memakai berkasnya sendiri supaya test yang berjalan
# bersamaan tidak berebut satu berkas SQLite.
config :maps_scraper, MapsScraper.Repo,
  database: Path.expand("../priv/maps_scraper_test.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :maps_scraper, MapsScraperWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "2kOnIk+rMVfTVQ36Akv/b3+Ql0QZYIS4bBx32dogzcCQrzqtUxIEXak7POMPwhjS",
  server: false

# Test tidak boleh menyentuh sidecar sungguhan; Req dialihkan ke stub.
config :maps_scraper, :scraper,
  base_url: "http://sidecar.test",
  timeout: 5_000,
  req_options: [plug: {Req.Test, MapsScraper.Scraper.Client}]

# Job tidak dijalankan pekerja yang berjalan sendiri; test memanggil `drain/0`
# supaya waktunya deterministik.
config :maps_scraper, Oban, testing: :manual

# Pembebasan job yatim menyentuh database di luar sandbox test, dan tidak ada
# job yatim yang perlu dibebaskan di sini.
config :maps_scraper, rescue_orphans_on_boot: false

# Antrean diuji tanpa sidecar: lookup diarahkan ke stub.
config :maps_scraper, :validation,
  max_attempts: 3,
  max_batch: 10,
  lookup: MapsScraper.ValidationStub

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
