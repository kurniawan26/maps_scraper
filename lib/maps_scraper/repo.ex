defmodule MapsScraper.Repo do
  @moduledoc """
  Penyimpanan antrean validasi.

  SQLite, bukan Postgres — dan itu pilihan sadar. Yang dibutuhkan proyek ini
  hanyalah antrean yang selamat dari restart, dengan beban beberapa job per
  detik dan satu node. SQLite memenuhinya tanpa menambah server database ke
  deployment, sehingga produksinya tetap dua container.

  Konsekuensinya ada dan harus diingat: SQLite hanya melayani satu penulis pada
  satu waktu, dan berkasnya terikat ke satu mesin. Kalau kelak aplikasi ini
  dijalankan lebih dari satu instance, penyimpanannya harus pindah ke Postgres —
  `Oban.Engines.Lite` diganti `Oban.Engines.Basic`, sisanya tidak berubah.
  """

  use Ecto.Repo,
    otp_app: :maps_scraper,
    adapter: Ecto.Adapters.SQLite3
end
