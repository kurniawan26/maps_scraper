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
    * `"crash"`            — task-nya mati

  Dengan `"source" => "instagram"` pemisahnya titik, bukan titik dua, karena
  `MapsScraper.Validation` menolak baris yang bukan username Instagram yang sah
  sebelum stub ini sempat dipanggil:

    * `"ok.<username>"`       — akun ditemukan
    * `"notfound.<username>"` — akun tidak ada
    * `"blocked"`             — Instagram menolak melayani; kegagalan sementara
      yang harus diulang, bukan "akun tidak ada"
  """

  @table :validation_stub_attempts

  @doc "Menyiapkan penghitung percobaan. Dipanggil di setup tiap test."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def lookup(%{"query" => query} = params) do
    if params["source"] == "instagram", do: instagram(query), else: maps(query)
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
      other -> {:ok, payload(other, found: true, best_match: 1)}
    end
  end

  @doc "Berapa kali sebuah query sudah dipanggil."
  def attempts(query), do: :ets.update_counter(@table, query, {2, 0}, {query, 0})

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
