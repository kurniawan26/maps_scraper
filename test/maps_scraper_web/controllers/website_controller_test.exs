defmodule MapsScraperWeb.WebsiteControllerTest do
  use MapsScraperWeb.ConnCase, async: true

  alias MapsScraper.Scraper.Client

  # Host berupa alamat IP publik dipakai di sepanjang test ini supaya
  # pemeriksaan alamat tidak perlu menyentuh DNS: hasilnya sama di mesin mana
  # pun dan tidak ada permintaan jaringan yang diam-diam ikut berjalan.
  @host "8.8.8.8"

  defp stub_success(payload) do
    Req.Test.stub(Client, fn conn -> Req.Test.json(conn, payload) end)
  end

  defp stub_error(status, error) do
    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => error})
    end)
  end

  defp live_payload(overrides \\ %{}) do
    site =
      Map.merge(
        %{
          "url" => "https://#{@host}/",
          "final_url" => "https://#{@host}/",
          "status" => 200,
          "title" => "Warung Sate Pak Budi",
          "description" => "Sate kambing sejak 1998",
          "redirected" => false,
          "parked" => false,
          "reason" => nil,
          "match" => 1
        },
        overrides
      )

    %{
      "type" => "website",
      "query" => @host,
      "found" => true,
      "best_match" => site["match"],
      "count" => 1,
      "reason" => nil,
      "results" => [site]
    }
  end

  describe "GET /api/website" do
    test "halaman hidup dijawab found beserta judulnya", %{conn: conn} do
      stub_success(live_payload())

      body = conn |> get(~p"/api/website", query: @host) |> json_response(200)

      assert body["found"] == true
      assert body["input_type"] == "domain"
      assert [%{"title" => "Warung Sate Pak Budi", "status" => 200}] = body["results"]
    end

    test "URL lengkap ditandai sebagai input url", %{conn: conn} do
      stub_success(live_payload())

      body = conn |> get(~p"/api/website", query: "https://#{@host}/kontak") |> json_response(200)

      assert body["input_type"] == "url"
    end

    test "halaman mati dijawab found: false dengan sebabnya", %{conn: conn} do
      stub_success(%{
        "type" => "website",
        "query" => @host,
        "found" => false,
        "best_match" => 0,
        "count" => 0,
        "reason" => "http_404",
        "results" => []
      })

      body = conn |> get(~p"/api/website", query: @host) |> json_response(200)

      assert body["found"] == false
      assert body["reason"] == "http_404"
    end

    test "alamat internal ditolak 403 tanpa menyentuh sidecar", %{conn: conn} do
      Req.Test.stub(Client, fn _conn -> flunk("sidecar tidak boleh dipanggil") end)

      body = conn |> get(~p"/api/website", query: "http://127.0.0.1:4000/") |> json_response(403)

      assert body["error"]["code"] == "blocked_address"
      assert body["error"]["field"] == "query"
    end

    test "skema selain http(s) ditolak 422", %{conn: conn} do
      Req.Test.stub(Client, fn _conn -> flunk("sidecar tidak boleh dipanggil") end)

      body = conn |> get(~p"/api/website", query: "file:///etc/passwd") |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
    end

    test "server yang memblokir kita diteruskan sebagai 503, bukan found: false", %{conn: conn} do
      # 403 dari situs tujuan berarti halamannya ada tetapi kita tidak boleh
      # melihatnya. Memvonisnya mati akan menghapus website yang sebenarnya
      # hidup dan hanya menolak bot.
      stub_error(503, %{"code" => "website_http_403", "message" => "Server menjawab 403"})

      body = conn |> get(~p"/api/website", query: @host) |> json_response(503)

      assert body["error"]["code"] == "website_http_403"
    end
  end

  describe "POST /api/website" do
    test "name dipakai sebagai pembanding nama usaha", %{conn: conn} do
      stub_success(live_payload(%{"match" => 0}))

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/website", %{query: @host, name: "Bengkel Motor Jaya"})
        |> json_response(200)

      # Halamannya hidup, tapi isinya bukan usaha yang dicari.
      assert body["found"] == true
      assert body["best_match"] == 0
    end
  end
end
