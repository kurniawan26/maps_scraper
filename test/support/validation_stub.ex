defmodule MapsScraper.ValidationStub do
  @moduledoc """
  Pengganti `MapsScraper.Maps` untuk menguji antrean tanpa menyentuh sidecar.

  Perilakunya ditentukan oleh bentuk query itu sendiri, sehingga tiap test
  cukup memilih query yang sesuai:

    * `"ok:<nama>"`        — berhasil, tempat ditemukan
    * `"notfound:<nama>"`  — berhasil, tempat tidak ditemukan
    * `"weak:<nama>"`      — berhasil, tapi best_match rendah
    * `"invalid"`          — gagal permanen (parameter tidak valid)
    * `"timeout"`          — gagal sementara terus-menerus
    * `"flaky:<n>:<nama>"` — gagal sementara `n` kali, lalu berhasil
    * `"crash"`            — task-nya mati
  """

  @table :validation_stub_attempts

  @doc "Menyiapkan penghitung percobaan. Dipanggil di setup tiap test."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def lookup(%{"query" => query} = _params) do
    case query do
      "ok:" <> name -> {:ok, payload(name, found: true, best_match: 1)}
      "notfound:" <> name -> {:ok, payload(name, found: false, best_match: 0)}
      "weak:" <> name -> {:ok, payload(name, found: true, best_match: 0)}
      "invalid" -> {:error, {:invalid, "query", "tidak valid"}}
      "timeout" -> {:error, :timeout}
      "unavailable" -> {:error, :unavailable}
      "server_error" -> {:error, {:scraper, 502, %{"code" => "scrape_failed"}}}
      "crash" -> exit(:boom)
      "flaky:" <> rest -> flaky(query, rest)
      other -> {:ok, payload(other, found: true, best_match: 1)}
    end
  end

  @doc "Berapa kali sebuah query sudah dipanggil."
  def attempts(query), do: :ets.update_counter(@table, query, {2, 0}, {query, 0})

  defp flaky(query, rest) do
    [threshold, name] = String.split(rest, ":", parts: 2)
    count = :ets.update_counter(@table, query, {2, 1}, {query, 0})

    if count > String.to_integer(threshold) do
      {:ok, payload(name, found: true, best_match: 1)}
    else
      {:error, :timeout}
    end
  end

  defp payload(name, opts) do
    %{
      "type" => "place",
      "input_type" => "text",
      "found" => opts[:found],
      "best_match" => opts[:best_match],
      "count" => if(opts[:found], do: 1, else: 0),
      "results" =>
        if opts[:found] do
          [
            %{
              "name" => name,
              "address" => "Jl. Contoh No. 1",
              "maps_url" => "https://www.google.com/maps/place/#{name}",
              "place_id" => "ChIJ#{name}",
              "latitude" => -6.2,
              "longitude" => 106.8,
              "rating" => 4.5
            }
          ]
        else
          []
        end
    }
  end
end
