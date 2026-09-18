defmodule MapsScraper.MapsTest do
  use ExUnit.Case, async: true

  alias MapsScraper.Maps

  describe "input_type/1" do
    test "mengenali URL Google Maps dalam berbagai bentuk" do
      assert Maps.input_type("https://www.google.com/maps/place/Monas") == :url
      assert Maps.input_type("https://maps.app.goo.gl/abc123") == :url
      assert Maps.input_type("https://www.google.co.id/maps/search/kopi") == :url
    end

    test "menerima subdomain dan ccTLD Google yang sah" do
      assert Maps.input_type("https://maps.google.com/maps/place/Monas") == :url
      assert Maps.input_type("https://www.google.co.uk/maps") == :url
      assert Maps.input_type("https://www.google.de/maps") == :url
      assert Maps.input_type("https://www.google.com.au/maps") == :url
    end

    test "menolak host yang hanya menyerupai domain Google" do
      assert Maps.input_type("https://google.evil.com/maps") == :text
      assert Maps.input_type("https://google.com.attacker.io/maps/place/x") == :text
      assert Maps.input_type("https://evil-google.com/maps") == :text
      assert Maps.input_type("https://notgoogle.com/maps") == :text
      assert Maps.input_type("https://google.com.evil.co/maps") == :text
    end

    test "mengenali koordinat" do
      assert Maps.input_type("-6.1754,106.8272") == :coordinates
      assert Maps.input_type("-6.1754, 106.8272") == :coordinates
    end

    test "sisanya diperlakukan sebagai teks" do
      assert Maps.input_type("Monas Jakarta") == :text
      assert Maps.input_type("Jl. Sudirman No. 1") == :text
      assert Maps.input_type("https://example.com/maps") == :text
    end
  end

  describe "lookup/1 validasi parameter" do
    test "menolak query kosong" do
      assert {:error, {:invalid, "query", _}} = Maps.lookup(%{})
      assert {:error, {:invalid, "query", _}} = Maps.lookup(%{"query" => "   "})
    end

    test "menolak query yang terlalu panjang" do
      assert {:error, {:invalid, "query", _}} =
               Maps.lookup(%{"query" => String.duplicate("a", 513)})
    end

    test "menolak limit di luar rentang atau bukan angka" do
      assert {:error, {:invalid, "limit", _}} = Maps.lookup(%{"query" => "kopi", "limit" => "0"})
      assert {:error, {:invalid, "limit", _}} = Maps.lookup(%{"query" => "kopi", "limit" => 101})

      assert {:error, {:invalid, "limit", _}} =
               Maps.lookup(%{"query" => "kopi", "limit" => "abc"})
    end

    test "menolak kode bahasa/region yang bukan kode" do
      assert {:error, {:invalid, "lang", _}} =
               Maps.lookup(%{"query" => "kopi", "lang" => "bukan kode"})

      assert {:error, {:invalid, "country", _}} =
               Maps.lookup(%{"query" => "kopi", "country" => "IDN"})

      assert {:error, {:invalid, "lang", _}} = Maps.lookup(%{"query" => "kopi", "lang" => 1})
    end

    test "menerima kode bahasa/region yang wajar" do
      assert {:ok, opts} = Maps.validate_options(%{"lang" => "en", "country" => "US"})
      assert opts.lang == "en"
      assert opts.country == "US"

      assert {:ok, %{lang: "pt-BR"}} = Maps.validate_options(%{"lang" => "pt-BR"})
      # kosong dan tidak diisi sama-sama jatuh ke default
      assert {:ok, %{lang: "id", country: "ID"}} = Maps.validate_options(%{"lang" => "  "})
    end

    test "menolak detail yang bukan boolean" do
      assert {:error, {:invalid, "detail", _}} =
               Maps.lookup(%{"query" => "kopi", "detail" => "ya"})
    end
  end
end
