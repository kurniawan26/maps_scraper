defmodule MapsScraper.Marketplace do
  @moduledoc """
  Context untuk memverifikasi keberadaan toko di marketplace.

  Mendukung **Tokopedia** dan **Shopee**, dan keduanya dibaca dengan cara yang
  berlawanan — itu hasil pengukuran, bukan selera:

    * **Tokopedia** dijawab lewat HTTP biasa, tanpa browser sama sekali. Nama
      toko ada di `og:title`, dan toko yang tidak ada dijawab `410 Gone` — status
      HTTP standar yang berarti persis itu. Browser justru ditolak Tokopedia di
      lapis HTTP/2, jadi memakainya bukan cuma mahal tapi tidak jalan.

    * **Shopee** tidak pernah merender nama toko untuk kita, dan API-nya menolak
      permintaan biasa dengan `403`. Tetapi di dalam browser, API itu dipanggil
      frontend-nya sendiri dan berhasil — jadi halamannya dibuka, lalu
      responsnya disadap.

  Akibatnya biaya keduanya jauh berbeda: satu baris Tokopedia sekitar 0,3–1
  detik tanpa context Chromium, satu baris Shopee sekitar 3 detik dengan satu
  context. Itu memengaruhi perhitungan kapasitas antrean.

  ## Kenapa nama toko telanjang tidak diterima

  `"samsung"` ada di kedua platform sebagai toko yang berbeda. Karena itu
  masukan wajib menyebut host — `tokopedia.com/samsung` atau
  `shopee.co.id/samsung.id` — dan platformnya ditentukan dari situ.
  """

  alias MapsScraper.Marketplace.Client

  @lang_format ~r/^[a-z]{2,3}(-[a-z]{2,4})?$/i
  @country_format ~r/^[a-z]{2}$/i

  @query_max_length 512
  @name_max_length 200

  @slug_format ~r/^[a-z0-9._-]{1,64}$/i

  @tokopedia_host ~r/^([a-z0-9-]+\.)?tokopedia\.com$/i

  # Shopee memakai domain berbeda per negara. Hanya shopee.co.id yang
  # benar-benar diuji; sisanya mengikuti pola yang sama.
  @shopee_host ~r/^([a-z0-9-]+\.)?shopee\.(co\.id|com|sg|ph|vn|co\.th|com\.my|com\.br|tw)$/i

  # Jalur yang bukan halaman toko. Tanpa daftar ini "tokopedia.com/search"
  # dibaca sebagai toko bernama "search".
  @tokopedia_reserved ~w(search cart help about promo discovery p find login register
                         wishlist order-list contact-us rewards)

  @shopee_reserved ~w(search cart daily-discover buyer seller help about mall product
                      shop user login register m web)

  @doc """
  Memverifikasi satu toko berdasarkan `params` yang datang dari request.

  Params yang dikenali:

    * `"query"` (wajib) — URL toko, mis. `tokopedia.com/samsung` atau
      `shopee.co.id/samsung.id`. Skema boleh dihilangkan
    * `"name"` — nama yang diharapkan, mis. nama usaha. Kalau diisi,
      `best_match` mengukur kecocokan nama itu terhadap nama toko
    * `"lang"` / `"country"` — kode bahasa dan region (default `id` / `ID`)

  """
  def lookup(params) when is_map(params) do
    with {:ok, query} <- fetch_query(params),
         {:ok, _store} <- normalize_store(query),
         {:ok, opts} <- validate_options(params) do
      case Client.scrape(query, opts) do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Memvalidasi opsi yang berlaku untuk satu maupun sekumpulan query.

  Dipakai `lookup/1` sebelum memanggil sidecar, dan `MapsScraper.Validation`
  sebelum menerima batch.
  """
  def validate_options(params) when is_map(params) do
    with {:ok, name} <- fetch_name(params),
         {:ok, lang} <- fetch_code(params, "lang", "id", @lang_format),
         {:ok, country} <- fetch_code(params, "country", "ID", @country_format) do
      {:ok, %{name: name, lang: lang, country: country}}
    end
  end

  @doc """
  Menguraikan URL toko menjadi `%{platform: _, slug: _}`.

  Menolak host di luar kedua platform, jalur yang bukan halaman toko
  (keranjang, pencarian, halaman produk), dan masukan tanpa host.
  """
  def normalize_store(query) when is_binary(query) do
    trimmed = String.trim(query)

    candidate =
      if Regex.match?(~r|^[a-z][a-z0-9+.-]*://|i, trimmed),
        do: trimmed,
        else: "https://#{trimmed}"

    with {:ok, %URI{scheme: scheme, host: host, path: path}} when scheme in ["http", "https"] <-
           URI.new(candidate),
         true <- is_binary(host),
         {:ok, platform, reserved} <- platform_for(host),
         [slug] <- path |> to_string() |> String.split("/", trim: true),
         false <- String.downcase(slug) in reserved,
         true <- Regex.match?(@slug_format, slug) do
      {:ok, %{platform: platform, slug: slug}}
    else
      _ -> {:error, {:invalid, "query", "bukan URL toko Tokopedia maupun Shopee"}}
    end
  end

  @doc "Daftar platform yang dikenali."
  def platforms, do: ["tokopedia", "shopee"]

  defp platform_for(host) do
    normalized = String.downcase(host)

    cond do
      Regex.match?(@tokopedia_host, normalized) -> {:ok, "tokopedia", @tokopedia_reserved}
      Regex.match?(@shopee_host, normalized) -> {:ok, "shopee", @shopee_reserved}
      true -> :error
    end
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
          "" ->
            {:ok, nil}

          trimmed when byte_size(trimmed) > @name_max_length ->
            {:error, {:invalid, "name", "maksimal #{@name_max_length} karakter"}}

          trimmed ->
            {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid, "name", "harus berupa teks"}}
    end
  end

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
