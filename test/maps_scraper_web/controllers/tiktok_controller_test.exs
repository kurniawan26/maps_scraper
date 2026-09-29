defmodule MapsScraperWeb.TikTokControllerTest do
  use MapsScraperWeb.ConnCase, async: true

  alias MapsScraper.Scraper.Client

  @profile %{
    "username" => "dicoding",
    "full_name" => "Dicoding Indonesia",
    "bio" => "Indonesia’s top technology education provider",
    "external_url" => "dicoding.com",
    "verified" => false,
    "private" => false,
    "followers" => 129_700,
    "following" => 1,
    "videos" => 1361,
    "likes" => 3_400_000,
    "profile_url" => "https://www.tiktok.com/@dicoding",
    "match" => 1
  }

  defp stub_success(payload) do
    Req.Test.stub(Client, fn conn ->
      assert conn.request_path == "/scrape/tiktok"
      Req.Test.json(conn, payload)
    end)
  end

  defp stub_error(status, error) do
    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => error})
    end)
  end

  defp found_payload do
    %{
      "type" => "profile",
      "query" => "dicoding",
      "found" => true,
      "best_match" => 1,
      "count" => 1,
      "results" => [@profile]
    }
  end

  describe "GET /api/tiktok" do
    test "akun yang ada dijawab found beserta profilnya", %{conn: conn} do
      stub_success(found_payload())

      body = conn |> get(~p"/api/tiktok", query: "dicoding") |> json_response(200)

      assert body["found"] == true
      assert body["input_type"] == "username"
      assert [%{"username" => "dicoding", "videos" => 1361}] = body["results"]
    end

    test "URL profil ditandai sebagai input url", %{conn: conn} do
      stub_success(found_payload())

      body =
        conn
        |> get(~p"/api/tiktok", query: "https://www.tiktok.com/@dicoding")
        |> json_response(200)

      assert body["input_type"] == "url"
    end

    test "akun yang tidak ada dijawab found: false, bukan error", %{conn: conn} do
      stub_success(%{
        "type" => "profile",
        "query" => "zzqqfiktif",
        "found" => false,
        "best_match" => 0,
        "count" => 0,
        "reason" => "user_banned_or_not_found",
        "results" => []
      })

      body = conn |> get(~p"/api/tiktok", query: "zzqqfiktif") |> json_response(200)

      assert body["found"] == false
      assert body["reason"] == "user_banned_or_not_found"
    end

    test "query yang bukan akun ditolak tanpa menyentuh sidecar", %{conn: conn} do
      Req.Test.stub(Client, fn _conn -> flunk("sidecar tidak boleh dipanggil") end)

      body =
        conn
        |> get(~p"/api/tiktok", query: "https://vt.tiktok.com/ZSabc/")
        |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert body["error"]["field"] == "query"
    end

    test "WAF TikTok diteruskan sebagai 503, bukan 404", %{conn: conn} do
      # "Tidak terbaca" bukan "tidak ada". Sebagai 404, baris yang sebenarnya
      # punya akun akan dihapus pemanggil.
      stub_error(503, %{
        "code" => "tiktok_blocked",
        "message" => "TikTok tidak menyajikan data profil (WAF/captcha)"
      })

      body = conn |> get(~p"/api/tiktok", query: "dicoding") |> json_response(503)

      assert body["error"]["code"] == "tiktok_blocked"
    end
  end

  describe "POST /api/tiktok" do
    test "name dipakai sebagai pembanding nama usaha", %{conn: conn} do
      stub_success(%{
        "type" => "profile",
        "query" => "kopikenangan",
        "found" => true,
        "best_match" => 0,
        "count" => 1,
        "results" => [
          %{@profile | "username" => "kopikenangan", "full_name" => "hey", "match" => 0}
        ]
      })

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/tiktok", %{query: "kopikenangan", name: "Warung Sate Pak Budi"})
        |> json_response(200)

      # Handle-nya ada, tapi bukan milik usaha yang dicari.
      assert body["found"] == true
      assert body["best_match"] == 0
    end
  end
end
