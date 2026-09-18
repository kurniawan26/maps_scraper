defmodule MapsScraper.Maps do
  @moduledoc """
  Context untuk pengambilan data Google Maps.

  Menerima input bervariasi — nama tempat, lokasi/alamat, koordinat, atau URL
  Google Maps — memvalidasinya, lalu meneruskannya ke sidecar Playwright.
  """

  alias MapsScraper.Maps.Client

  @short_link_hosts ["maps.app.goo.gl", "goo.gl", "g.co"]
  @google_host ~r/^([a-z0-9-]+\.)*google\.(com|[a-z]{2})(\.[a-z]{2})?$/i

  @lang_format ~r/^[a-z]{2,3}(-[a-z]{2,4})?$/i
  @country_format ~r/^[a-z]{2}$/i

  @max_limit 100
  @default_limit 20
  @query_max_length 512

  @doc """
  Mencari tempat berdasarkan `params` yang datang dari request.

  Params yang dikenali:

    * `"query"` (wajib) — nama tempat, alamat, koordinat, atau URL Google Maps
    * `"limit"` — jumlah maksimum hasil, 1..#{@max_limit} (default #{@default_limit})
    * `"detail"` — `true` untuk membuka tiap hasil dan mengambil kolom lengkap
    * `"lang"` / `"country"` — kode bahasa dan region hasil (default `id` / `ID`)

  """
  def lookup(params) when is_map(params) do
    with {:ok, query} <- fetch_query(params),
         {:ok, opts} <- validate_options(params) do
      case Client.scrape(query, opts) do
        {:ok, payload} -> {:ok, Map.put(payload, "input_type", to_string(input_type(query)))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Memvalidasi opsi yang berlaku untuk satu maupun sekumpulan query.

  Dipakai `lookup/1` sebelum memanggil sidecar, dan `MapsScraper.Validation`
  sebelum menerima batch — supaya opsi yang keliru ditolak sekali di depan,
  bukan menggagalkan tiap baris satu per satu setelah job terlanjur diterima.
  """
  def validate_options(params) when is_map(params) do
    with {:ok, limit} <- fetch_limit(params),
         {:ok, detail} <- fetch_detail(params),
         {:ok, lang} <- fetch_code(params, "lang", "id", @lang_format),
         {:ok, country} <- fetch_code(params, "country", "ID", @country_format) do
      {:ok, %{limit: limit, detail: detail, lang: lang, country: country}}
    end
  end

  @doc """
  Menebak bentuk input agar klien tahu bagaimana query diperlakukan.

  Koordinat dan teks biasa sama-sama diperlakukan sebagai pencarian; URL
  langsung dibuka sebagai halaman tempat.
  """
  def input_type(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      maps_url?(trimmed) -> :url
      coordinates?(trimmed) -> :coordinates
      true -> :text
    end
  end

  defp maps_url?(query) do
    case URI.new(query) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        host = String.replace_prefix(host, "www.", "")
        host in @short_link_hosts or Regex.match?(@google_host, host)

      _ ->
        false
    end
  end

  defp coordinates?(query) do
    Regex.match?(~r/^-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?$/, query)
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

  defp fetch_limit(params) do
    case Map.get(params, "limit") do
      nil ->
        {:ok, @default_limit}

      value when is_integer(value) ->
        validate_limit(value)

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> validate_limit(parsed)
          _ -> {:error, {:invalid, "limit", "harus berupa angka"}}
        end

      _ ->
        {:error, {:invalid, "limit", "harus berupa angka"}}
    end
  end

  defp validate_limit(value) when value in 1..@max_limit, do: {:ok, value}

  defp validate_limit(_),
    do: {:error, {:invalid, "limit", "harus di antara 1 dan #{@max_limit}"}}

  defp fetch_detail(params) do
    case Map.get(params, "detail") do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      value when value in ["true", "1"] -> {:ok, true}
      value when value in ["false", "0"] -> {:ok, false}
      _ -> {:error, {:invalid, "detail", "harus true atau false"}}
    end
  end

  # Kode bahasa/region diteruskan apa adanya ke sidecar: masuk ke `locale`
  # context Playwright dan ke parameter hl/gl pada URL. Nilai yang bukan kode
  # membuat pembuatan context gagal, jadi bentuknya diperiksa di sini.
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
