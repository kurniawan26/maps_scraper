defmodule MapsScraper.MarketplaceTest do
  use ExUnit.Case, async: true

  alias MapsScraper.Marketplace

  describe "normalize_store/1" do
    test "mengenali toko Tokopedia dengan dan tanpa skema" do
      assert {:ok, %{platform: "tokopedia", slug: "samsung"}} =
               Marketplace.normalize_store("tokopedia.com/samsung")

      assert {:ok, %{platform: "tokopedia", slug: "erafone"}} =
               Marketplace.normalize_store("https://www.tokopedia.com/erafone")
    end

    test "mengenali toko Shopee, termasuk domain negara lain" do
      assert {:ok, %{platform: "shopee", slug: "samsung.id"}} =
               Marketplace.normalize_store("shopee.co.id/samsung.id")

      assert {:ok, %{platform: "shopee", slug: "toko"}} =
               Marketplace.normalize_store("https://shopee.sg/toko?x=1")
    end

    test "menolak nama toko telanjang tanpa host" do
      # "samsung" ada di kedua platform sebagai toko yang berbeda, jadi masukan
      # tanpa host tidak punya jawaban tunggal.
      assert {:error, {:invalid, "query", _}} = Marketplace.normalize_store("samsung")
      assert {:error, {:invalid, "query", _}} = Marketplace.normalize_store("@samsung")
    end

    test "menolak jalur yang bukan halaman toko" do
      # Tanpa daftar jalur cadangan, "tokopedia.com/search" terbaca sebagai toko
      # bernama "search".
      assert {:error, _} = Marketplace.normalize_store("tokopedia.com/search")
      assert {:error, _} = Marketplace.normalize_store("tokopedia.com/cart")
      assert {:error, _} = Marketplace.normalize_store("shopee.co.id/daily-discover")
      assert {:error, _} = Marketplace.normalize_store("tokopedia.com/samsung/produk-abc")
      assert {:error, _} = Marketplace.normalize_store("https://www.tokopedia.com/")
    end

    test "menolak platform lain dan host yang menyerupai" do
      assert {:error, _} = Marketplace.normalize_store("bukalapak.com/samsung")
      assert {:error, _} = Marketplace.normalize_store("https://tokopedia.com.evil.io/samsung")
      assert {:error, _} = Marketplace.normalize_store("https://not-shopee.co.id/toko")
      assert {:error, _} = Marketplace.normalize_store("file:///etc/passwd")
    end
  end

  describe "platforms/0" do
    test "melaporkan platform yang didukung" do
      assert Marketplace.platforms() == ["tokopedia", "shopee"]
    end
  end

  describe "validate_options/1" do
    test "defaultnya id/ID" do
      assert {:ok, %{lang: "id", country: "ID", name: nil}} = Marketplace.validate_options(%{})
    end

    test "menerima name sebagai pembanding" do
      assert {:ok, %{name: "Warung Sate"}} =
               Marketplace.validate_options(%{"name" => "  Warung Sate  "})
    end

    test "menolak opsi yang keliru" do
      assert {:error, {:invalid, "name", _}} = Marketplace.validate_options(%{"name" => 123})

      assert {:error, {:invalid, "country", _}} =
               Marketplace.validate_options(%{"country" => "Indonesia"})
    end
  end

  describe "lookup/1 validasi parameter" do
    test "query wajib diisi dan harus berupa URL toko" do
      assert {:error, {:invalid, "query", _}} = Marketplace.lookup(%{})
      assert {:error, {:invalid, "query", _}} = Marketplace.lookup(%{"query" => "   "})
      assert {:error, {:invalid, "query", _}} = Marketplace.lookup(%{"query" => "samsung"})

      assert {:error, {:invalid, "query", _}} =
               Marketplace.lookup(%{"query" => "bukalapak.com/samsung"})
    end

    test "opsi diperiksa sebelum sidecar dipanggil" do
      assert {:error, {:invalid, "country", _}} =
               Marketplace.lookup(%{"query" => "tokopedia.com/samsung", "country" => "Indonesia"})
    end
  end
end
