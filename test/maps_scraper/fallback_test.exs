defmodule MapsScraper.FallbackTest do
  use ExUnit.Case, async: false

  alias MapsScraper.Apify
  alias MapsScraper.Failure
  alias MapsScraper.Instagram
  alias MapsScraper.Maps
  alias MapsScraper.Scraper.Client
  alias MapsScraper.TikTok

  setup do
    previous = Application.get_env(:maps_scraper, :apify, [])
    Application.put_env(:maps_scraper, :apify, Keyword.put(previous, :token, "test-token"))
    on_exit(fn -> Application.put_env(:maps_scraper, :apify, previous) end)
    :ok
  end

  defp sidecar_error(code) do
    Req.Test.stub(Client, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"code" => code, "message" => code}})
    end)
  end

  defp sidecar_ok(payload) do
    Req.Test.stub(Client, fn conn -> Req.Test.json(conn, payload) end)
  end

  defp apify(items, inspect_request \\ fn _conn, _body -> :ok end) do
    Req.Test.stub(Apify.Client, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      inspect_request.(conn, Jason.decode!(raw))
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(items)
    end)
  end

  defp apify_status(status) do
    Req.Test.stub(Apify.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => %{"message" => "gagal #{status}"}})
    end)
  end

  defp apify_never do
    Req.Test.stub(Apify.Client, fn _conn -> flunk("Apify tidak boleh dipanggil") end)
  end

  @natgeo %{
    "username" => "natgeo",
    "fullName" => "National Geographic",
    "biography" => "Step into wonder",
    "externalUrl" => "http://visitstore.bio/natgeo",
    "followersCount" => 268_508_297,
    "followsCount" => 194,
    "postsCount" => 32_024,
    "verified" => true,
    "private" => false
  }

  describe "Instagram" do
    test "sidecar berhasil: Apify tidak dipanggil" do
      sidecar_ok(%{"found" => true, "best_match" => 1, "count" => 1, "results" => []})
      apify_never()

      assert {:ok, %{"provider" => "sidecar"}} = Instagram.lookup(%{"query" => "natgeo"})
    end

    test "diblokir: dijawab Apify" do
      sidecar_error("instagram_blocked")

      apify([@natgeo], fn conn, body ->
        assert conn.request_path ==
                 "/v2/acts/apify~instagram-profile-scraper/run-sync-get-dataset-items"

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
        assert body == %{"usernames" => ["natgeo"]}
      end)

      assert {:ok, payload} = Instagram.lookup(%{"query" => "https://www.instagram.com/natgeo/"})

      assert payload["provider"] == "apify"
      assert payload["fallback_from"] == "instagram_blocked"
      assert payload["found"] == true
      assert payload["best_match"] == 1
      assert payload["input_type"] == "url"

      assert [%{"username" => "natgeo", "followers" => 268_508_297, "verified" => true}] =
               payload["results"]
    end

    test "profil dengan error: null juga diterima" do
      sidecar_error("instagram_blocked")
      apify([Map.put(@natgeo, "error", nil)])

      assert {:ok, %{"found" => true}} = Instagram.lookup(%{"query" => "natgeo"})
    end

    test "name dibandingkan dengan profil dari Apify" do
      sidecar_error("instagram_unreadable")
      apify([@natgeo])

      assert {:ok, %{"best_match" => 0}} =
               Instagram.lookup(%{"query" => "natgeo", "name" => "Warung Sate Pak Budi"})
    end

    test "not_found dari Apify berarti akun tidak ada" do
      sidecar_error("instagram_blocked")

      apify([
        %{
          "username" => "zzqqfiktif",
          "error" => "not_found",
          "errorDescription" => "Post does not exist"
        }
      ])

      assert {:ok, %{"found" => false, "provider" => "apify", "results" => []}} =
               Instagram.lookup(%{"query" => "zzqqfiktif"})
    end

    test "jawaban Apify yang ambigu tetap tidak terbaca, bukan tidak ada" do
      sidecar_error("instagram_blocked")
      apify([%{"username" => "natgeo", "error" => "rate_limited"}])

      assert {:error, {:scraper, 503, detail} = reason} = Instagram.lookup(%{"query" => "natgeo"})
      assert detail["code"] == "instagram_blocked"
      assert detail["fallback_error"]["code"] == "apify_unreadable"
      assert Failure.retryable?(reason)
    end

    test "Apify gagal: galat sidecar dikembalikan dan tetap diulang" do
      sidecar_error("instagram_blocked")
      apify_status(402)

      assert {:error, {:scraper, 503, detail} = reason} = Instagram.lookup(%{"query" => "natgeo"})
      assert detail["fallback_error"]["code"] == "apify_http_402"
      assert Failure.retryable?(reason)
    end

    test "busy tidak memicu fallback" do
      sidecar_error("busy")
      apify_never()

      assert {:error, {:scraper, 503, %{"code" => "busy"}}} =
               Instagram.lookup(%{"query" => "natgeo"})
    end

    test "tanpa token, fallback mati" do
      Application.put_env(
        :maps_scraper,
        :apify,
        Keyword.put(Application.get_env(:maps_scraper, :apify), :token, nil)
      )

      sidecar_error("instagram_blocked")
      apify_never()

      assert {:error, {:scraper, 503, detail}} = Instagram.lookup(%{"query" => "natgeo"})
      refute Map.has_key?(detail, "fallback_error")
    end

    test "APIFY_FALLBACK=false mematikan fallback walau token ada" do
      Application.put_env(
        :maps_scraper,
        :apify,
        Keyword.put(Application.get_env(:maps_scraper, :apify), :enabled, false)
      )

      sidecar_error("instagram_blocked")
      apify_never()

      assert {:error, _} = Instagram.lookup(%{"query" => "natgeo"})
    end
  end

  describe "TikTok" do
    test "diblokir: profil dibaca dari authorMeta" do
      sidecar_error("tiktok_blocked")

      apify(
        [
          %{
            "authorMeta" => %{
              "name" => "dicoding",
              "nickName" => "Dicoding Indonesia",
              "verified" => false,
              "privateAccount" => false,
              "signature" => "Indonesia’s top technology education provider",
              "bioLink" => "dicoding.com",
              "fans" => 129_800,
              "following" => 1,
              "video" => 1361,
              "heart" => 3_400_000
            }
          }
        ],
        fn conn, body ->
          assert conn.request_path =~ "clockworks~tiktok-profile-scraper"
          assert body == %{"profiles" => ["dicoding"], "resultsPerPage" => 1}
        end
      )

      assert {:ok, payload} =
               TikTok.lookup(%{"query" => "tiktok.com/@dicoding", "name" => "Dicoding Indonesia"})

      assert payload["provider"] == "apify"
      assert payload["best_match"] == 1

      assert [%{"username" => "dicoding", "videos" => 1361, "external_url" => "dicoding.com"}] =
               payload["results"]
    end

    test "NOT_FOUND dari Apify berarti akun tidak ada" do
      sidecar_error("tiktok_unreadable")

      apify([
        %{
          "error" => "This profile/hashtag does not exist.",
          "errorCode" => "NOT_FOUND",
          "input" => "zzqqfiktif"
        }
      ])

      assert {:ok, %{"found" => false, "provider" => "apify"}} =
               TikTok.lookup(%{"query" => "zzqqfiktif"})
    end

    test "dataset kosong tidak terbaca, bukan tidak ada" do
      sidecar_error("tiktok_blocked")
      apify([])

      assert {:error, {:scraper, 503, %{"fallback_error" => %{"code" => "apify_unreadable"}}}} =
               TikTok.lookup(%{"query" => "akunprivat"})
    end
  end

  describe "Maps" do
    @monas %{
      "title" => "Monumen Nasional",
      "address" => "Jalan Lapangan Monas, Gambir, Kota Jakarta Pusat",
      "categoryName" => "Monumen",
      "placeId" => "ChIJLbFk59L1aS4RyLzp4OHWKj0",
      "cid" => "4407571450964851912",
      "fid" => "0x2e69f5d2e764b12d:0x3d2ad6e1e0e9bcc8",
      "url" => "https://www.google.com/maps/search/?api=1&query=Monumen%20Nasional",
      "phone" => "+62 21 3853040",
      "website" => nil,
      "location" => %{"lat" => -6.1753083, "lng" => 106.8271106},
      "totalScore" => 4.6,
      "reviewsCount" => 122_613,
      "permanentlyClosed" => false,
      "temporarilyClosed" => false
    }

    test "captcha Google: pencarian dijawab Apify, dibatasi maps_max_places" do
      sidecar_error("maps_blocked")

      apify([@monas], fn _conn, body ->
        assert body == %{
                 "searchStringsArray" => ["Monumen Nasional Jakarta"],
                 "maxCrawledPlacesPerSearch" => 5,
                 "language" => "id"
               }
      end)

      assert {:ok, payload} = Maps.lookup(%{"query" => "Monumen Nasional Jakarta"})

      assert payload["provider"] == "apify"
      assert payload["fallback_from"] == "maps_blocked"
      assert payload["best_match"] == 1

      assert [
               %{
                 "name" => "Monumen Nasional",
                 "place_id" => "ChIJLbFk59L1aS4RyLzp4OHWKj0",
                 "ftid" => "0x2e69f5d2e764b12d:0x3d2ad6e1e0e9bcc8",
                 "latitude" => -6.1753083,
                 "rating" => 4.6
               }
             ] = payload["results"]
    end

    test "limit yang lebih kecil dihormati" do
      sidecar_error("maps_unreadable")
      apify([], fn _conn, body -> assert body["maxCrawledPlacesPerSearch"] == 2 end)

      assert {:ok, %{"found" => false}} = Maps.lookup(%{"query" => "tempat fiktif", "limit" => 2})
    end

    test "URL dibuka lewat startUrls, dan hasil kosong tidak terbaca" do
      url = "https://www.google.com/maps/place/Monumen+Nasional/@-6.17,106.82,17z"
      sidecar_error("maps_blocked")
      apify([], fn _conn, body -> assert body["startUrls"] == [%{"url" => url}] end)

      assert {:error, {:scraper, 503, %{"fallback_error" => %{"code" => "apify_unreadable"}}}} =
               Maps.lookup(%{"query" => url})
    end

    test "URL tanpa name tidak diberi skor, sama dengan sidecar" do
      sidecar_error("maps_blocked")
      apify([@monas])

      assert {:ok, %{"found" => true, "best_match" => nil}} =
               Maps.lookup(%{"query" => "https://www.google.com/maps/place/Monumen+Nasional/"})
    end
  end
end
