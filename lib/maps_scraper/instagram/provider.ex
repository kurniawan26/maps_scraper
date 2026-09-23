defmodule MapsScraper.Instagram.Provider do
  @moduledoc """
  Dari mana data profil Instagram diambil.

  Saat ini hanya ada satu implementasi, `#{inspect(__MODULE__)}.Playwright`, yang
  memakai sidecar milik proyek ini sendiri. Lapisan ini ada karena risiko
  terbesarnya bukan di kode: scraping anonim terbukti lancar dari IP residensial,
  tetapi Instagram jauh lebih ketat terhadap IP datacenter. Kalau kelak sidecar
  sendiri mulai diblokir, yang perlu ditulis cuma satu modul baru — penyedia
  pihak ketiga, atau sidecar di balik proxy residensial — tanpa menyentuh
  context, antrean, maupun controller.

  Implementasi dipilih lewat config:

      config :maps_scraper, :instagram, provider: MyApp.ProviderLain

  Kontraknya: `fetch/2` mengembalikan payload berbentuk sama dengan yang dipakai
  `MapsScraper.Maps` — `found`, `best_match`, `count`, `results` — supaya
  `MapsScraper.Validation.Queue` dapat merangkumnya tanpa tahu sumbernya.

  Kegagalan sementara wajib dikembalikan sebagai `{:error, {:scraper, status, _}}`
  dengan status 5xx, `:timeout`, atau `:unavailable`. Hanya bentuk itu yang
  diulang antrean. Menjawab "tidak ditemukan" untuk profil yang sebenarnya tidak
  terbaca akan menghapus akun yang sebetulnya ada.
  """

  @doc "Mengambil satu profil. `query` boleh username maupun URL profil."
  @callback fetch(query :: String.t(), opts :: map()) ::
              {:ok, map()} | {:error, term()}
end
