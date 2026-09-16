defmodule MapsScraper.Repo do
  use Ecto.Repo,
    otp_app: :maps_scraper,
    adapter: Ecto.Adapters.Postgres
end
