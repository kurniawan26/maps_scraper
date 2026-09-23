defmodule MapsScraper.SubjectTest do
  # Kanal dijalankan pada proses terpisah, jadi stub Req harus dibagikan —
  # dan mode bagi-pakai hanya boleh dipakai test yang tidak paralel.
  use ExUnit.Case, async: false

  alias MapsScraper.Scraper.Client
  alias MapsScraper.Subject

  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  # Sidecar dijawab berdasarkan jalur yang diminta, jadi satu stub melayani
  # keempat kanal sekaligus.
  defp stub(handlers) do
    Req.Test.stub(Client, fn conn ->
      case Map.fetch(handlers, conn.request_path) do
        {:ok, fun} -> fun.(conn)
        :error -> flunk("kanal tak terduga dipanggil: #{conn.request_path}")
      end
    end)
  end

  defp json(payload), do: fn conn -> Req.Test.json(conn, payload) end

  defp gagal(status, code) do
    fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => %{"code" => code, "message" => code}})
    end
  end

  defp place(name, match, extra \\ %{}) do
    Map.merge(
      %{"name" => name, "address" => "Jl. Contoh No. 1", "match" => match},
      extra
    )
  end

  defp payload(found, best_match, results) do
    %{
      "found" => found,
      "best_match" => best_match,
      "count" => length(results),
      "results" => results
    }
  end

  describe "validate/1" do
    test "memeriksa seluruh kanal yang diisi, paralel" do
      stub(%{
        "/scrape" => json(payload(true, 1, [place("Warung Sate Pak Budi", 1)])),
        "/scrape/instagram" =>
          json(payload(true, 1, [%{"username" => "warungsate", "match" => 1}])),
        "/scrape/website" => json(payload(true, 1, [%{"title" => "Warung Sate", "match" => 1}])),
        "/scrape/marketplace" =>
          json(payload(true, 1, [%{"store_name" => "Warung Sate", "match" => 1}]))
      })

      {:ok, hasil} =
        Subject.validate(%{
          "name" => "Warung Sate Pak Budi",
          "google_maps_url" => "https://maps.app.goo.gl/abc",
          "instagram_url" => "instagram.com/warungsate",
          "website_url" => "warungsate.com",
          "tokopedia_url" => "tokopedia.com/warungsate"
        })

      assert hasil.name == "Warung Sate Pak Budi"
      assert hasil.checked == 4
      assert hasil.found == 4
      assert hasil.errors == 0
      assert hasil.verdicts == %{match: 4, review: 0, no_match: 0}

      assert Map.keys(hasil.channels) |> Enum.sort() == [
               :google_maps,
               :instagram,
               :tokopedia,
               :website
             ]
    end

    test "nama yang tidak cocok membuat kanal divonis tidak cocok walau ketemu" do
      # Inti pendekatan ini: tautan yang hidup belum berarti milik usaha yang
      # dimaksud. Tanpa perbandingan nama, ketiganya akan lolos begitu saja.
      stub(%{
        "/scrape/website" =>
          json(payload(true, 0, [%{"title" => "Bengkel Motor Jaya", "match" => 0}]))
      })

      {:ok, hasil} =
        Subject.validate(%{"name" => "Warung Sate Pak Budi", "website_url" => "bengkeljaya.com"})

      assert hasil.channels.website.found == true
      assert hasil.channels.website.verdict == :no_match
      assert hasil.verdicts == %{match: 0, review: 0, no_match: 1}
    end

    test "tanpa name, kanal yang ketemu ditandai untuk dinilai di luar" do
      stub(%{"/scrape" => json(payload(true, nil, [place("Entah", nil)]))})

      {:ok, hasil} = Subject.validate(%{"google_maps_url" => "https://maps.app.goo.gl/abc"})

      assert hasil.channels.google_maps.verdict == :review
    end

    test "satu kanal gagal tidak menjatuhkan kanal lain" do
      stub(%{
        "/scrape/website" => json(payload(true, 1, [%{"title" => "Warung Sate", "match" => 1}])),
        "/scrape/marketplace" => gagal(503, "shopee_blocked")
      })

      {:ok, hasil} =
        Subject.validate(%{
          "name" => "Warung Sate",
          "website_url" => "warungsate.com",
          "shopee_url" => "shopee.co.id/warungsate"
        })

      assert hasil.checked == 2
      assert hasil.errors == 1
      assert hasil.channels.website.status == :ok
      assert hasil.channels.shopee.status == :error
      assert hasil.channels.shopee.error["code"] == "shopee_blocked"
      # Kegagalan sementara ditandai supaya pemanggil tahu layak dicoba lagi.
      assert hasil.channels.shopee.retryable == true
    end

    test "menyilangkan website yang dideklarasikan Maps dengan yang dikirim" do
      # Bukti terkuat yang tersedia gratis: listing Maps memuat website milik
      # usaha itu sendiri, dan datanya sudah ikut terbawa.
      stub(%{
        "/scrape" =>
          json(
            payload(true, 1, [
              place("Warung Sate", 1, %{
                "website" => "https://www.warungsate.com/",
                "phone" => "021-123"
              })
            ])
          ),
        "/scrape/website" => json(payload(true, 1, [%{"title" => "Warung Sate", "match" => 1}]))
      })

      {:ok, hasil} =
        Subject.validate(%{
          "google_maps_url" => "https://maps.app.goo.gl/abc",
          "website_url" => "warungsate.com"
        })

      assert hasil.cross_check.website_matches_maps == true
      assert hasil.cross_check.maps_phone == "021-123"
    end

    test "website yang berbeda dari listing Maps ikut dilaporkan" do
      stub(%{
        "/scrape" =>
          json(payload(true, 1, [place("Warung Sate", 1, %{"website" => "https://lain.com/"})])),
        "/scrape/website" => json(payload(true, 1, [%{"title" => "Lain", "match" => 1}]))
      })

      {:ok, hasil} =
        Subject.validate(%{
          "google_maps_url" => "https://maps.app.goo.gl/abc",
          "website_url" => "warungsate.com"
        })

      assert hasil.cross_check.website_matches_maps == false
    end
  end

  describe "validasi masukan" do
    test "minimal satu kanal wajib diisi" do
      assert {:error, {:invalid, "channels", _}} = Subject.validate(%{"name" => "X"})
      assert {:error, {:invalid, "channels", _}} = Subject.validate(%{})
    end

    test "tautan yang salah bentuk ditolak sebelum satu pun kanal dijalankan" do
      Req.Test.stub(Client, fn _conn -> flunk("sidecar tidak boleh dipanggil") end)

      assert {:error, {:invalid, "instagram_url", _}} =
               Subject.validate(%{"instagram_url" => "instagram.com/p/ABC/"})

      assert {:error, {:invalid, "website_url", _}} =
               Subject.validate(%{"website_url" => "bukan domain"})

      assert {:error, {:invalid, "website_url", pesan}} =
               Subject.validate(%{"website_url" => "http://127.0.0.1/"})

      assert pesan =~ "alamat internal"
    end

    test "URL platform lain pada field yang salah ditolak" do
      Req.Test.stub(Client, fn _conn -> flunk("sidecar tidak boleh dipanggil") end)

      assert {:error, {:invalid, "tokopedia_url", pesan}} =
               Subject.validate(%{"tokopedia_url" => "shopee.co.id/samsung.id"})

      assert pesan =~ "shopee"

      assert {:error, {:invalid, "shopee_url", _}} =
               Subject.validate(%{"shopee_url" => "tokopedia.com/samsung"})
    end

    test "name yang keliru ditolak" do
      assert {:error, {:invalid, "name", _}} =
               Subject.validate(%{"name" => 123, "website_url" => "contoh.com"})
    end
  end
end
