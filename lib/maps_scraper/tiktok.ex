defmodule MapsScraper.TikTok do
  @moduledoc """
  Context untuk memverifikasi keberadaan akun TikTok.

  Mekanismenya sama dengan `MapsScraper.Instagram`: satu query menunjuk tepat
  satu akun, lewat username atau URL, dan sidecar membukanya dengan browser.

  ## Kenapa browser

  TikTok memasang WAF di depan seluruh halamannya. Permintaan HTTP polos
  dijawab `200` berisi tantangan JavaScript — untuk akun yang ada maupun yang
  tidak — jadi tanpa browser keduanya tidak bisa dibedakan. Setelah tantangan
  itu selesai, data profil sudah tertanam sebagai JSON lengkap dengan kode
  status, dan pembacaannya jauh lebih pasti daripada Instagram.

  ## Tiga keadaan, bukan dua

  Ditemukan, tidak ada, dan *tidak terbaca*. Yang ketiga — WAF yang tidak
  selesai, captcha, atau kode status yang belum dikenal — dikembalikan sebagai
  error 5xx supaya diulang antrean, bukan dijawab `found: false`.

  ## Yang tidak bisa dibedakan

  TikTok menjawab kode yang sama untuk username yang tidak pernah ada dan akun
  yang diblokir. Keduanya dijawab `found: false`.
  """

  alias MapsScraper.Apify
  alias MapsScraper.Fallback
  alias MapsScraper.TikTok.Client

  @username_format ~r/^[a-z0-9._]{1,30}$/i

  @tiktok_hosts ["tiktok.com", "m.tiktok.com"]

  @short_hosts ["vm.tiktok.com", "vt.tiktok.com"]

  @lang_format ~r/^[a-z]{2,3}(-[a-z]{2,4})?$/i
  @country_format ~r/^[a-z]{2}$/i

  @query_max_length 512
  @name_max_length 200

  @doc """
  Memverifikasi satu akun berdasarkan `params` yang datang dari request.

  Params yang dikenali:

    * `"query"` (wajib) — username (`dicoding`, `@dicoding`), URL profil, atau
      URL video (`tiktok.com/@dicoding/video/123` — yang diperiksa akunnya)
    * `"name"` — nama yang diharapkan, mis. nama usaha. Kalau diisi, `best_match`
      mengukur kecocokan nama itu terhadap profil, bukan sekadar kecocokan handle
    * `"lang"` / `"country"` — kode bahasa dan region (default `en` / `US`)

  """
  def lookup(params) when is_map(params) do
    with {:ok, query} <- fetch_query(params),
         {:ok, username} <- normalize_username(query),
         {:ok, opts} <- validate_options(params) do
      Fallback.run(
        :tiktok,
        fn -> Client.scrape(query, opts) end,
        fn -> Apify.TikTok.fetch(username, query, opts) end
      )
      |> case do
        {:ok, payload} -> {:ok, Map.put(payload, "input_type", to_string(input_type(query)))}
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
         {:ok, lang} <- fetch_code(params, "lang", "en", @lang_format),
         {:ok, country} <- fetch_code(params, "country", "US", @country_format) do
      {:ok, %{name: name, lang: lang, country: country}}
    end
  end

  @doc """
  Mengubah username maupun URL profil menjadi username huruf kecil.

  Mengembalikan `{:error, {:invalid, "query", _}}` untuk masukan yang bukan
  keduanya — termasuk tautan pendek `vt.tiktok.com`, yang tidak menyebut akun.
  """
  def normalize_username(query) when is_binary(query) do
    trimmed = String.trim(query)

    if url_like?(trimmed) do
      uri = trimmed |> with_scheme() |> URI.parse()

      if short_link?(uri) do
        {:error,
         {:invalid, "query", "tautan pendek TikTok tidak menyebut akun; pakai URL profil"}}
      else
        resolved(username_from_url(uri))
      end
    else
      resolved(bare_username(trimmed))
    end
  end

  @doc "Menebak bentuk input agar klien tahu bagaimana query diperlakukan."
  def input_type(query) when is_binary(query) do
    if query |> String.trim() |> url_like?(), do: :url, else: :username
  end

  defp resolved(nil), do: {:error, {:invalid, "query", "bukan username maupun URL profil TikTok"}}
  defp resolved(username), do: {:ok, username}

  defp url_like?(query), do: String.contains?(query, "/")

  defp with_scheme(query) do
    if Regex.match?(~r|^[a-z][a-z0-9+.-]*://|i, query), do: query, else: "https://#{query}"
  end

  defp host_of(%URI{host: host}) when is_binary(host),
    do: host |> String.replace_prefix("www.", "") |> String.downcase()

  defp host_of(_uri), do: nil

  defp short_link?(uri), do: host_of(uri) in @short_hosts

  defp username_from_url(%URI{scheme: scheme, path: path} = uri)
       when scheme in ["http", "https"] do
    with true <- host_of(uri) in @tiktok_hosts,
         ["@" <> handle | _] <- path |> to_string() |> String.split("/", trim: true) do
      match_username(handle)
    else
      _ -> nil
    end
  end

  defp username_from_url(_uri), do: nil

  defp bare_username(value), do: value |> String.replace_prefix("@", "") |> match_username()

  defp match_username(candidate) do
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
