defmodule MapsScraper.Validation.Verdict do
  @moduledoc """
  Memadatkan satu hasil scraping menjadi jawaban validasinya.

  Fungsi murni, tanpa proses maupun database — dipisah dari pekerjanya supaya
  aturan vonis dapat diuji sendiri, dan supaya sumber baru cukup menambah satu
  klausa `candidate/2` tanpa menyentuh apa pun yang lain.
  """

  @defaults [
    max_candidates: 5,
    match_threshold: 0.8,
    review_threshold: 0.3,
    ambiguity_margin: 0.1
  ]

  @doc """
  Merangkum payload sidecar menjadi map hasil yang disimpan pada satu baris.

  Kuncinya sengaja string: isinya masuk ke kolom JSON.
  """
  def summarize(payload, source, opts \\ []) do
    settings = Keyword.merge(config(), opts)

    found = Map.get(payload, "found")
    best_match = Map.get(payload, "best_match")

    candidates =
      payload
      |> Map.get("results", [])
      |> sort_by_match()
      |> Enum.take(settings[:max_candidates])
      |> Enum.map(&candidate(&1, source))

    %{
      "found" => found,
      "best_match" => best_match,
      "verdict" => Atom.to_string(verdict(found, best_match, candidates, settings)),
      "type" => Map.get(payload, "type"),
      "input_type" => Map.get(payload, "input_type"),
      "count" => Map.get(payload, "count"),
      "candidates" => candidates
    }
  end

  @doc """
  Vonis untuk satu hasil, tanpa memangkas kandidatnya.

  Dipakai pintu gabungan, yang menyajikan hasil selengkapnya alih-alih ringkasan
  kandidat seperti pada antrean.
  """
  def decide(found, best_match, results, opts \\ []) do
    settings = Keyword.merge(config(), opts)

    verdict(found, best_match, results, settings)
  end

  @doc "Setelan vonis yang sedang berlaku."
  def config do
    Keyword.merge(@defaults, Application.get_env(:maps_scraper, :validation, []))
  end

  defp sort_by_match(results) do
    if Enum.all?(results, &is_nil(&1["match"])) do
      results
    else
      Enum.sort_by(results, &(&1["match"] || -1), :desc)
    end
  end

  # Vonis bernilai tiga arah, bukan dua, karena keputusan akhir yang butuh
  # pertimbangan sebaiknya diambil di luar service ini.
  defp verdict(_found, _best_match, [], _settings), do: :no_match
  defp verdict(found, _best_match, _candidates, _settings) when found != true, do: :no_match
  defp verdict(_found, nil, _candidates, _settings), do: :review

  defp verdict(_found, score, candidates, settings) when is_number(score) do
    cond do
      score < settings[:review_threshold] -> :no_match
      score < settings[:match_threshold] -> :review
      ambiguous?(candidates, settings) -> :review
      true -> :match
    end
  end

  defp verdict(_found, _best_match, _candidates, _settings), do: :review

  # Skor tinggi menjawab "ada yang cocok", bukan "yang mana". Ketika dua kandidat
  # teratas berimpit, pertanyaan kedua belum terjawab — dan justru itu yang perlu
  # dikirim ke penilai di luar.
  defp ambiguous?([%{"match" => first}, %{"match" => second} | _], settings)
       when is_number(first) and is_number(second) do
    first - second <= settings[:ambiguity_margin]
  end

  defp ambiguous?(_candidates, _settings), do: false

  # Kandidat dipangkas ke kolom yang dibutuhkan penilai di luar service ini.
  # Bentuknya berbeda per sumber: identitas stabil sebuah tempat adalah
  # place_id/cid/ftid, sebuah akun Instagram cukup username-nya, dan sebuah
  # halaman web adalah URL-nya.
  defp candidate(store, "marketplace") do
    Map.take(store, ~w(platform slug store_name store_url shop_id followers items rating match))
  end

  defp candidate(page, "website") do
    Map.take(page, ~w(url final_url status title description redirected parked match))
  end

  defp candidate(profile, "instagram") do
    Map.take(profile, ~w(username full_name profile_url followers verified private match))
  end

  defp candidate(place, _source) do
    Map.take(place, ~w(name address maps_url place_id cid ftid latitude longitude match))
  end
end
