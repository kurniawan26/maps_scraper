defmodule MapsScraperWeb.SubjectControllerTest do
  use MapsScraperWeb.ConnCase, async: false

  alias MapsScraper.Scraper.Client

  setup context do
    Req.Test.set_req_test_to_shared(context)
    :ok
  end

  defp stub(handlers) do
    Req.Test.stub(Client, fn conn ->
      case Map.fetch(handlers, conn.request_path) do
        {:ok, payload} -> Req.Test.json(conn, payload)
        :error -> flunk("kanal tak terduga dipanggil: #{conn.request_path}")
      end
    end)
  end

  defp payload(found, best_match, results) do
    %{
      "found" => found,
      "best_match" => best_match,
      "count" => length(results),
      "results" => results
    }
  end

  describe "POST /api/validate" do
    test "memeriksa beberapa kanal sekaligus", %{conn: conn} do
      stub(%{
        "/scrape/website" => payload(true, 1, [%{"title" => "Warung Sate", "match" => 1}]),
        "/scrape/instagram" => payload(true, 1, [%{"username" => "warungsate", "match" => 1}])
      })

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validate", %{
          name: "Warung Sate",
          website_url: "warungsate.com",
          instagram_url: "instagram.com/warungsate"
        })
        |> json_response(200)

      assert body["checked"] == 2
      assert body["found"] == 2
      assert body["verdicts"] == %{"match" => 2, "review" => 0, "no_match" => 0}
      assert body["channels"]["website"]["verdict"] == "match"
      assert body["channels"]["instagram"]["status"] == "ok"
    end

    test "kanal yang gagal tetap dijawab 200", %{conn: conn} do
      # Satu kanal diblokir tidak boleh membuang kanal lain yang sudah terjawab.
      Req.Test.stub(Client, fn conn ->
        case conn.request_path do
          "/scrape/website" ->
            Req.Test.json(conn, payload(true, 1, [%{"title" => "Warung Sate", "match" => 1}]))

          "/scrape/marketplace" ->
            conn
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"error" => %{"code" => "shopee_blocked", "message" => "penuh"}})
        end
      end)

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validate", %{
          name: "Warung Sate",
          website_url: "warungsate.com",
          shopee_url: "shopee.co.id/warungsate"
        })
        |> json_response(200)

      assert body["errors"] == 1
      assert body["channels"]["website"]["status"] == "ok"
      assert body["channels"]["shopee"]["status"] == "error"
      assert body["channels"]["shopee"]["error"]["code"] == "shopee_blocked"
    end

    test "tanpa kanal apa pun ditolak 422", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validate", %{name: "Warung Sate"})
        |> json_response(422)

      assert body["error"]["field"] == "channels"
    end

    test "tautan salah bentuk ditolak 422 dengan nama fieldnya", %{conn: conn} do
      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/validate", %{tokopedia_url: "shopee.co.id/samsung.id"})
        |> json_response(422)

      assert body["error"]["field"] == "tokopedia_url"
    end
  end
end
