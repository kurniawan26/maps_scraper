defmodule MapsScraperWeb.MarketplaceControllerTest do
  use MapsScraperWeb.ConnCase, async: true

  alias MapsScraper.Scraper.Client

  defp stub_success(payload) do
    Req.Test.stub(Client, fn conn -> Req.Test.json(conn, payload) end)
  end

  defp stub_error(status, error) do
    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => error})
    end)
  end

  defp toko_payload(overrides \\ %{}) do
    store =
      Map.merge(
        %{
          "platform" => "tokopedia",
          "slug" => "samsung",
          "store_name" => "Samsung",
          "store_url" => "https://www.tokopedia.com/samsung",
          "shop_id" => nil,
          "followers" => nil,
          "items" => nil,
          "rating" => nil,
          "match" => 1
        },
        overrides
      )

    %{
      "type" => "marketplace",
      "platform" => store["platform"],
      "query" => "tokopedia.com/samsung",
      "found" => true,
      "best_match" => store["match"],
      "count" => 1,
      "reason" => nil,
      "results" => [store]
    }
  end

  describe "GET /api/marketplace" do
    test "toko yang ada dijawab found beserta namanya", %{conn: conn} do
      stub_success(toko_payload())

      body =
        conn |> get(~p"/api/marketplace", query: "tokopedia.com/samsung") |> json_response(200)

      assert body["found"] == true
      assert body["platform"] == "tokopedia"
      assert [%{"store_name" => "Samsung"}] = body["results"]
    end

    test "toko Shopee membawa kolom tambahannya", %{conn: conn} do
      stub_success(
        toko_payload(%{
          "platform" => "shopee",
          "slug" => "samsung.id",
          "store_name" => "Sam Sung ID",
          "shop_id" => 326_058_955,
          "followers" => 2,
          "items" => 2
        })
      )

      body =
        conn |> get(~p"/api/marketplace", query: "shopee.co.id/samsung.id") |> json_response(200)

      assert [%{"shop_id" => 326_058_955, "followers" => 2}] = body["results"]
    end

    test "toko yang tidak ada dijawab found: false dengan sebabnya", %{conn: conn} do
      stub_success(%{
        "type" => "marketplace",
        "platform" => "tokopedia",
        "query" => "tokopedia.com/zzqq",
        "found" => false,
        "best_match" => 0,
        "count" => 0,
        "reason" => "store_not_found_410",
        "results" => []
      })

      body = conn |> get(~p"/api/marketplace", query: "tokopedia.com/zzqq") |> json_response(200)

      assert body["found"] == false
      assert body["reason"] == "store_not_found_410"
    end

    test "nama toko telanjang ditolak tanpa menyentuh sidecar", %{conn: conn} do
      Req.Test.stub(Client, fn _conn -> flunk("sidecar tidak boleh dipanggil") end)

      body = conn |> get(~p"/api/marketplace", query: "samsung") |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert body["error"]["field"] == "query"
    end

    test "verifikasi bot diteruskan sebagai 503, bukan 404", %{conn: conn} do
      # Tokopedia memasang Bot Manager pada sebagian toko. "tidak terbaca" tidak
      # boleh menjadi "toko tidak ada" — itu akan menghapus toko yang nyata.
      stub_error(503, %{
        "code" => "tokopedia_challenged",
        "message" => "Tokopedia meminta verifikasi bot"
      })

      body =
        conn |> get(~p"/api/marketplace", query: "tokopedia.com/samsung") |> json_response(503)

      assert body["error"]["code"] == "tokopedia_challenged"
    end

    test "Shopee yang tidak mengembalikan data dijawab 503", %{conn: conn} do
      stub_error(503, %{
        "code" => "shopee_blocked",
        "message" => "Shopee tidak mengembalikan data"
      })

      body =
        conn |> get(~p"/api/marketplace", query: "shopee.co.id/toko") |> json_response(503)

      assert body["error"]["code"] == "shopee_blocked"
    end
  end

  describe "POST /api/marketplace" do
    test "name dipakai sebagai pembanding nama usaha", %{conn: conn} do
      stub_success(toko_payload(%{"match" => 0}))

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/marketplace", %{query: "tokopedia.com/samsung", name: "Warung Sate"})
        |> json_response(200)

      assert body["found"] == true
      assert body["best_match"] == 0
    end
  end
end
