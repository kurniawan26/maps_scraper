import Config

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

# Antrean diuji tanpa sidecar: lookup diarahkan ke stub, dan jeda retry
# dipendekkan supaya test tidak perlu menunggu lama.
config :maps_scraper, :validation,
  concurrency: 2,
  max_attempts: 3,
  backoff_ms: 5,
  max_backoff_ms: 20,
  max_batch: 10,
  lookup: MapsScraper.ValidationStub

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
