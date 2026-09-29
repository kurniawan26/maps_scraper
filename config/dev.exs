import Config

config :maps_scraper, MapsScraperWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "f0cYcMFpWVta4hWOHEAHJJvHsIEbP9lqmJOQJYSPj7wbGuc5kajEJqOVYCptdCT0"

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
