defmodule MapsScraperWeb.InstagramControllerTest do
  use MapsScraperWeb.ConnCase, async: true

  alias MapsScraper.Scraper.Client

  @profile %{
    "username" => "kournicloud",
    "full_name" => "Kurniawan",
    "bio" => nil,
    "external_url" => "kurniawan-social.netlify.app",
    "verified" => false,
    "private" => false,
    "followers" => 710,
    "following" => 513,
    "posts" => 5,
    "profile_url" => "https://www.instagram.com/kournicloud/",
    "match" => 1
  }

  defp stub_success(payload) do
    Req.Test.stub(Client, fn conn -> Req.Test.json(conn, payload) end)
  end

  defp stub_error(status, error) do
    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => error})
    end)
  end

  defp found_payload do
    %{
      "type" => "profile",
      "query" => "kournicloud",
      "found" => true,
      "best_match" => 1,
      "count" => 1,
      "results" => [@profile]
    }
  end

  describe "GET /api/instagram" do
    test "akun yang ada dijawab found beserta profilnya", %{conn: conn} do
      stub_success(found_payload())

      body = conn |> get(~p"/api/instagram", query: "kournicloud") |> json_response(200)

      assert body["found"] == true
      assert body["best_match"] == 1
      assert body["input_type"] == "username"
      assert [%{"username" => "kournicloud", "followers" => 710}] = body["results"]
    end

    test "URL profil ditandai sebagai input url", %{conn: conn} do
      stub_success(found_payload())

      body =
        conn
        |> get(~p"/api/instagram", query: "https://www.instagram.com/kournicloud/")
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
        "results" => []
      })

      body = conn |> get(~p"/api/instagram", query: "zzqqfiktif") |> json_response(200)

      assert body["found"] == false
      assert body["results"] == []
    end

    test "query yang bukan akun ditolak tanpa menyentuh sidecar", %{conn: conn} do
      Req.Test.stub(Client, fn _conn -> flunk("sidecar tidak boleh dipanggil") end)

      body =
        conn
        |> get(~p"/api/instagram", query: "https://www.instagram.com/p/ABC/")
        |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert body["error"]["field"] == "query"
    end

    test "penolakan Instagram diteruskan sebagai 503, bukan 404", %{conn: conn} do
      # Ini pembedaan yang menentukan: "tidak terbaca" bukan "tidak ada".
      # Sebagai 404, baris yang sebenarnya punya akun akan dihapus pemanggil.
      stub_error(503, %{
        "code" => "instagram_blocked",
        "message" => "Instagram mengalihkan ke halaman login"
      })

      body = conn |> get(~p"/api/instagram", query: "natgeo") |> json_response(503)

      assert body["error"]["code"] == "instagram_blocked"
    end
  end

  describe "POST /api/instagram" do
    test "name dipakai sebagai pembanding nama usaha", %{conn: conn} do
      stub_success(%{
        "type" => "profile",
        "query" => "kournicloud",
        "found" => true,
        "best_match" => 0,
        "count" => 1,
        "results" => [Map.put(@profile, "match", 0)]
      })

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/instagram", %{query: "kournicloud", name: "Warung Sate Pak Budi"})
        |> json_response(200)

      # Akunnya ada, tapi bukan milik usaha yang dicari.
      assert body["found"] == true
      assert body["best_match"] == 0
    end
  end
end
