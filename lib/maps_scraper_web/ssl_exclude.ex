defmodule MapsScraperWeb.SSLExclude do
  @moduledoc """
  Pengecualian `force_ssl` yang diatur saat runtime.

  `force_ssl` dibaca saat kompilasi, jadi daftar host di `prod.exs` terpaku ke
  image. Host tambahan — misalnya IP LAN saat aplikasi hanya dilayani di
  jaringan lokal tanpa TLS — diisi lewat `SSL_EXCLUDE_HOSTS` dan dibaca di
  sini pada setiap permintaan.
  """

  @spec excluded?(Plug.Conn.t()) :: boolean()
  def excluded?(%Plug.Conn{host: host}) do
    host in Application.get_env(:maps_scraper, :ssl_exclude_hosts, [])
  end
end
