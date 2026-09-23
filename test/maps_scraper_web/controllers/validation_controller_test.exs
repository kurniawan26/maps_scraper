defmodule MapsScraperWeb.ValidationControllerTest do
  use MapsScraperWeb.ConnCase, async: false

  alias MapsScraper.ValidationStub

  setup do
    ValidationStub.reset()
    :ok
  end

  # Job tidak lagi dijalankan pekerja yang berjalan sendiri selama test; antrean
  # dijalankan di sini supaya waktunya deterministik, tanpa polling maupun sleep.
  defp await_done(conn, job_id) do
    drain()

    body = conn |> get(~p"/api/validations/#{job_id}") |> json_response(200)
    assert body["status"] == "done", "job belum selesai: #{inspect(body["counts"])}"
    body
  end

  describe "POST /api/validations" do
    test "menerima batch dan membalas 202 dengan job_id", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validations", %{queries: ["ok:Monas", "notfound:Fiktif"]})
        |> json_response(202)

      assert is_binary(body["job_id"])
      assert body["total"] == 2
      assert body["status"] == "running"
    end

    test "batch tidak valid ditolak 422", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validations", %{})
        |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert body["error"]["field"] == "queries"
    end

    test "batch melebihi batas ditolak 422", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validations", %{queries: for(i <- 1..11, do: "ok:#{i}")})
        |> json_response(422)

      assert body["error"]["field"] == "queries"
    end
  end

  describe "GET /api/validations/:id" do
    test "mengembalikan hasil lengkap setelah job selesai", %{conn: conn} do
      created =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validations", %{queries: ["ok:Monas", "notfound:Fiktif", "invalid"]})
        |> json_response(202)

      body = await_done(conn, created["job_id"])

      assert body["total"] == 3
      assert body["counts"]["ok"] == 2
      assert body["counts"]["error"] == 1
      assert body["verdicts"] == %{"match" => 1, "review" => 0, "no_match" => 1}
      assert body["finished_at"]

      results = Map.new(body["results"], &{&1["query"], &1})
      assert results["ok:Monas"]["found"] == true
      assert results["ok:Monas"]["verdict"] == "match"
      assert [%{"name" => "Monas"}] = results["ok:Monas"]["candidates"]
      assert results["notfound:Fiktif"]["found"] == false
      assert results["invalid"]["error"]["code"] == "invalid_params"
    end

    test "job yang diulang melaporkan jumlah percobaannya", %{conn: conn} do
      created =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validations", %{queries: ["flaky:1:Monas"]})
        |> json_response(202)

      body = await_done(conn, created["job_id"])
      [result] = body["results"]

      assert result["status"] == "ok"
      assert result["attempts"] == 2
    end

    test "job tidak dikenal menghasilkan 404", %{conn: conn} do
      body = conn |> get(~p"/api/validations/entah") |> json_response(404)
      assert body["error"]["code"] == "job_not_found"
    end
  end

  describe "GET /api/validations" do
    test "melaporkan ringkasan antrean", %{conn: conn} do
      body = conn |> get(~p"/api/validations") |> json_response(200)

      # Concurrency kini ditentukan ukuran antrean Oban, bukan state GenServer.
      assert body["concurrency"] == MapsScraper.Validation.concurrency()
      assert body["max_attempts"] == 3
      assert is_integer(body["pending"])
    end
  end
end
