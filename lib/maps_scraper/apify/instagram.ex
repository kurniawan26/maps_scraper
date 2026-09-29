defmodule MapsScraper.Apify.Instagram do
  @moduledoc """
  Profil Instagram lewat actor `apify/instagram-profile-scraper`.

  Akun yang tidak ada dijawab actor dengan `error: "not_found"`. Galat lain,
  atau dataset tanpa baris untuk akun yang diminta, dianggap tidak terbaca.
  """

  alias MapsScraper.Apify.Client
  alias MapsScraper.MatchScore

  @actor "apify~instagram-profile-scraper"

  def fetch(username, query, opts) do
    with {:ok, items} <- Client.run(@actor, %{"usernames" => [username]}) do
      items
      |> Enum.find(&(downcase(&1["username"]) == username))
      |> interpret(username, query, opts)
    end
  end

  defp interpret(%{"error" => "not_found"}, _username, query, _opts) do
    {:ok,
     %{
       "type" => "profile",
       "query" => query,
       "found" => false,
       "best_match" => 0,
       "count" => 0,
       "reason" => "not_found",
       "results" => []
     }}
  end

  defp interpret(%{"username" => handle} = item, username, query, opts)
       when is_binary(handle) and not is_map_key(item, "error") do
    interpret(Map.put(item, "error", nil), username, query, opts)
  end

  defp interpret(%{"error" => nil, "username" => handle} = item, username, query, opts)
       when is_binary(handle) do
    profile = %{
      "username" => downcase(handle),
      "full_name" => item["fullName"],
      "bio" => item["biography"],
      "external_url" => item["externalUrl"],
      "verified" => item["verified"] == true,
      "private" => item["private"] == true,
      "followers" => item["followersCount"],
      "following" => item["followsCount"],
      "posts" => item["postsCount"],
      "profile_url" => "https://www.instagram.com/#{downcase(handle)}/"
    }

    match = match(profile, username, opts[:name])

    {:ok,
     %{
       "type" => "profile",
       "query" => query,
       "found" => true,
       "best_match" => match,
       "count" => 1,
       "results" => [Map.put(profile, "match", match)]
     }}
  end

  defp interpret(item, _username, _query, _opts) do
    detail = if is_map(item), do: item["errorDescription"] || item["error"], else: nil

    Client.failure(
      502,
      "apify_unreadable",
      "Apify tidak mengembalikan profil Instagram#{if detail, do: " (#{detail})"}"
    )
  end

  defp match(profile, _username, name) when is_binary(name) do
    MatchScore.score(name, %{
      name: profile["full_name"],
      address: profile["username"],
      category: profile["bio"]
    })
  end

  defp match(profile, username, _name), do: if(profile["username"] == username, do: 1, else: 0)

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_value), do: nil
end
