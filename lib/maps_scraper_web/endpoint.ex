defmodule MapsScraperWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :maps_scraper

  # Endpoint ini hanya melayani JSON API: tidak ada berkas statis, socket
  # LiveView, maupun session cookie — semuanya tidak terpakai tanpa frontend.

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug MapsScraperWeb.Router
end
