defmodule MapsScraper.Apify.Maps do
  @moduledoc """
  Tempat Google Maps lewat actor `compass/crawler-google-places`.

  URL dibuka sebagai `startUrls`; teks dan koordinat sebagai pencarian. URL
  yang tidak menghasilkan tempat dianggap tidak terbaca, sedangkan pencarian
  tanpa hasil dijawab `found: false`, sama dengan sidecar.

  Actor ini ditagih per tempat, jadi jumlah hasilnya dibatasi `:maps_max_places`.
  """

  alias MapsScraper.Apify.Client
  alias MapsScraper.MatchScore

  @actor "compass~crawler-google-places"

  def fetch(query, input_type, opts) do
    with {:ok, items} <- Client.run(@actor, input(query, input_type, opts)) do
      interpret(items, query, input_type, opts)
    end
  end

  defp input(query, :url, opts) do
    %{"startUrls" => [%{"url" => query}], "maxCrawledPlacesPerSearch" => 1}
    |> Map.put("language", opts[:lang] || "id")
  end

  defp input(query, _input_type, opts) do
    %{
      "searchStringsArray" => [query],
      "maxCrawledPlacesPerSearch" => max_places(opts),
      "language" => opts[:lang] || "id"
    }
  end

  defp max_places(opts) do
    cap =
      :maps_scraper
      |> Application.get_env(:apify, [])
      |> Keyword.get(:maps_max_places, 5)

    min(opts[:limit] || cap, cap)
  end

  defp interpret([], _query, :url, _opts),
    do: Client.failure(502, "apify_unreadable", "Apify tidak mengembalikan tempat untuk URL ini")

  defp interpret([], query, _input_type, _opts) do
    {:ok,
     %{
       "type" => "search",
       "query" => query,
       "found" => false,
       "best_match" => 0,
       "count" => 0,
       "results" => []
     }}
  end

  defp interpret(items, query, input_type, opts) do
    score_against = if input_type == :url, do: opts[:name], else: opts[:name] || query

    results =
      items
      |> Enum.filter(&is_binary(&1["title"]))
      |> Enum.map(&place/1)
      |> Enum.map(&Map.put(&1, "match", score(score_against, &1)))

    best_match =
      cond do
        results == [] -> 0
        Enum.any?(results, &is_nil(&1["match"])) -> nil
        true -> results |> Enum.map(& &1["match"]) |> Enum.max()
      end

    {:ok,
     %{
       "type" => if(input_type == :url or length(results) == 1, do: "place", else: "search"),
       "query" => query,
       "found" => results != [],
       "best_match" => best_match,
       "count" => length(results),
       "results" => results
     }}
  end

  defp place(item) do
    location = item["location"] || %{}

    %{
      "name" => item["title"],
      "category" => item["categoryName"],
      "address" => item["address"],
      "phone" => blank_to_nil(item["phone"]),
      "website" => item["website"],
      "rating" => item["totalScore"],
      "reviews_count" => item["reviewsCount"],
      "status" => status(item),
      "sponsored" => item["isAdvertisement"] == true,
      "place_id" => item["placeId"],
      "cid" => item["cid"],
      "ftid" => item["fid"],
      "latitude" => location["lat"],
      "longitude" => location["lng"],
      "maps_url" => item["url"]
    }
  end

  defp status(%{"permanentlyClosed" => true}), do: "permanently_closed"
  defp status(%{"temporarilyClosed" => true}), do: "temporarily_closed"
  defp status(_item), do: nil

  defp score(nil, _place), do: nil

  defp score(against, place) do
    MatchScore.score(against, %{
      name: place["name"],
      address: place["address"],
      category: place["category"]
    })
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
