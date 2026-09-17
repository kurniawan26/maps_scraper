defmodule MapsScraperWeb.ValidationController do
  use MapsScraperWeb, :controller

  alias MapsScraper.Validation
  alias MapsScraper.Validation.Job

  action_fallback MapsScraperWeb.FallbackController

  @doc """
  `POST /api/validations` — memasukkan batch query ke antrean.

  Membalas `202 Accepted` dengan `job_id`; hasilnya diambil lewat `show/2`.
  """
  def create(conn, params) do
    with {:ok, job} <- Validation.enqueue(params) do
      conn
      |> put_status(:accepted)
      |> json(Job.to_map(job))
    end
  end

  @doc "`GET /api/validations/:id` — status dan hasil job."
  def show(conn, %{"id" => job_id}) do
    case Validation.fetch(job_id) do
      {:ok, job} ->
        json(conn, Job.to_map(job))

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: %{code: "job_not_found", message: "Job tidak dikenal atau sudah hilang"}
        })
    end
  end

  @doc "`GET /api/validations` — ringkasan antrean."
  def index(conn, _params), do: json(conn, Validation.stats())
end
