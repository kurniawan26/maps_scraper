defmodule MapsScraper.Subject do
  @moduledoc """
  Satu pintu untuk memeriksa seluruh kanal sebuah usaha sekaligus.

  Satu permintaan membawa nama usaha beserta tautan kanalnya, dan tiap kanal
  yang diisi diperiksa **paralel** oleh context-nya masing-masing.

  ## Kenapa field-nya diberi nama, bukan daftar

  Menamai kanalnya menghapus dua ambiguitas yang sebelumnya memaksa masukan
  ditolak: `"samsung"` tidak lagi perlu ditebak milik Tokopedia atau Shopee, dan
  `name` akhirnya punya tempat yang benar — ia milik usahanya, bukan milik satu
  baris query.

  ## `name` dipakai untuk membandingkan, bukan untuk mencari

  Tiap kanal tetap diambil lewat tautan yang kamu berikan. `name` dipakai
  sesudahnya, untuk menilai apakah yang ketemu memang usaha yang dimaksud.
  Tanpa itu, sebuah tautan Maps yang ternyata menunjuk bengkel motor tetap
  dilaporkan "ketemu" — karena memang ketemu.

  ## Satu kanal gagal tidak menjatuhkan yang lain

  Kanal yang tidak terbaca dilaporkan `status: "error"` pada kanalnya sendiri,
  dan permintaannya tetap `200`. Menggagalkan seluruh jawaban karena satu kanal
  sedang diblokir akan membuang tiga kanal yang sudah terjawab.
  """

  alias MapsScraper.Failure
  alias MapsScraper.Instagram
  alias MapsScraper.Maps
  alias MapsScraper.Marketplace
  alias MapsScraper.Validation.Verdict
  alias MapsScraper.Website

  # {field pada payload, nama kanal pada response, context yang mengerjakannya}
  @channels [
    {"google_maps_url", :google_maps, Maps},
    {"instagram_url", :instagram, Instagram},
    {"website_url", :website, Website},
    {"tokopedia_url", :tokopedia, Marketplace},
    {"shopee_url", :shopee, Marketplace}
  ]

  @option_keys ~w(lang country)

  @name_max_length 200

  @doc """
  Memeriksa satu usaha pada seluruh kanal yang diisi.

  Params yang dikenali:

    * `"name"` — nama usaha. Dipakai membandingkan hasil tiap kanal
    * `"google_maps_url"` — URL Google Maps, juga menerima nama tempat atau alamat
    * `"instagram_url"` — URL profil atau username
    * `"website_url"` — URL atau nama domain
    * `"tokopedia_url"` / `"shopee_url"` — URL toko
    * `"lang"` / `"country"` — diteruskan ke tiap kanal

  Minimal satu kanal wajib diisi.
  """
  def validate(params) when is_map(params) do
    with {:ok, name} <- fetch_name(params),
         {:ok, channels} <- fetch_channels(params) do
      opts = Map.take(params, @option_keys)

      results =
        channels
        |> run(name, opts)
        |> Map.new()

      {:ok, assemble(name, channels, results)}
    end
  end

  @doc "Field kanal yang dikenali, berurutan."
  def channel_fields, do: Enum.map(@channels, fn {field, _key, _context} -> field end)

  # ------------------------------------------------------------------
  # Menjalankan kanal
  # ------------------------------------------------------------------

  defp run(channels, name, opts) do
    channels
    |> Task.async_stream(
      fn {_field, key, context, query} ->
        params =
          opts
          |> Map.put("query", query)
          |> maybe_put_name(name)

        {key, context.lookup(params)}
      end,
      max_concurrency: max_concurrency(),
      # Batas waktu sesungguhnya dipegang tiap client HTTP; menaruh batas kedua
      # di sini hanya akan memutus kanal yang sebenarnya masih berjalan.
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, {key, outcome}} -> {key, channel(outcome)} end)
  end

  defp maybe_put_name(params, nil), do: params
  defp maybe_put_name(params, name), do: Map.put(params, "name", name)

  defp channel({:ok, payload}) do
    results = Map.get(payload, "results", [])
    found = Map.get(payload, "found")
    best_match = Map.get(payload, "best_match")

    %{
      status: :ok,
      found: found,
      best_match: best_match,
      verdict: Verdict.decide(found, best_match, results),
      type: Map.get(payload, "type"),
      platform: Map.get(payload, "platform"),
      reason: Map.get(payload, "reason"),
      count: Map.get(payload, "count"),
      # Hasilnya dibawa utuh, tidak dipangkas seperti pada antrean — justru
      # kolom lengkap inilah yang membuat pintu ini berguna.
      results: results
    }
  end

  defp channel({:error, reason}) do
    %{status: :error, error: Failure.describe(reason), retryable: Failure.retryable?(reason)}
  end

  # ------------------------------------------------------------------
  # Merangkum
  # ------------------------------------------------------------------

  defp assemble(name, channels, results) do
    ok = for {_key, %{status: :ok} = hasil} <- results, do: hasil

    %{
      name: name,
      checked: map_size(results),
      found: Enum.count(ok, &(&1.found == true)),
      errors: map_size(results) - length(ok),
      verdicts: tally(ok),
      cross_check: cross_check(channels, results),
      channels: results
    }
  end

  defp tally(hasil) do
    Enum.reduce(hasil, %{match: 0, review: 0, no_match: 0}, fn %{verdict: verdict}, acc ->
      Map.update!(acc, verdict, &(&1 + 1))
    end)
  end

  # Listing Google Maps memuat website dan telepon yang dideklarasikan usaha itu
  # sendiri. Membandingkannya dengan website yang kamu kirim adalah bukti yang
  # jauh lebih kuat daripada kemiripan nama — dan datanya sudah ikut terbawa,
  # jadi tidak ada permintaan tambahan.
  defp cross_check(channels, results) do
    with %{status: :ok, results: [place | _]} <- Map.get(results, :google_maps),
         maps_website when is_binary(maps_website) <- place["website"] do
      dikirim =
        Enum.find_value(channels, fn {field, _key, _ctx, query} ->
          field == "website_url" && query
        end)

      %{
        maps_website: maps_website,
        maps_phone: place["phone"],
        website_matches_maps: dikirim && same_site?(maps_website, dikirim)
      }
    else
      _ -> nil
    end
  end

  defp same_site?(left, right) do
    case {host_of(left), host_of(right)} do
      {nil, _} -> false
      {_, nil} -> false
      {a, b} -> a == b
    end
  end

  defp host_of(value) do
    candidate =
      if Regex.match?(~r|^[a-z][a-z0-9+.-]*://|i, value), do: value, else: "https://#{value}"

    case URI.new(candidate) do
      {:ok, %URI{host: host}} when is_binary(host) ->
        host |> String.downcase() |> String.replace_prefix("www.", "")

      _ ->
        nil
    end
  end

  # ------------------------------------------------------------------
  # Masukan
  # ------------------------------------------------------------------

  defp fetch_channels(params) do
    channels =
      for {field, key, context} <- @channels,
          query = normalize(Map.get(params, field)),
          not is_nil(query),
          do: {field, key, context, query}

    case channels do
      [] ->
        {:error,
         {:invalid, "channels", "isi minimal satu dari: #{Enum.join(channel_fields(), ", ")}"}}

      channels ->
        validate_each(channels)
    end
  end

  # Tiap kanal memvalidasi bentuk masukannya dengan aturannya sendiri, sebelum
  # satu pun permintaan dikirim. Tautan yang salah bentuk ditolak sekarang,
  # bukan setelah empat kanal terlanjur berjalan.
  defp validate_each(channels) do
    Enum.reduce_while(channels, {:ok, channels}, fn {field, _key, _context, query}, acc ->
      case check(field, query) do
        :ok -> {:cont, acc}
        {:error, message} -> {:halt, {:error, {:invalid, field, message}}}
      end
    end)
  end

  # Maps menerima URL, nama tempat, alamat, maupun koordinat. URL memberi kolom
  # paling lengkap karena menunjuk satu tempat secara pasti; bentuk lain tetap
  # dilayani lewat pencarian.
  defp check("google_maps_url", query) do
    if byte_size(query) <= 512, do: :ok, else: {:error, "maksimal 512 karakter"}
  end

  defp check("instagram_url", query) do
    case Instagram.normalize_username(query) do
      {:ok, _username} -> :ok
      {:error, {:invalid, _field, message}} -> {:error, message}
    end
  end

  defp check("website_url", query) do
    with {:ok, uri} <- Website.normalize_url(query),
         :ok <- Website.ensure_public(uri) do
      :ok
    else
      {:error, {:invalid, _field, message}} -> {:error, message}
      {:error, {:blocked, host}} -> {:error, "#{host} mengarah ke alamat internal"}
    end
  end

  # Nama fieldnya sudah menjanjikan platformnya, jadi URL yang menunjuk platform
  # lain ditolak — itu hampir pasti salah tempat isi, bukan maksud pemanggil.
  defp check("tokopedia_url", query), do: check_store(query, "tokopedia")
  defp check("shopee_url", query), do: check_store(query, "shopee")

  defp check_store(query, expected) do
    case Marketplace.normalize_store(query) do
      {:ok, %{platform: ^expected}} ->
        :ok

      {:ok, %{platform: lain}} ->
        {:error, "ini URL #{lain}, bukan #{expected}"}

      {:error, {:invalid, _field, message}} ->
        {:error, message}
    end
  end

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

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil

  # Satu usaha memakai sampai empat context browser sekaligus (Tokopedia tidak
  # memakai satu pun). Batas ini menjaga satu permintaan tidak menghabiskan
  # seluruh kapasitas sidecar.
  defp max_concurrency do
    :maps_scraper
    |> Application.get_env(:subject, [])
    |> Keyword.get(:max_concurrency, 4)
  end
end
