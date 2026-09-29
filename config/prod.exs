import Config

config :maps_scraper, MapsScraperWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: [
        "localhost",
        "127.0.0.1",
        "app",
        "maps_scraper_app"
      ]
    ]
  ]

config :maps_scraper, auto_migrate: true

config :logger, level: :info
