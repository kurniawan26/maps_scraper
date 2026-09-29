defmodule MapsScraper.MatchScore do
  @moduledoc """
  Skor kemiripan nama, sama persis dengan `matchScore` di sidecar
  (`scraper/src/util.js`).

  Dipakai hasil yang tidak lewat sidecar, supaya `best_match` dari Apify dan
  dari sidecar bisa dibandingkan dengan ambang vonis yang sama.
  """

  @stopwords MapSet.new(~w(di ke dan yang the of in at jl jln jalan no nomor kota kab kabupaten
                           kec kecamatan kel kelurahan rt rw provinsi))

  @coordinates ~r/^\s*-?\d{1,3}(\.\d+)?\s*,\s*-?\d{1,3}(\.\d+)?\s*$/

  def score(query, fields) when is_binary(query) and is_map(fields) do
    if Regex.match?(@coordinates, query) do
      nil
    else
      compare(tokenize(query), fields)
    end
  end

  def score(_query, _fields), do: nil

  defp compare([], _fields), do: nil

  defp compare(query_tokens, fields) do
    target =
      [fields[:name], fields[:address], fields[:category]]
      |> Enum.map(&(&1 || ""))
      |> Enum.join(" ")
      |> tokenize()

    case target do
      [] ->
        0

      words ->
        set = MapSet.new(words)

        hits =
          Enum.count(query_tokens, fn token ->
            MapSet.member?(set, token) or Enum.any?(words, &String.starts_with?(&1, token))
          end)

        Float.round(hits / length(query_tokens), 2) |> normalize()
    end
  end

  defp normalize(value) when value == trunc(value), do: trunc(value)
  defp normalize(value), do: value

  defp tokenize(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.filter(&(String.length(&1) > 1 and not MapSet.member?(@stopwords, &1)))
  end

  defp tokenize(_value), do: []
end
