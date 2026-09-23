defmodule MapsScraper.ValidationStub do
  @moduledoc """
  Pengganti `MapsScraper.Maps` untuk menguji antrean tanpa menyentuh sidecar.

  Perilakunya ditentukan oleh bentuk query itu sendiri, sehingga tiap test
  cukup memilih query yang sesuai:

    * `"ok:<nama>"`        — berhasil, tempat ditemukan
    * `"notfound:<nama>"`  — berhasil, tempat tidak ditemukan
    * `"weak:<nama>"`      — berhasil, tapi best_match rendah (di bawah ambang)
    * `"review:<nama>"`    — berhasil dengan best_match di pita tengah
    * `"nomatch:<nama>"`   — berhasil tanpa skor kemiripan (meniru input URL)
    * `"multi:<nama>"`     — tiga hasil, yang paling cocok bukan yang teratas
    * `"ambigu:<nama>"`    — dua kandidat teratas berskor penuh dan berimpit
    * `"invalid"`          — gagal permanen (parameter tidak valid)
    * `"timeout"`          — gagal sementara terus-menerus
    * `"flaky:<n>:<nama>"` — gagal sementara `n` kali, lalu berhasil
    * `"busy:<n>:<nama>"`  — sidecar penuh `n` kali, lalu berhasil
    * `"crash"`            — task-nya mati

  Dengan `"source" => "instagram"` pemisahnya titik, bukan titik dua, karena
  `MapsScraper.Validation` menolak baris yang bukan username Instagram yang sah
  sebelum stub ini sempat dipanggil:

    * `"ok.<username>"`       — akun ditemukan
    * `"notfound.<username>"` — akun tidak ada
    * `"blocked"`             — Instagram menolak melayani; kegagalan sementara
      yang harus diulang, bukan "akun tidak ada"

  Dengan `"source" => "website"` query harus berupa URL yang sah:

    * `"https://ok.<host>/"`         — halaman hidup
    * `"https://notfound.<host>/"`   — halaman mati
    * `"https://unreadable.<host>/"` — server memblokir kita; harus diulang

  Dengan `"source" => "marketplace"` query wajib menyebut host:

    * `"https://www.tokopedia.com/ok<slug>"`       — toko ada
    * `"https://www.tokopedia.com/notfound<slug>"` — toko tidak ada
    * `"https://shopee.co.id/blocked<slug>"`       — Shopee menolak; harus diulang
  """

  @table :validation_stub_attempts

  @doc "Menyiapkan penghitung percobaan. Dipanggil di setup tiap test."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def lookup(%{"query" => query} = params) do
    case params["source"] do
      "instagram" -> instagram(query)
      "website" -> website(query)
      "marketplace" -> marketplace(query)
      _ -> maps(query)
    end
  end

  # Host memakai TLD .invalid, yang menurut RFC 6761 tidak pernah diresolusi.
  # Itu membuat pemeriksaan alamat di MapsScraper.Website melewatkannya tanpa
  # menyentuh DNS sungguhan, dan hasilnya sama di mesin mana pun.
  # Query marketplace wajib menyebut host, jadi prefiksnya ada pada slug toko.
  defp marketplace("https://www.tokopedia.com/ok" <> slug) do
    {:ok, store_payload("tokopedia", "ok#{slug}", found: true, best_match: 1)}
  end

  defp marketplace("https://www.tokopedia.com/notfound" <> slug) do
    {:ok, store_payload("tokopedia", "notfound#{slug}", found: false, best_match: 0)}
  end

  defp marketplace("https://shopee.co.id/blocked" <> _slug) do
    {:error,
     {:scraper, 503,
      %{"code" => "shopee_blocked", "message" => "Shopee tidak mengembalikan data toko"}}}
  end

  defp marketplace(other), do: maps(other)

  defp store_payload(platform, slug, opts) do
    %{
      "type" => "marketplace",
      "platform" => platform,
      "input_type" => "url",
      "found" => opts[:found],
      "best_match" => opts[:best_match],
      "count" => if(opts[:found], do: 1, else: 0),
      "reason" => if(opts[:found], do: nil, else: "store_not_found_410"),
      "results" => if(opts[:found], do: [store(platform, slug, opts[:best_match])], else: [])
    }
  end

  defp store(platform, slug, match) do
    %{
      "platform" => platform,
      "slug" => slug,
      "store_name" => "Toko #{slug}",
      "store_url" => "https://www.tokopedia.com/#{slug}",
      "shop_id" => nil,
      "followers" => nil,
      "items" => nil,
      "rating" => nil,
      "match" => match
    }
  end

  defp website("https://ok." <> rest) do
    {:ok, site_payload(String.trim_trailing(rest, "/"), found: true, best_match: 1)}
  end

  defp website("https://notfound." <> rest) do
    {:ok, site_payload(String.trim_trailing(rest, "/"), found: false, best_match: 0)}
  end

  defp website("https://unreadable." <> _rest) do
    {:error, {:scraper, 503, %{"code" => "website_http_403", "message" => "Server menjawab 403"}}}
  end

  defp website(other), do: maps(other)

  defp site_payload(host, opts) do
    %{
      "type" => "website",
      "input_type" => "url",
      "found" => opts[:found],
      "best_match" => opts[:best_match],
      "count" => if(opts[:found], do: 1, else: 0),
      "reason" => if(opts[:found], do: nil, else: "http_404"),
      "results" => if(opts[:found], do: [site(host, opts[:best_match])], else: [])
    }
  end

  defp site(host, match) do
    %{
      "url" => "https://ok.#{host}/",
      "final_url" => "https://ok.#{host}/",
      "status" => 200,
      "title" => "Situs #{host}",
      "description" => "Deskripsi #{host}",
      "redirected" => false,
      "parked" => false,
      "reason" => nil,
      "match" => match
    }
  end

  # Bentuk payload Instagram berbeda dari Maps — kandidatnya akun, bukan tempat.
  # Query kontrol seperti "timeout" dan "crash" diteruskan ke jalur Maps supaya
  # tidak perlu ditulis dua kali.
  defp instagram("ok." <> username) do
    {:ok, profile_payload(username, found: true, best_match: 1)}
  end

  defp instagram("notfound." <> username) do
    {:ok, profile_payload(username, found: false, best_match: 0)}
  end

  defp instagram("blocked") do
    {:error,
     {:scraper, 503,
      %{"code" => "instagram_blocked", "message" => "Instagram mengalihkan ke halaman login"}}}
  end

  defp instagram(other), do: maps(other)

  defp profile_payload(username, opts) do
    %{
      "type" => "profile",
      "input_type" => "username",
      "found" => opts[:found],
      "best_match" => opts[:best_match],
      "count" => if(opts[:found], do: 1, else: 0),
      "results" => if(opts[:found], do: [profile(username, opts[:best_match])], else: [])
    }
  end

  defp profile(username, match) do
    %{
      "username" => username,
      "full_name" => String.capitalize(username),
      "profile_url" => "https://www.instagram.com/#{username}/",
      "followers" => 710,
      "following" => 513,
      "posts" => 5,
      "verified" => false,
      "private" => false,
      "match" => match
    }
  end

  defp maps(query) do
    case query do
      "ok:" <> name -> {:ok, payload(name, found: true, best_match: 1)}
      "notfound:" <> name -> {:ok, payload(name, found: false, best_match: 0)}
      "weak:" <> name -> {:ok, payload(name, found: true, best_match: 0)}
      "review:" <> name -> {:ok, payload(name, found: true, best_match: 0.5)}
      "nomatch:" <> name -> {:ok, payload(name, found: true, best_match: nil)}
      "multi:" <> name -> {:ok, multi_payload(name)}
      "ambigu:" <> name -> {:ok, ambiguous_payload(name)}
      "invalid" -> {:error, {:invalid, "query", "tidak valid"}}
      "timeout" -> {:error, :timeout}
      "unavailable" -> {:error, :unavailable}
      "server_error" -> {:error, {:scraper, 502, %{"code" => "scrape_failed"}}}
      "crash" -> exit(:boom)
      "flaky:" <> rest -> flaky(query, rest)
      "busy:" <> rest -> busy(query, rest)
      other -> {:ok, payload(other, found: true, best_match: 1)}
    end
  end

  @doc "Berapa kali sebuah query sudah dipanggil."
  def attempts(query), do: :ets.update_counter(@table, query, {2, 0}, {query, 0})

  # Sidecar penuh `n` kali, lalu berhasil. Dipakai membuktikan bahwa kemacetan
  # yang kita timbulkan sendiri tidak menghabiskan jatah retry.
  defp busy(query, rest) do
    [threshold, name] = String.split(rest, ":", parts: 2)
    count = :ets.update_counter(@table, query, {2, 1}, {query, 0})

    if count > String.to_integer(threshold) do
      {:ok, payload(name, found: true, best_match: 1)}
    else
      {:error,
       {:scraper, 503, %{"code" => "busy", "message" => "Sidecar sedang menangani 4 permintaan"}}}
    end
  end

  defp flaky(query, rest) do
    [threshold, name] = String.split(rest, ":", parts: 2)
    count = :ets.update_counter(@table, query, {2, 1}, {query, 0})

    if count > String.to_integer(threshold) do
      {:ok, payload(name, found: true, best_match: 1)}
    else
      {:error, :timeout}
    end
  end

  defp payload(name, opts) do
    %{
      "type" => "place",
      "input_type" => "text",
      "found" => opts[:found],
      "best_match" => opts[:best_match],
      "count" => if(opts[:found], do: 1, else: 0),
      "results" => if(opts[:found], do: [place(name, opts[:best_match])], else: [])
    }
  end

  # Tiga hasil dengan yang paling cocok di posisi terakhir — meniru Google yang
  # meranking tempat lain lebih dulu.
  defp multi_payload(name) do
    %{
      "type" => "search",
      "input_type" => "text",
      "found" => true,
      "best_match" => 1,
      "count" => 3,
      "results" => [place("Mirip A", 0.2), place("Mirip B", 0.5), place(name, 1)]
    }
  end

  # Dua kandidat berbeda yang sama-sama berskor penuh — persis yang terjadi pada
  # detail=true ketika beberapa tempat berbagi kecamatan dan kota yang sama.
  defp ambiguous_payload(name) do
    %{
      "type" => "search",
      "input_type" => "text",
      "found" => true,
      "best_match" => 1,
      "count" => 3,
      "results" => [place(name, 1), place("#{name} Cabang Dua", 1), place("Lain", 0.25)]
    }
  end

  defp place(name, match) do
    %{
      "name" => name,
      "address" => "Jl. Contoh No. 1",
      "maps_url" => "https://www.google.com/maps/place/#{name}",
      "place_id" => "ChIJ#{name}",
      "cid" => "4407571450964851912",
      "ftid" => "0x2e69f5d2e764b12d:0x3d2ad6e1e0e9bcc8",
      "latitude" => -6.2,
      "longitude" => 106.8,
      "rating" => 4.5,
      "match" => match
    }
  end
end
