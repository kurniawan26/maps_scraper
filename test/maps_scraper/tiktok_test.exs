defmodule MapsScraper.TikTokTest do
  use ExUnit.Case, async: true

  alias MapsScraper.TikTok

  describe "normalize_username/1" do
    test "menerima username telanjang, dengan @, dan beda kapitalisasi" do
      assert TikTok.normalize_username("dicoding") == {:ok, "dicoding"}
      assert TikTok.normalize_username("@dicoding") == {:ok, "dicoding"}
      assert TikTok.normalize_username("  DiCoding  ") == {:ok, "dicoding"}
      assert TikTok.normalize_username("nama.dengan_titik") == {:ok, "nama.dengan_titik"}
    end

    test "menerima URL profil dalam berbagai bentuk" do
      assert TikTok.normalize_username("https://www.tiktok.com/@dicoding") == {:ok, "dicoding"}
      assert TikTok.normalize_username("https://m.tiktok.com/@dicoding/") == {:ok, "dicoding"}

      assert TikTok.normalize_username("https://www.tiktok.com/@dicoding?lang=id") ==
               {:ok, "dicoding"}
    end

    test "menerima tautan tanpa skema, seperti yang biasa disalin orang" do
      assert TikTok.normalize_username("tiktok.com/@dicoding") == {:ok, "dicoding"}
      assert TikTok.normalize_username("www.tiktok.com/@dicoding") == {:ok, "dicoding"}
      assert TikTok.input_type("tiktok.com/@dicoding") == :url
    end

    test "URL video dibaca sebagai akun pemiliknya" do
      assert TikTok.normalize_username("https://www.tiktok.com/@dicoding/video/7300000000000") ==
               {:ok, "dicoding"}
    end

    test "menolak URL TikTok yang bukan profil" do
      assert {:error, {:invalid, "query", _}} =
               TikTok.normalize_username("https://www.tiktok.com/explore")

      assert {:error, {:invalid, "query", _}} =
               TikTok.normalize_username("https://www.tiktok.com/tag/kuliner")

      assert {:error, {:invalid, "query", _}} =
               TikTok.normalize_username("https://www.tiktok.com/")
    end

    test "menolak tautan pendek dengan pesan yang menjelaskan sebabnya" do
      assert {:error, {:invalid, "query", pesan}} =
               TikTok.normalize_username("https://vt.tiktok.com/ZSabc123/")

      assert pesan =~ "tautan pendek"
      assert {:error, _} = TikTok.normalize_username("vm.tiktok.com/ZSabc123")
    end

    test "menolak host yang hanya menyerupai TikTok" do
      assert {:error, _} = TikTok.normalize_username("https://tiktok.com.evil.io/@dicoding")
      assert {:error, _} = TikTok.normalize_username("https://nottiktok.com/@dicoding")
      assert {:error, _} = TikTok.normalize_username("https://instagram.com/@dicoding")
    end

    test "menolak bentuk yang bukan username TikTok" do
      assert {:error, _} = TikTok.normalize_username("ada spasi")
      assert {:error, _} = TikTok.normalize_username("tanda-hubung")
      assert {:error, _} = TikTok.normalize_username("emoji🙂")
      assert {:error, _} = TikTok.normalize_username(String.duplicate("a", 31))
    end
  end

  describe "input_type/1" do
    test "membedakan username dari URL" do
      assert TikTok.input_type("dicoding") == :username
      assert TikTok.input_type("https://www.tiktok.com/@dicoding") == :url
    end
  end

  describe "validate_options/1" do
    test "defaultnya en/US, sama dengan Instagram" do
      assert {:ok, %{lang: "en", country: "US", name: nil}} = TikTok.validate_options(%{})
    end

    test "menerima name sebagai pembanding" do
      assert {:ok, %{name: "Warung Sate"}} =
               TikTok.validate_options(%{"name" => "  Warung Sate  "})
    end

    test "menolak opsi yang keliru" do
      assert {:error, {:invalid, "name", _}} = TikTok.validate_options(%{"name" => 123})

      assert {:error, {:invalid, "country", _}} =
               TikTok.validate_options(%{"country" => "Indonesia"})
    end
  end

  describe "lookup/1 validasi parameter" do
    test "query wajib diisi dan harus berupa akun" do
      assert {:error, {:invalid, "query", _}} = TikTok.lookup(%{})
      assert {:error, {:invalid, "query", _}} = TikTok.lookup(%{"query" => "   "})
      assert {:error, {:invalid, "query", _}} = TikTok.lookup(%{"query" => "ada spasi"})

      assert {:error, {:invalid, "query", _}} =
               TikTok.lookup(%{"query" => String.duplicate("a", 513)})
    end

    test "opsi diperiksa sebelum sidecar dipanggil" do
      assert {:error, {:invalid, "country", _}} =
               TikTok.lookup(%{"query" => "dicoding", "country" => "Indonesia"})
    end
  end
end
