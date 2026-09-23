defmodule MapsScraperWeb.PlaceControllerTest do
  use MapsScraperWeb.ConnCase, async: true

  alias MapsScraper.Scraper.Client

  @place %{
    "name" => "Monumen Nasional",
    "category" => "Monumen",
    "address" => "Gambir, Jakarta Pusat",
    "rating" => 4.6,
    "reviews_count" => 1234,
    "latitude" => -6.1754,
    "longitude" => 106.8272,
    "maps_url" => "https://www.google.com/maps/place/Monumen+Nasional"
  }

  defp stub_scraper(fun), do: Req.Test.stub(Client, fun)

  defp stub_success(payload) do
    stub_scraper(fn conn -> Req.Test.json(conn, payload) end)
  end

  describe "GET /api/places" do
    test "mencari berdasarkan nama tempat", %{conn: conn} do
      stub_success(%{"type" => "search", "query" => "monas", "count" => 1, "results" => [@place]})

      body = conn |> get(~p"/api/places", query: "monas") |> json_response(200)

      assert body["type"] == "search"
      assert body["input_type"] == "text"
      assert body["count"] == 1
      assert [%{"name" => "Monumen Nasional", "latitude" => -6.1754}] = body["results"]
    end

    test "URL Google Maps ditandai sebagai input url", %{conn: conn} do
      stub_success(%{"type" => "place", "query" => "url", "count" => 1, "results" => [@place]})

      body =
        conn
        |> get(~p"/api/places", query: "https://maps.app.goo.gl/abc123")
        |> json_response(200)

      assert body["input_type"] == "url"
      assert body["type"] == "place"
    end

    test "koordinat ditandai sebagai input coordinates", %{conn: conn} do
      stub_success(%{"type" => "search", "query" => "koordinat", "count" => 0, "results" => []})

      body = conn |> get(~p"/api/places", query: "-6.1754,106.8272") |> json_response(200)

      assert body["input_type"] == "coordinates"
      assert body["results"] == []
    end

    test "meneruskan limit dan detail ke sidecar", %{conn: conn} do
      stub_scraper(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(raw)

        assert payload["query"] == "kopi"
        assert payload["limit"] == 5
        assert payload["detail"] == true
        assert payload["lang"] == "id"

        Req.Test.json(conn, %{"type" => "search", "count" => 0, "results" => []})
      end)

      conn
      |> get(~p"/api/places", query: "kopi", limit: "5", detail: "true")
      |> json_response(200)
    end

    test "query kosong ditolak 422", %{conn: conn} do
      body = conn |> get(~p"/api/places") |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert body["error"]["field"] == "query"
    end

    test "limit di luar rentang ditolak 422", %{conn: conn} do
      body = conn |> get(~p"/api/places", query: "kopi", limit: "999") |> json_response(422)

      assert body["error"]["field"] == "limit"
    end
  end

  describe "POST /api/places" do
    test "menerima body JSON", %{conn: conn} do
      stub_success(%{"type" => "place", "count" => 1, "results" => [@place]})

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/places", %{query: "https://www.google.com/maps/place/Monas"})
        |> json_response(200)

      assert body["count"] == 1
    end
  end

  describe "penanganan error sidecar" do
    test "error dari sidecar diteruskan apa adanya", %{conn: conn} do
      stub_scraper(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => "place_not_found", "message" => "tidak ada"}})
      end)

      body = conn |> get(~p"/api/places", query: "xyz") |> json_response(404)

      assert body["error"]["code"] == "place_not_found"
    end

    test "sidecar mati menghasilkan 503", %{conn: conn} do
      stub_scraper(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      body = conn |> get(~p"/api/places", query: "kopi") |> json_response(503)

      assert body["error"]["code"] == "scraper_unavailable"
    end
  end
end
