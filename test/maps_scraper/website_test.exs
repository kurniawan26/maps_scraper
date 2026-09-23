defmodule MapsScraper.WebsiteTest do
  use ExUnit.Case, async: true

  alias MapsScraper.Website

  defp host!(query) do
    {:ok, uri} = Website.normalize_url(query)
    uri.host
  end

  describe "normalize_url/1" do
    test "domain telanjang dinaikkan ke https" do
      assert {:ok, %URI{scheme: "https", host: "warungsate.com"}} =
               Website.normalize_url("warungsate.com")

      assert host!("www.contoh.co.id/kontak") == "www.contoh.co.id"
    end

    test "skema yang ditulis pemanggil dihormati" do
      assert {:ok, %URI{scheme: "http"}} = Website.normalize_url("http://contoh.com")
      assert {:ok, %URI{scheme: "https"}} = Website.normalize_url("https://contoh.com")
    end

    test "menolak skema selain http(s)" do
      # Tanpa penjagaan ini, "file:///etc/passwd" ikut diterima sebagai website.
      assert {:error, {:invalid, "query", _}} = Website.normalize_url("file:///etc/passwd")
      assert {:error, {:invalid, "query", _}} = Website.normalize_url("data:text/html,<h1>x")
      assert {:error, {:invalid, "query", _}} = Website.normalize_url("javascript:alert(1)")
      assert {:error, {:invalid, "query", _}} = Website.normalize_url("ftp://contoh.com")
    end

    test "menolak yang bukan nama host" do
      assert {:error, _} = Website.normalize_url("bukan domain")
      assert {:error, _} = Website.normalize_url("")
      assert {:error, _} = Website.normalize_url("-awalan-strip.com")
      assert {:error, _} = Website.normalize_url("titik..ganda.com")
    end

    test "host satu suku kata diteruskan ke pemeriksa alamat" do
      # Menolaknya di sini akan melaporkan "localhost" sebagai "bukan domain",
      # padahal sebabnya adalah ia menunjuk mesin di dalam jaringan.
      assert {:ok, %URI{host: "localhost"}} = Website.normalize_url("localhost")
      assert {:error, {:blocked, "localhost"}} = Website.lookup(%{"query" => "localhost"})
    end

    test "menerima alamat IP telanjang, yang disaring belakangan" do
      assert {:ok, %URI{host: "127.0.0.1"}} = Website.normalize_url("http://127.0.0.1:4000/")
      assert {:ok, %URI{host: "8.8.8.8"}} = Website.normalize_url("http://8.8.8.8/")
    end
  end

  describe "ensure_public/1" do
    # Seluruh kasus memakai alamat literal supaya tidak bergantung DNS —
    # hasilnya sama di mesin mana pun, dan tidak ada permintaan jaringan.
    test "meloloskan alamat publik" do
      assert Website.ensure_public(%URI{host: "8.8.8.8"}) == :ok
      assert Website.ensure_public(%URI{host: "1.1.1.1"}) == :ok
      assert Website.ensure_public(%URI{host: "2606:4700:4700::1111"}) == :ok
    end

    test "menolak loopback, jaringan privat, dan link-local" do
      for host <- ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "100.64.0.1", "0.0.0.0"] do
        assert {:error, {:blocked, ^host}} = Website.ensure_public(%URI{host: host})
      end
    end

    test "menolak endpoint metadata cloud" do
      # Sasaran SSRF paling klasik: kredensial instance ada di balik alamat ini.
      assert {:error, {:blocked, _}} = Website.ensure_public(%URI{host: "169.254.169.254"})
    end

    test "menolak loopback dan alamat internal IPv6" do
      assert {:error, {:blocked, _}} = Website.ensure_public(%URI{host: "::1"})
      assert {:error, {:blocked, _}} = Website.ensure_public(%URI{host: "fd00::1"})
      assert {:error, {:blocked, _}} = Website.ensure_public(%URI{host: "fe80::1"})
    end

    test "menolak IPv4 yang menyamar sebagai IPv6" do
      # ::ffff:127.0.0.1 adalah loopback yang ditulis dalam notasi IPv6. Tanpa
      # dikembalikan ke bentuk IPv4-nya, ia lolos dari pemeriksaan IPv6.
      assert {:error, {:blocked, _}} = Website.ensure_public(%URI{host: "::ffff:127.0.0.1"})
      assert Website.ensure_public(%URI{host: "::ffff:8.8.8.8"}) == :ok
    end

    test "menolak nama yang menunjuk loopback, bukan hanya alamatnya" do
      # Pemeriksaan berbasis nama tidak akan melihat ini; yang diperiksa harus
      # alamat hasil resolusi.
      assert {:error, {:blocked, "localhost"}} = Website.ensure_public(%URI{host: "localhost"})
    end

    test "nama yang tidak dapat diresolusi dibiarkan lewat" do
      # Itu urusan sidecar, yang menjawabnya sebagai dns_not_found — "tidak
      # ada", bukan "diblokir". Membedakannya penting bagi pemanggil.
      assert Website.ensure_public(%URI{host: "zzqq-tidak-ada-99999.invalid"}) == :ok
    end
  end

  describe "input_type/1" do
    test "membedakan URL dari domain telanjang" do
      assert Website.input_type("https://contoh.com/kontak") == :url
      assert Website.input_type("contoh.com") == :domain
    end
  end

  describe "validate_options/1" do
    test "defaultnya id/ID, mengikuti Maps" do
      assert {:ok, %{lang: "id", country: "ID", name: nil}} = Website.validate_options(%{})
    end

    test "menerima name sebagai pembanding" do
      assert {:ok, %{name: "Warung Sate"}} =
               Website.validate_options(%{"name" => "  Warung Sate  "})
    end

    test "menolak opsi yang keliru" do
      assert {:error, {:invalid, "name", _}} = Website.validate_options(%{"name" => 123})

      assert {:error, {:invalid, "name", _}} =
               Website.validate_options(%{"name" => String.duplicate("a", 201)})

      assert {:error, {:invalid, "country", _}} =
               Website.validate_options(%{"country" => "Indonesia"})
    end
  end

  describe "lookup/1 validasi parameter" do
    test "query wajib diisi dan harus berupa alamat" do
      assert {:error, {:invalid, "query", _}} = Website.lookup(%{})
      assert {:error, {:invalid, "query", _}} = Website.lookup(%{"query" => "   "})
      assert {:error, {:invalid, "query", _}} = Website.lookup(%{"query" => "bukan domain"})

      assert {:error, {:invalid, "query", _}} =
               Website.lookup(%{"query" => String.duplicate("a", 513)})
    end

    test "alamat internal ditolak sebelum sidecar dipanggil" do
      assert {:error, {:blocked, "127.0.0.1"}} =
               Website.lookup(%{"query" => "http://127.0.0.1:4000/api/health"})

      assert {:error, {:blocked, _}} =
               Website.lookup(%{"query" => "http://169.254.169.254/latest/meta-data/"})
    end
  end
end
