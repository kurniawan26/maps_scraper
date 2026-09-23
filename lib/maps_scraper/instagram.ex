defmodule MapsScraper.Instagram do
  @moduledoc """
  Context untuk memverifikasi keberadaan akun Instagram.

  Sejalan dengan `MapsScraper.Maps`: menerima masukan, memvalidasinya, lalu
  meneruskannya ke penyedia yang dipilih config. Bedanya, Instagram tidak punya
  pencarian — satu query menunjuk tepat satu akun, entah lewat username atau URL
  profil.

  ## Tiga keadaan, bukan dua

  Instagram merender profilnya dari JavaScript, sehingga HTML mentah halaman
  akun yang ada dan yang tidak ada sama persis. Yang membedakan hanya isi DOM
  setelah skripnya jalan, dan di situ ada tiga kemungkinan — ditemukan, tidak
  ada, dan *tidak terbaca*. Yang ketiga dikembalikan sidecar sebagai error 5xx
  supaya diulang antrean, bukan dijawab `found: false`. Keliru memetakannya
  berarti menghapus akun yang sebenarnya ada hanya karena Instagram sedang
  menolak melayani.

  ## Yang tidak bisa dibedakan

  Akun yang tidak pernah ada, akun yang dihapus, dan akun yang dinonaktifkan
  menampilkan halaman yang sama persis. Ketiganya dijawab `found: false`.
  """

  @default_provider MapsScraper.Instagram.Provider.Playwright

  # Aturan Instagram sendiri: huruf, angka, titik, garis bawah, maksimal 30.
  @username_format ~r/^[a-z0-9._]{1,30}$/i

  @instagram_hosts ["instagram.com", "instagr.am", "ig.me"]

  # Segmen pertama URL Instagram yang bukan username. Tanpa daftar ini,
  # "/p/ABC123/" akan dibaca sebagai profil bernama "p".
  @reserved_paths ~w(p reel reels stories explore accounts direct tv s about
                     developer legal privacy terms api challenge oauth)

  @lang_format ~r/^[a-z]{2,3}(-[a-z]{2,4})?$/i
  @country_format ~r/^[a-z]{2}$/i

  @query_max_length 512
  @name_max_length 200

  @doc """
  Memverifikasi satu akun berdasarkan `params` yang datang dari request.

  Params yang dikenali:

    * `"query"` (wajib) — username (`kournicloud`, `@kournicloud`) atau URL profil
    * `"name"` — nama yang diharapkan, mis. nama usaha. Kalau diisi, `best_match`
      mengukur kecocokan nama itu terhadap profil, bukan sekadar kecocokan handle
    * `"lang"` / `"country"` — kode bahasa dan region (default `en` / `US`)

  """
  def lookup(params) when is_map(params) do
    with {:ok, query} <- fetch_query(params),
         {:ok, _username} <- normalize_username(query),
         {:ok, opts} <- validate_options(params) do
      case provider().fetch(query, opts) do
        {:ok, payload} -> {:ok, Map.put(payload, "input_type", to_string(input_type(query)))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Memvalidasi opsi yang berlaku untuk satu maupun sekumpulan query.

  Dipakai `lookup/1` sebelum memanggil penyedia, dan `MapsScraper.Validation`
  sebelum menerima batch — supaya opsi yang keliru ditolak sekali di depan,
  bukan menggagalkan tiap baris satu per satu setelah job terlanjur diterima.
  """
  def validate_options(params) when is_map(params) do
    with {:ok, name} <- fetch_name(params),
         {:ok, lang} <- fetch_code(params, "lang", "en", @lang_format),
         {:ok, country} <- fetch_code(params, "country", "US", @country_format) do
      {:ok, %{name: name, lang: lang, country: country}}
    end
  end

  @doc """
  Mengubah username maupun URL profil menjadi username huruf kecil.

  Mengembalikan `{:error, {:invalid, "query", _}}` untuk masukan yang bukan
  keduanya — termasuk URL Instagram yang menunjuk postingan atau reel, bukan
  profil.
  """
  def normalize_username(query) when is_binary(query) do
    trimmed = String.trim(query)

    resolved =
      if url?(trimmed), do: username_from_url(trimmed), else: bare_username(trimmed)

    case resolved do
      nil -> {:error, {:invalid, "query", "bukan username maupun URL profil Instagram"}}
      username -> {:ok, username}
    end
  end

  @doc "Menebak bentuk input agar klien tahu bagaimana query diperlakukan."
  def input_type(query) when is_binary(query) do
    if query |> String.trim() |> url?(), do: :url, else: :username
  end

  @doc "Penyedia yang sedang dipakai. Lihat `MapsScraper.Instagram.Provider`."
  def provider do
    :maps_scraper
    |> Application.get_env(:instagram, [])
    |> Keyword.get(:provider, @default_provider)
  end

  defp url?(query), do: Regex.match?(~r|^https?://|i, query)

  defp username_from_url(query) do
    with %URI{scheme: scheme, host: host, path: path} when scheme in ["http", "https"] <-
           URI.parse(query),
         true <- is_binary(host),
         host = host |> String.replace_prefix("www.", "") |> String.downcase(),
         true <- host in @instagram_hosts,
         [first | _] <- path |> to_string() |> String.split("/", trim: true),
         false <- String.downcase(first) in @reserved_paths do
      bare_username(first)
    else
      _ -> nil
    end
  end

  defp bare_username(value) do
    candidate = String.replace_prefix(value, "@", "")

    if Regex.match?(@username_format, candidate), do: String.downcase(candidate), else: nil
  end

  defp fetch_query(params) do
    case params |> Map.get("query") |> normalize_query() do
      nil ->
        {:error, {:invalid, "query", "wajib diisi"}}

      query when byte_size(query) > @query_max_length ->
        {:error, {:invalid, "query", "maksimal #{@query_max_length} karakter"}}

      query ->
        {:ok, query}
    end
  end

  defp normalize_query(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_query(_), do: nil

  defp fetch_name(params) do
    case Map.get(params, "name") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          trimmed when byte_size(trimmed) > @name_max_length -> name_too_long()
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid, "name", "harus berupa teks"}}
    end
  end

  defp name_too_long,
    do: {:error, {:invalid, "name", "maksimal #{@name_max_length} karakter"}}

  # Kode bahasa/region diteruskan apa adanya ke sidecar dan masuk ke `locale`
  # context Playwright. Nilai yang bukan kode membuat pembuatan context gagal,
  # jadi bentuknya diperiksa di sini.
  defp fetch_code(params, key, default, format) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> validate_code(trimmed, key, format)
        end

      nil ->
        {:ok, default}

      _ ->
        {:error, {:invalid, key, "harus berupa teks"}}
    end
  end

  defp validate_code(value, key, format) do
    if Regex.match?(format, value) do
      {:ok, value}
    else
      {:error, {:invalid, key, "bukan kode yang dikenal"}}
    end
  end
end
