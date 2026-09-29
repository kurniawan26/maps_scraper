defmodule MapsScraper.MatchScoreTest do
  use ExUnit.Case, async: true

  alias MapsScraper.MatchScore

  test "sama dengan matchScore di sidecar" do
    assert MatchScore.score("Monumen Nasional Jakarta", %{
             name: "Monumen Nasional",
             address: "Jl. Lapangan Monas, Kota Jakarta Pusat",
             category: "Monumen"
           }) == 1

    assert MatchScore.score("Warung Sate Pak Budi", %{name: "Sate Budi", address: nil}) == 0.5
    assert MatchScore.score("Warung Sate", %{name: "Bengkel Motor Jaya"}) == 0
    assert MatchScore.score("Kopi Kenangan", %{name: "hey", address: "kopikenangan"}) == 0.5
  end

  test "awalan kata dihitung cocok" do
    assert MatchScore.score("Mon Nas", %{name: "Monumen Nasional"}) == 1
  end

  test "koordinat dan query tanpa token tidak punya skor" do
    assert MatchScore.score("-6.1754,106.8272", %{name: "Monas"}) == nil
    assert MatchScore.score("di ke", %{name: "Monas"}) == nil
  end

  test "target kosong berskor nol" do
    assert MatchScore.score("Monas", %{name: nil, address: nil}) == 0
  end
end
