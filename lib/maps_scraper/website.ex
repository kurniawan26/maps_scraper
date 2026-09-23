defmodule MapsScraper.Website do
  @moduledoc """
  Context untuk memverifikasi keberadaan sebuah halaman web.

  Sejalan dengan `MapsScraper.Maps` dan `MapsScraper.Instagram`, dan menjawab
  pertanyaan yang sama sempitnya: **apakah halaman ini hidup, dan apakah isinya
  cocok dengan nama yang dicari.** Bukan pengekstrak konten — tidak ada teks
  isi, tabel, kontak, maupun selektor CSS di sini.

  ## Kenapa ada penyaring alamat

  Berbeda dari dua sumber lain yang host-nya terkunci ke Google dan Instagram,
  sumber ini membuka URL yang ditentukan pemanggil. Tanpa penyaring, siapa pun
  yang dapat memanggil API ini bisa memakainya sebagai perantara untuk
  menjangkau apa yang hanya terlihat dari dalam jaringan — metadata cloud di
  `169.254.169.254`, Phoenix di `app:4000`, atau sidecar-nya sendiri.

  Karena itu alamat diperiksa dua kali: di sini, sebelum permintaan dikirim,
  dan lagi di sidecar untuk tiap lompatan pengalihan. Yang diperiksa adalah
  alamat hasil resolusi, bukan namanya — sebuah domain publik bisa saja
  mengarah ke `127.0.0.1`.

  ## Tiga keadaan, bukan dua

  Sama seperti Instagram: hidup, mati, dan *tidak terbaca*. Yang ketiga —
  timeout, 5xx dari server tujuan, atau 401/403/429 yang berarti kita diblokir —
  dikembalikan sebagai 5xx supaya diulang antrean. Memvonisnya mati akan
  menghapus website yang sebenarnya ada dan hanya sedang menolak bot.
  """

  alias MapsScraper.Website.Client

  @lang_format ~r/^[a-z]{2,3}(-[a-z]{2,4})?$/i
  @country_format ~r/^[a-z]{2}$/i

  @query_max_length 512
  @name_max_length 200

  # Bentuk nama host. Diperiksa di sini supaya masukan yang jelas-jelas bukan
  # alamat tidak perlu menghabiskan satu context browser untuk dibuktikan.
  #
  # Host satu suku kata ("localhost", "intranet") sengaja ikut diterima:
  # menolaknya sebagai "bukan domain" menyesatkan, padahal yang sebenarnya
  # terjadi adalah ia menunjuk mesin di dalam jaringan. `ensure_public/1` yang
  # menolaknya, dengan sebab yang tepat.
  @hostname ~r/^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/i

  @doc """
  Memverifikasi satu halaman berdasarkan `params` yang datang dari request.

  Params yang dikenali:

    * `"query"` (wajib) — URL lengkap atau nama domain (`warungsate.com`)
    * `"name"` — nama yang diharapkan, mis. nama usaha. Kalau diisi,
      `best_match` mengukur kecocokan nama itu terhadap judul dan deskripsi
      halaman; kalau tidak, `best_match` bernilai `null`
    * `"lang"` / `"country"` — kode bahasa dan region (default `id` / `ID`)

  """
  def lookup(params) when is_map(params) do
    with {:ok, query} <- fetch_query(params),
         {:ok, uri} <- normalize_url(query),
         :ok <- ensure_public(uri),
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
  Mengubah URL atau nama domain menjadi `URI` absolut.

  Domain telanjang dinaikkan ke `https`; sidecar yang menurunkannya ke `http`
  kalau ternyata situsnya memang belum berpindah.
  """
  def normalize_url(query) when is_binary(query) do
    trimmed = String.trim(query)

    candidate =
      if Regex.match?(~r|^[a-z][a-z0-9+.-]*://|i, trimmed),
        do: trimmed,
        else: "https://#{trimmed}"

    case URI.new(candidate) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if valid_host?(host), do: {:ok, uri}, else: invalid_query()

      _ ->
        invalid_query()
    end
  end

  @doc "Menebak bentuk input agar klien tahu bagaimana query diperlakukan."
  def input_type(query) when is_binary(query) do
    if query |> String.trim() |> then(&Regex.match?(~r|^[a-z][a-z0-9+.-]*://|i, &1)),
      do: :url,
      else: :domain
  end

  @doc """
  Memastikan host menunjuk alamat publik.

  Pemeriksaannya berbasis alamat hasil resolusi, bukan nama — pemeriksaan
  berbasis nama tidak akan melihat domain publik yang diarahkan ke loopback.
  Nama yang gagal diresolusi dibiarkan lewat: itu urusan sidecar, yang akan
  menjawabnya sebagai `dns_not_found` — "tidak ada", bukan "diblokir".
  """
  def ensure_public(%URI{host: host}) do
    charlist = String.to_charlist(host)

    addresses =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(charlist, family) do
          {:ok, list} -> list
          {:error, _} -> []
        end
      end)

    cond do
      addresses == [] -> :ok
      Enum.all?(addresses, &public_address?/1) -> :ok
      true -> {:error, {:blocked, host}}
    end
  end

  # ------------------------------------------------------------------
  # Alamat yang tidak boleh dijangkau
  # ------------------------------------------------------------------

  defp public_address?({0, _, _, _}), do: false
  defp public_address?({10, _, _, _}), do: false
  defp public_address?({127, _, _, _}), do: false
  defp public_address?({169, 254, _, _}), do: false
  defp public_address?({172, b, _, _}) when b in 16..31, do: false
  defp public_address?({192, 168, _, _}), do: false
  defp public_address?({100, b, _, _}) when b in 64..127, do: false
  defp public_address?({192, 0, 0, _}), do: false
  defp public_address?({192, 0, 2, _}), do: false
  defp public_address?({198, b, _, _}) when b in 18..19, do: false
  defp public_address?({198, 51, 100, _}), do: false
  defp public_address?({203, 0, 113, _}), do: false
  defp public_address?({a, _, _, _}) when a >= 224, do: false
  defp public_address?({_, _, _, _}), do: true

  # IPv4 yang dipetakan ke IPv6 menembus pemeriksaan IPv6 kalau tidak
  # dikembalikan dulu ke bentuk IPv4-nya.
  defp public_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    public_address?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  end

  defp public_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  # fc00::/7 unique local
  defp public_address?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFE00) == 0xFC00, do: false
  # fe80::/10 link-local
  defp public_address?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFFC0) == 0xFE80, do: false
  # ff00::/8 multicast
  defp public_address?({a, _, _, _, _, _, _, _}) when Bitwise.band(a, 0xFF00) == 0xFF00, do: false
  defp public_address?({_, _, _, _, _, _, _, _}), do: true

  defp public_address?(_), do: false

  # ------------------------------------------------------------------
  # Parameter
  # ------------------------------------------------------------------

  # Alamat IP telanjang lolos di sini dan disaring ensure_public/1 —
  # pemeriksaannya sama untuk IP literal maupun hasil resolusi DNS.
  defp valid_host?(host) do
    Regex.match?(@hostname, host) or match?({:ok, _}, :inet.parse_address(to_charlist(host)))
  end

  defp invalid_query,
    do: {:error, {:invalid, "query", "bukan URL maupun nama domain yang sah"}}

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
