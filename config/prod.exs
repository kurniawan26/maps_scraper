import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :maps_scraper, MapsScraperWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # paths: ["/health"],
      hosts: [
        "localhost",
        "127.0.0.1",
        # Nama service dan container pada docker-compose. Pemanggil di dalam
        # jaringan Docker — n8n, misalnya — menghubungi Phoenix lewat
        # `http://app:4000`, dan di jaringan internal itu tidak ada TLS yang
        # bisa dituju. Tanpa dikecualikan, mereka menerima 301 ke
        # https://PHX_HOST dan permintaannya gagal di sana.
        #
        # Pengecualian ini berdasarkan header Host, jadi siapa pun bisa
        # melewatinya dengan memalsukan Host — sama halnya dengan "localhost"
        # di atas. Yang benar-benar menjaga lalu lintas publik adalah reverse
        # proxy yang mengakhiri TLS, bukan pengalihan ini.
        #
        # Kalau nama service di compose diubah, perbarui daftar ini.
        "app",
        "maps_scraper_app"
      ]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
