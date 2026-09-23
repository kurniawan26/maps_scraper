defmodule MapsScraper.InstagramTest do
  use ExUnit.Case, async: true

  alias MapsScraper.Instagram

  describe "normalize_username/1" do
    test "menerima username telanjang, dengan @, dan beda kapitalisasi" do
      assert Instagram.normalize_username("kournicloud") == {:ok, "kournicloud"}
      assert Instagram.normalize_username("@kournicloud") == {:ok, "kournicloud"}
      assert Instagram.normalize_username("  KourniCloud  ") == {:ok, "kournicloud"}
      assert Instagram.normalize_username("nama.dengan_titik") == {:ok, "nama.dengan_titik"}
    end

    test "menerima URL profil dalam berbagai bentuk" do
      assert Instagram.normalize_username("https://www.instagram.com/natgeo/") == {:ok, "natgeo"}
      assert Instagram.normalize_username("https://instagram.com/natgeo") == {:ok, "natgeo"}

      assert Instagram.normalize_username("http://www.instagram.com/natgeo/?hl=id") ==
               {:ok, "natgeo"}
    end

    test "menolak URL Instagram yang bukan profil" do
      # Tanpa daftar jalur cadangan, "/p/ABC123/" terbaca sebagai akun bernama "p".
      assert {:error, {:invalid, "query", _}} =
               Instagram.normalize_username("https://www.instagram.com/p/ABC123/")

      assert {:error, {:invalid, "query", _}} =
               Instagram.normalize_username("https://www.instagram.com/reel/XYZ/")

      assert {:error, {:invalid, "query", _}} =
               Instagram.normalize_username("https://www.instagram.com/accounts/login/")

      assert {:error, {:invalid, "query", _}} =
               Instagram.normalize_username("https://www.instagram.com/")
    end

    test "menolak host yang hanya menyerupai Instagram" do
      assert {:error, _} = Instagram.normalize_username("https://instagram.com.evil.io/natgeo")
      assert {:error, _} = Instagram.normalize_username("https://not-instagram.com/natgeo")
      assert {:error, _} = Instagram.normalize_username("https://example.com/natgeo")
    end

    test "menolak bentuk yang bukan username Instagram" do
      assert {:error, _} = Instagram.normalize_username("ada spasi")
      assert {:error, _} = Instagram.normalize_username("tanda-hubung")
      assert {:error, _} = Instagram.normalize_username("emoji🙂")
      assert {:error, _} = Instagram.normalize_username(String.duplicate("a", 31))
      assert {:ok, _} = Instagram.normalize_username(String.duplicate("a", 30))
    end
  end

  describe "input_type/1" do
    test "membedakan username dari URL" do
      assert Instagram.input_type("kournicloud") == :username
      assert Instagram.input_type("https://www.instagram.com/kournicloud/") == :url
    end
  end

  describe "validate_options/1" do
    test "defaultnya en/US, bukan id/ID seperti Maps" do
      # Seluruh penanda yang dibaca sidecar — "Followers", "Profile isn't
      # available", lencana "Verified" — ikut berubah mengikuti bahasa halaman.
      assert {:ok, %{lang: "en", country: "US", name: nil}} = Instagram.validate_options(%{})
    end

    test "menerima name sebagai pembanding" do
      assert {:ok, %{name: "Warung Sate"}} =
               Instagram.validate_options(%{"name" => "  Warung Sate  "})

      assert {:ok, %{name: nil}} = Instagram.validate_options(%{"name" => "   "})
    end

    test "menolak opsi yang keliru" do
      assert {:error, {:invalid, "name", _}} = Instagram.validate_options(%{"name" => 123})

      assert {:error, {:invalid, "name", _}} =
               Instagram.validate_options(%{"name" => String.duplicate("a", 201)})

      assert {:error, {:invalid, "country", _}} =
               Instagram.validate_options(%{"country" => "Indonesia"})

      assert {:error, {:invalid, "lang", _}} = Instagram.validate_options(%{"lang" => "inggris!"})
    end
  end

  describe "lookup/1 validasi parameter" do
    test "query wajib diisi dan harus berupa akun" do
      assert {:error, {:invalid, "query", _}} = Instagram.lookup(%{})
      assert {:error, {:invalid, "query", _}} = Instagram.lookup(%{"query" => "   "})
      assert {:error, {:invalid, "query", _}} = Instagram.lookup(%{"query" => "ada spasi"})

      assert {:error, {:invalid, "query", _}} =
               Instagram.lookup(%{"query" => String.duplicate("a", 513)})
    end

    test "opsi diperiksa sebelum penyedia dipanggil" do
      assert {:error, {:invalid, "country", _}} =
               Instagram.lookup(%{"query" => "natgeo", "country" => "Indonesia"})
    end
  end

  describe "provider/0" do
    test "defaultnya sidecar Playwright milik proyek ini" do
      assert Instagram.provider() == MapsScraper.Instagram.Provider.Playwright
    end
  end
end
