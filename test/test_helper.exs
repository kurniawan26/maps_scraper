ExUnit.start()

# Job dijalankan test secara eksplisit lewat `drain/0`, bukan oleh pekerja yang
# berjalan sendiri — supaya tiap test menentukan sendiri kapan antreannya jalan.
Ecto.Adapters.SQL.Sandbox.mode(MapsScraper.Repo, :manual)
