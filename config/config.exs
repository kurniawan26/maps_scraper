# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure the endpoint
config :maps_scraper, ecto_repos: [MapsScraper.Repo]

# WAL membuat pembacaan tidak saling menghalangi penulisan — tanpa itu antrean
# yang sedang menulis hasil memblokir permintaan yang sedang membaca status job.
# busy_timeout memberi penulis kesempatan menunggu, bukan langsung gagal dengan
# "database is locked".
config :maps_scraper, MapsScraper.Repo,
  database: Path.expand("../priv/maps_scraper_dev.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool_size: 5

config :maps_scraper, MapsScraperWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: MapsScraperWeb.ErrorJSON], layout: false],
  pubsub_server: MapsScraper.PubSub

config :maps_scraper, :scraper,
  base_url: "http://localhost:3000",
  timeout: 45_000,
  detail_budget_ms: 60_000

# Instagram tidak punya fase detail seperti Maps: seluruh kolom profil datang
# dari satu halaman yang sama. Penyedia dapat ditukar tanpa menyentuh context —
# lihat MapsScraper.Instagram.Provider.
config :maps_scraper, :instagram,
  provider: MapsScraper.Instagram.Provider.Playwright,
  timeout: 45_000

# Sumber "website" membuka URL dari pemanggil, jadi batas waktunya harus
# menampung situs lambat tanpa menahan antrean terlalu lama.
config :maps_scraper, :website, timeout: 45_000

# Antrean validasi. Engine Lite adalah engine SQLite Oban; dengannya :notifier
# dan :peer otomatis menjadi PG dan isolated — cocok untuk satu node, dan itu
# memang bentuk deployment proyek ini.
#
# `snooze` dipakai saat sidecar penuh, dan Oban mengembalikan hitungan percobaan
# saat job di-snooze. Jadi kemacetan yang kita timbulkan sendiri tidak pernah
# menghabiskan jatah retry milik kegagalan yang sesungguhnya.
config :maps_scraper, Oban,
  engine: Oban.Engines.Lite,
  repo: MapsScraper.Repo,
  queues: [validation: 3, maintenance: 1],
  plugins: [
    # Job yang pekerjanya mati mendadak (SIGKILL, OOM) tertinggal berstatus
    # "executing" dan hanya plugin ini yang mengembalikannya ke antrean.
    # Ambangnya harus lebih lama dari scraping terlama — `detail=true` bisa
    # mendekati dua menit — tetapi tidak selama bawaannya, karena selama itu
    # pula barisnya menggantung tanpa dikerjakan siapa pun.
    {Oban.Plugins.Lifeline, rescue_after: {5, :minutes}},
    # Hasil job dibaca dari tabelnya sendiri, bukan dari oban_jobs; umur ini
    # hanya menentukan berapa lama jejak eksekusinya disimpan.
    {Oban.Plugins.Pruner, max_age: {1, :day}},
    # Penyapuan hasil validasi. Tabel kita juga dibersihkan tiap kali batch baru
    # masuk, tetapi itu tidak pernah terjadi saat trafiknya berhenti — dan
    # justru pada masa sepi itulah data mengendap paling lama.
    #
    # Jadwalnya UTC; Oban butuh basis data zona waktu untuk zona lain, dan itu
    # dependensi yang tidak sebanding untuk satu pekerjaan harian. "0 20" UTC
    # sama dengan pukul 03.00 WIB.
    {Oban.Plugins.Cron, crontab: [{"0 20 * * *", MapsScraper.Validation.Cleaner}]}
  ]

# Tokopedia dibaca lewat HTTP biasa (cepat, tanpa browser); Shopee lewat browser
# dan dibaca dua kali ketika jawabannya menunjukkan toko tidak ada. Batas waktu
# ini berlaku per pemuatan halaman, bukan per permintaan.
config :maps_scraper, :marketplace, timeout: 45_000

# Satu usaha memakai sampai empat context browser sekaligus (Tokopedia tidak
# memakai satu pun). Batas ini menjaga satu permintaan tidak menghabiskan
# seluruh kapasitas sidecar.
config :maps_scraper, :subject, max_concurrency: 4

config :maps_scraper, :validation,
  concurrency: 3,
  max_attempts: 3,
  backoff_ms: 1_000,
  max_backoff_ms: 30_000,
  max_batch: 500,
  # Hasil disimpan sehari, sejalan dengan umur jejak job di Oban. Nilai lama —
  # 15 menit — dipilih ketika antreannya masih di memori dan hasilnya memang
  # tidak diharapkan bertahan. Sekarang antreannya tahan restart, jadi hasilnya
  # pun semestinya masih bisa diambil setelah pemanggilnya sempat mati.
  job_ttl_ms: 86_400_000,
  max_jobs: 1_000,
  max_candidates: 5,
  match_threshold: 0.8,
  review_threshold: 0.3,
  ambiguity_margin: 0.1

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
