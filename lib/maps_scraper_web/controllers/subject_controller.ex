defmodule MapsScraperWeb.SubjectController do
  use MapsScraperWeb, :controller

  alias MapsScraper.Subject

  action_fallback MapsScraperWeb.FallbackController

  @doc """
  `POST /api/validate` — memeriksa seluruh kanal satu usaha sekaligus.

  Kanal yang tidak terbaca dilaporkan pada kanalnya sendiri; responsnya tetap
  `200` selama masukannya sah.
  """
  def create(conn, params) do
    with {:ok, payload} <- Subject.validate(params) do
      json(conn, payload)
    end
  end
end
