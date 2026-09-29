defmodule MapsScraper.Apify.TikTok do
  @moduledoc """
  Profil TikTok lewat actor `clockworks/tiktok-profile-scraper`.

  Actor ini mengambil video, jadi profil dibaca dari `authorMeta` video
  pertama. Akun yang tidak ada dijawab `errorCode: "NOT_FOUND"`. Galat lain,
  atau dataset kosong (mis. akun privat atau tanpa video), dianggap tidak
  terbaca.
  """

  alias MapsScraper.Apify.Client
  alias MapsScraper.MatchScore

  @actor "clockworks~tiktok-profile-scraper"

  def fetch(username, query, opts) do
    input = %{"profiles" => [username], "resultsPerPage" => 1}

    with {:ok, items} <- Client.run(@actor, input) do
      interpret(items, username, query, opts)
    end
  end

  defp interpret(items, username, query, opts) do
    cond do
      Enum.any?(items, &(&1["errorCode"] == "NOT_FOUND")) ->
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

      author = Enum.find_value(items, &author_meta/1) ->
        found(author, username, query, opts)

      true ->
        detail = Enum.find_value(items, & &1["error"])

        Client.failure(
          502,
          "apify_unreadable",
          "Apify tidak mengembalikan profil TikTok#{if detail, do: " (#{detail})"}"
        )
    end
  end

  defp author_meta(%{"authorMeta" => %{"name" => name} = author}) when is_binary(name), do: author
  defp author_meta(_item), do: nil

  defp found(author, username, query, opts) do
    handle = String.downcase(author["name"])

    profile = %{
      "username" => handle,
      "full_name" => author["nickName"],
      "bio" => blank_to_nil(author["signature"]),
      "external_url" => blank_to_nil(author["bioLink"]),
      "verified" => author["verified"] == true,
      "private" => author["privateAccount"] == true,
      "followers" => author["fans"],
      "following" => author["following"],
      "videos" => author["video"],
      "likes" => author["heart"],
      "profile_url" => "https://www.tiktok.com/@#{handle}"
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

  defp match(profile, _username, name) when is_binary(name) do
    MatchScore.score(name, %{
      name: profile["full_name"],
      address: profile["username"],
      category: profile["bio"]
    })
  end

  defp match(profile, username, _name), do: if(profile["username"] == username, do: 1, else: 0)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
