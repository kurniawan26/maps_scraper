# MapsScraper

JSON API untuk memverifikasi keberadaan sebuah data — tempat di Google Maps,
akun di Instagram, halaman di web, toko di marketplace — dari input yang
bervariasi.

Aplikasi ini **hanya menyajikan JSON API**: tanpa frontend, email, maupun
terjemahan. Dependensi untuk semua itu — esbuild, Tailwind, LiveView, Swoosh,
Gettext — sengaja tidak dipasang.

Satu-satunya penyimpanan adalah **SQLite**, dipakai antrean validasi agar batch
yang sedang berjalan selamat dari restart. Tidak ada server database yang perlu
dijalankan: berkasnya cukup satu, dan produksinya tetap dua container.

## API

Dua sumber, satu pola yang sama: Phoenix memvalidasi masukan, sidecar Playwright
membuka halamannya, dan jawabannya selalu berbentuk `found` + `best_match`.

```
klien  ->  Phoenix /api/places     ->  sidecar :3000 (Playwright)  ->  Google Maps
klien  ->  Phoenix /api/instagram  ->  sidecar :3000 (Playwright)  ->  Instagram
klien  ->  Phoenix /api/website    ->  sidecar :3000 (Playwright)  ->  situs mana pun
klien  ->  Phoenix /api/marketplace ->  sidecar :3000               ->  Tokopedia / Shopee
```

| Sumber | Endpoint | Pertanyaan yang dijawab |
| ------ | -------- | ----------------------- |
| Google Maps | `/api/places` | Apakah tempat ini benar-benar ada? |
| Instagram | `/api/instagram` | Apakah akun ini ada, dan apakah milik usaha yang dimaksud? |
| Website | `/api/website` | Apakah halaman ini hidup, dan apakah isinya cocok dengan usaha itu? |
| Marketplace | `/api/marketplace` | Apakah toko ini ada di Tokopedia/Shopee, dan apakah miliknya? |

Keempatnya bisa dipanggil satu per satu, **sekaligus lewat satu pintu**
(`POST /api/validate` — lihat [Satu pintu](#satu-pintu-post-apivalidate)), atau
sebagai batch lewat `/api/validations`.

### Menjalankan

```bash
cp .env.example .env           # semua nilai sudah punya default, aman dibiarkan
mix setup                      # unduh dependensi + siapkan berkas SQLite
docker compose up -d --build   # sidecar Playwright di port 3000
mix phx.server                 # Phoenix di port 4000
curl http://localhost:4000/api/health
```

Docker Compose membaca `.env` otomatis, tetapi Mix **tidak**. Kalau kamu mengubah
setelan Phoenix di `.env` (`SCRAPER_URL`, `VALIDATION_*`), muat dulu:

```bash
set -a && source .env && set +a && mix phx.server
```

Seluruh variabel beserta penjelasannya ada di `.env.example`.

### Endpoint

| Method | Path | Keterangan |
| ------ | ---- | ---------- |
| `GET`  | `/api/places?query=...` | Verifikasi tempat lewat query string |
| `POST` | `/api/places` | Verifikasi tempat lewat body JSON |
| `GET`  | `/api/instagram?query=...` | Verifikasi akun Instagram lewat query string |
| `POST` | `/api/instagram` | Verifikasi akun Instagram lewat body JSON |
| `GET`  | `/api/website?query=...` | Verifikasi halaman web lewat query string |
| `POST` | `/api/website` | Verifikasi halaman web lewat body JSON |
| `GET`  | `/api/marketplace?query=...` | Verifikasi toko marketplace lewat query string |
| `POST` | `/api/marketplace` | Verifikasi toko marketplace lewat body JSON |
| `POST` | `/api/validate` | **Satu pintu** — seluruh kanal satu usaha sekaligus |
| `POST` | `/api/validations` | Batch, untuk seluruh sumber |
| `GET`  | `/api/health` | Status Phoenix + sidecar |

Koleksi Postman siap pakai ada di `postman/` — lihat [Postman](#postman) di bawah.

### Satu pintu: `POST /api/validate`

Kalau yang ingin kamu validasi adalah **sebuah usaha**, bukan satu tautan, ini
pintunya. Satu permintaan membawa nama usaha beserta tautan kanalnya, dan
semuanya diperiksa paralel.

```bash
curl -X POST http://localhost:4000/api/validate \
  -H "content-type: application/json" \
  -d '{
    "name": "Warung Sate Pak Budi",
    "google_maps_url": "https://maps.app.goo.gl/xxxx",
    "instagram_url": "instagram.com/warungsatepakbudi",
    "website_url": "warungsate.com",
    "tokopedia_url": "tokopedia.com/warungsatepakbudi",
    "shopee_url": "shopee.co.id/warungsatepakbudi"
  }'
```

Isi kanal seperlunya — minimal satu. Usaha tanpa website tinggal tidak mengisi
fieldnya.

| Field | Keterangan |
| ----- | ---------- |
| `name` | Nama usaha. **Ini yang membuat jawabannya berarti** — lihat di bawah |
| `google_maps_url` | URL Google Maps. Menerima nama tempat, alamat, atau koordinat juga |
| `instagram_url` | URL profil atau username saja |
| `website_url` | URL atau nama domain |
| `tokopedia_url` / `shopee_url` | URL toko. Platformnya diperiksa cocok dengan nama fieldnya |
| `lang` / `country` | Diteruskan ke tiap kanal |

#### Kenapa `name` menentukan segalanya

Tautan yang hidup **belum berarti milik usaha yang kamu maksud**. Kalau data
kamu menyimpan link Maps yang salah, kami tetap menemukan tempat di sana — hanya
saja tempat itu bengkel motor, bukan warung sate.

Karena itu `name` dibandingkan dengan apa pun yang ketemu di tiap kanal:

| Yang terjadi | Vonis kanal |
| ------------ | ----------- |
| Tautan ketemu, namanya cocok | `match` — aman dipakai otomatis |
| Tautan ketemu, namanya beda jauh | `no_match` — tautannya salah usaha |
| Tautan tidak ketemu | `no_match` |
| `name` tidak diisi | `review` — tidak ada pembanding, nilai sendiri |

Ini **bukan** pencarian berdasarkan nama. Tiap kanal tetap diambil lewat tautan
yang kamu berikan; `name` hanya dipakai menilai hasilnya. Tidak ada permintaan
tambahan.

#### Bentuk jawabannya

```json
{
  "name": "Warung Sate Pak Budi",
  "checked": 4,
  "found": 4,
  "errors": 0,
  "verdicts": { "match": 3, "review": 1, "no_match": 0 },
  "cross_check": {
    "maps_website": "https://www.warungsate.com/",
    "maps_phone": "021-1234567",
    "website_matches_maps": true
  },
  "channels": {
    "google_maps": { "status": "ok", "found": true, "best_match": 1, "verdict": "match",
                     "results": [ { "name": "...", "address": "...", "phone": "...",
                                    "website": "...", "opening_hours": [], "…": "…" } ] },
    "instagram":   { "status": "ok", "found": true, "best_match": 1, "verdict": "match", "results": [ … ] },
    "website":     { "status": "ok", "found": true, "best_match": 1, "verdict": "match", "results": [ … ] },
    "tokopedia":   { "status": "ok", "found": true, "best_match": 1, "verdict": "match", "results": [ … ] }
  }
}
```

Hasil tiap kanal dibawa **utuh**, tidak dipangkas seperti pada endpoint batch —
justru kolom lengkap itulah yang membuat pintu ini berguna.

#### Validasi silang, gratis

Listing Google Maps memuat website dan telepon yang **dideklarasikan usaha itu
sendiri**. Keduanya dibandingkan dengan `website_url` yang kamu kirim dan
dilaporkan di `cross_check`.

Kalau keduanya cocok, itu bukti jauh lebih kuat daripada kemiripan nama — tidak
bergantung pada ejaan. Datanya sudah ikut terbawa, jadi tidak ada permintaan
tambahan.

#### Satu kanal gagal tidak menjatuhkan yang lain

Kanal yang tidak terbaca dilaporkan pada kanalnya sendiri, dan permintaannya
**tetap `200`**:

```json
"shopee": { "status": "error", "retryable": true,
            "error": { "code": "shopee_blocked", "message": "…" } }
```

Menggagalkan seluruh jawaban karena satu kanal sedang diblokir akan membuang
tiga kanal yang sudah terjawab. Field `retryable` memberi tahu apakah layak
dicoba lagi.

Yang tetap dijawab `422` hanyalah masukan yang salah bentuk — dan ditolak
**sebelum** satu pun kanal dijalankan, dengan menyebut field mana yang salah:

```json
{ "error": { "code": "invalid_params", "field": "tokopedia_url",
             "message": "ini URL shopee, bukan tokopedia" } }
```

#### Biayanya

Satu usaha memakai sampai **empat context browser** sekaligus — Tokopedia tidak
memakai satu pun. Lamanya ditentukan kanal terlambat, jadi sekitar **3–4 detik**.

Jaga `SUBJECT_MAX_CONCURRENCY` (default 4) tidak melebihi
`MAX_CONCURRENT_SCRAPES`, kalau tidak sebagian kanal pada satu permintaan yang
sama akan dijawab `busy`. Untuk volume besar, pakai endpoint batch — di sana
`busy` ditangani antrean lewat `snooze`, bukan dilaporkan sebagai kegagalan.

### Parameter `/api/places`

| Nama | Tipe | Default | Keterangan |
| ---- | ---- | ------- | ---------- |
| `query` | string | *wajib* | Nama tempat, alamat/lokasi, koordinat `lat,lng`, atau URL Google Maps |
| `limit` | integer | `20` | Jumlah maksimum hasil, 1–100 (hanya untuk pencarian) |
| `detail` | boolean | `false` | Buka tiap hasil untuk mengambil telepon, website, jam buka |
| `lang` | string | `id` | Bahasa hasil |
| `country` | string | `ID` | Region hasil |

### Membaca hasil `/api/places`

Dua kolom yang menentukan jawaban "valid atau tidak":

| Kolom | Arti |
| ----- | ---- |
| `found` | Google mengembalikan tempat untuk query ini |
| `best_match` | `0`–`1`, seberapa besar bagian kata dari query yang benar-benar muncul pada nama/alamat hasil. `null` untuk input URL dan koordinat, karena keduanya menunjuk lokasi secara pasti |

**`found: true` saja belum berarti tempatnya ada.** Google selalu berusaha menjawab:
untuk alamat fiktif pun ia mengembalikan tempat lain yang sekilas mirip. Itulah
gunanya `best_match`:

| Query | `found` | `best_match` | Kesimpulan |
| ----- | ------- | ------------ | ---------- |
| `Monumen Nasional Jakarta` | `true` | `1` | Ada |
| `kopi kenangan jakarta pusat` | `true` | `1` | Ada |
| `Jalan Zzqq Fiktif No 9999 Kota Antah` | `true` | `0` | **Tidak ada** — hasilnya tak berhubungan |
| `qwzxkjvbnmasdf plqowieuryt zzzz` | `false` | `0` | Tidak ada |

Ambang yang aman untuk dipakai sebagai keputusan otomatis: anggap valid bila
`found == true` **dan** (`best_match == null` atau `best_match >= 0.5`).

### Contoh `/api/places`

```bash
# nama tempat
curl "http://localhost:4000/api/places?query=Monumen+Nasional+Jakarta"

# daftar hasil
curl "http://localhost:4000/api/places?query=kopi+kenangan+jakarta+pusat&limit=5"

# koordinat
curl "http://localhost:4000/api/places?query=-6.1754,106.8272"

# URL Google Maps (termasuk link pendek maps.app.goo.gl)
curl -X POST http://localhost:4000/api/places \
  -H "content-type: application/json" \
  -d '{"query": "https://maps.app.goo.gl/xxxxxxxx"}'

# dengan detail lengkap
curl -X POST http://localhost:4000/api/places \
  -H "content-type: application/json" \
  -d '{"query": "warung sate jakarta", "limit": 3, "detail": true}'
```

### Bentuk response `/api/places`

```json
{
  "type": "search",
  "input_type": "text",
  "query": "kopi kenangan jakarta pusat",
  "found": true,
  "best_match": 1,
  "count": 1,
  "results": [
    {
      "name": "Kopi Kenangan - Ruko Sabang Jakarta Pusat",
      "match": 1,
      "category": "Kedai Kopi",
      "address": "Jl. H. Agus Salim No.40, RT.2/RW.1, Gondangdia, Jakarta Pusat",
      "phone": "081944223043",
      "website": "https://m.kopikenangan.com/og/share/2LeipgHMwtU",
      "plus_code": "RR7F+JX Gondangdia, Kota Jakarta Pusat",
      "status": "Buka 24 jam",
      "sponsored": false,
      "rating": 4.8,
      "reviews_count": 276,
      "opening_hours": [{ "day": "Rabu", "hours": "Buka 24 jam" }],
      "latitude": -6.185986,
      "longitude": 106.8249591,
      "ftid": "0x2e69f56d210b5631:0x5a67b43cadaf5a3a",
      "cid": "6514373558719699514",
      "place_id": "ChIJMVYLIW31aS4ROlqvrTy0Z1o",
      "thumbnail": "https://lh3.googleusercontent.com/...",
      "maps_url": "https://www.google.com/maps/place/..."
    }
  ]
}
```

`type` bernilai `search` (daftar hasil) atau `place` (satu tempat pasti).
`input_type` menyebut bentuk input yang terdeteksi: `text`, `coordinates`, atau `url`.
Bila URL yang dikirim tidak lengkap sehingga Google membuka peta kosong, nama tempat
pada URL dipakai sebagai pencarian cadangan dan hasilnya membawa `resolved_from_url`.

Kolom yang hanya terisi saat `detail=true` atau input berupa URL: `phone`, `website`,
`opening_hours`, `plus_code`, `description`, `thumbnail`. Hasil yang gagal diperkaya
ditandai `"detail_error": true` tanpa menggagalkan hasil lain.

Fase `detail=true` punya anggaran waktu sendiri (`DETAIL_BUDGET_MS`, default 60
detik untuk seluruh permintaan). Tanpa batas itu lamanya tumbuh mengikuti `limit`
dan selalu melewati batas waktu pemanggil. Tempat yang tidak kebagian waktu
ditandai `"detail_skipped": true` — kolom dari kartu hasil tetap terisi, hanya
kolom yang butuh membuka halaman yang kosong.

`rating` dan `reviews_count` bersifat sekunder dan tidak dijamin terisi — kartu
berbayar (`sponsored: true`) memang tidak memuatnya, dan Google merendernya menyusul.
Jangan pakai keduanya sebagai dasar keputusan.

### Instagram `/api/instagram`

Memastikan apakah sebuah akun Instagram ada, dari username maupun URL profil.
**Tidak perlu login, cookie sesi, maupun akun apa pun.** Halaman profil publik
memang menampilkan modal ajakan mendaftar, tetapi itu hanya lapisan di atas
kontennya — data profilnya tetap ada di DOM.

Yang tidak bisa dilakukan tanpa browser: `curl` ke `instagram.com/<username>/`
mengembalikan `200` dengan shell JavaScript yang **sama persis** untuk akun yang
ada maupun yang tidak. Profilnya dirender klien, jadi status HTTP dan HTML mentah
tidak membedakan apa pun. Karena itu jalurnya tetap lewat sidecar Playwright.

| Nama | Tipe | Default | Keterangan |
| ---- | ---- | ------- | ---------- |
| `query` | string | *wajib* | Username (`kournicloud`, `@kournicloud`) atau URL profil |
| `name` | string | — | Nama yang diharapkan, mis. nama usaha. Mengubah arti `best_match` (lihat di bawah) |
| `lang` | string | `en` | Bahasa halaman |
| `country` | string | `US` | Region halaman |

`lang`/`country` defaultnya `en`/`US`, bukan `id`/`ID` seperti `/api/places`.
Seluruh penanda yang dibaca sidecar — `Followers`, `Profile isn't available`,
lencana `Verified` — ikut berubah mengikuti bahasa halaman, jadi bahasanya
dikunci supaya parsingnya pasti. Bahasa bio tidak terpengaruh; itu isi pengguna.

```bash
# username
curl "http://localhost:4000/api/instagram?query=kournicloud"

# URL profil
curl "http://localhost:4000/api/instagram?query=https://www.instagram.com/natgeo/"

# apakah handle ini milik usaha bernama X?
curl -X POST http://localhost:4000/api/instagram \
  -H "content-type: application/json" \
  -d '{"query": "kournicloud", "name": "Warung Sate Pak Budi"}'
```

```json
{
  "type": "profile",
  "input_type": "username",
  "query": "kournicloud",
  "found": true,
  "best_match": 1,
  "count": 1,
  "results": [
    {
      "username": "kournicloud",
      "full_name": "Kurniawan",
      "bio": null,
      "external_url": "kurniawan-social.netlify.app",
      "verified": false,
      "private": false,
      "followers": 710,
      "following": 513,
      "posts": 5,
      "profile_url": "https://www.instagram.com/kournicloud/",
      "match": 1
    }
  ]
}
```

#### Arti `best_match` di sini

Berbeda dari Maps, Instagram tidak punya pencarian — satu query menunjuk tepat
satu akun. Jadi yang diukur bergantung pada ada tidaknya `name`:

| `name` | Yang diukur | `best_match` |
| ------ | ----------- | ------------ |
| tidak diisi | Apakah handle yang dibuka sama dengan yang diminta | `1` sama persis, `0` kalau Instagram mengalihkan ke akun lain |
| diisi | Seberapa cocok nama itu dengan `full_name` + username + bio | `0`–`1`, memakai skor yang sama dengan `/api/places` |

Isi `name` kalau yang ingin dijawab adalah "apakah handle ini benar milik usaha
X". Tanpa itu, `found: true` hanya berarti handle-nya ada — bukan milik siapa.

#### Tiga keadaan, bukan dua

Ini pembedaan yang paling menentukan, dan paling mudah terlewat:

| Keadaan | Yang terlihat | Jawaban API |
| ------- | ------------- | ----------- |
| Akun ada | `og:title` ada di halaman | `200`, `found: true` |
| Akun tidak ada | Halaman "Profile isn't available" | `200`, `found: false` |
| **Tidak terbaca** | Tidak keduanya — Instagram menolak melayani | `503`, `instagram_blocked` |

Keadaan ketiga **tidak boleh** diperlakukan sebagai "tidak ada". Kalau
dilaporkan `found: false`, akun yang sebenarnya ada akan terhapus dari data Anda
hanya karena Instagram sedang rewel. Karena itu jawabannya `5xx`, yang membuat
`MapsScraper.Validation.Queue` mengulangnya alih-alih memvonis barisnya.

#### Yang tidak bisa dibedakan

Akun yang **tidak pernah ada**, yang **dihapus**, dan yang **dinonaktifkan**
menampilkan halaman yang sama persis. Ketiganya dijawab `found: false`. Kalau
Anda perlu membedakannya, sinyal ini tidak cukup.

Kolom `followers`, `following`, `posts`, `bio`, dan `external_url` bersifat
sekunder dan best-effort — Instagram merendernya menyusul, dan `external_url`
tidak selalu ada dalam bentuk yang bisa dibaca. Untuk keputusan validasi, pakai
`found` dan `best_match`.

#### Batasnya

Pengujian 10 akun berurutan dari IP residensial: 10/10 berhasil, ~1 detik per
akun, nol blokir. **Itu belum diuji dari IP datacenter**, dan Instagram jauh
lebih ketat di sana. Kalau `instagram_blocked` mulai sering muncul setelah
dideploy, yang pertama diturunkan adalah `VALIDATION_CONCURRENCY`; kalau tetap,
yang dibutuhkan adalah proxy residensial di depan sidecar — bukan perubahan kode.

Penyedia data dapat ditukar tanpa menyentuh context, antrean, maupun controller;
lihat `MapsScraper.Instagram.Provider`.

### Website `/api/website`

Memastikan apakah sebuah halaman web hidup, dari URL lengkap maupun nama domain
telanjang. Menjawab dua hal saja: **hidup atau mati**, dan **cocok atau tidak**
dengan nama yang dicari. Ini bukan pengekstrak konten — tidak ada teks isi,
tabel, kontak, maupun selektor CSS.

| Nama | Tipe | Default | Keterangan |
| ---- | ---- | ------- | ---------- |
| `query` | string | *wajib* | URL lengkap atau nama domain (`warungsate.com`) |
| `name` | string | — | Nama yang diharapkan, mis. nama usaha. Tanpa ini `best_match` bernilai `null` |
| `lang` | string | `id` | Bahasa halaman |
| `country` | string | `ID` | Region halaman |

Domain telanjang dinaikkan ke `https` lebih dulu. Kalau gagal di lapis koneksi
atau sertifikat, sekali dicoba lewat `http` — banyak situs usaha kecil belum
berpindah, dan itu bukan alasan menyatakannya mati.

```bash
# domain telanjang
curl "http://localhost:4000/api/website?query=warungsate.com"

# apakah halaman ini milik usaha bernama X?
curl -X POST http://localhost:4000/api/website \
  -H "content-type: application/json" \
  -d '{"query": "warungsate.com", "name": "Warung Sate Pak Budi"}'
```

```json
{
  "type": "website",
  "input_type": "domain",
  "query": "warungsate.com",
  "found": true,
  "best_match": 1,
  "count": 1,
  "reason": null,
  "results": [
    {
      "url": "https://warungsate.com/",
      "final_url": "https://www.warungsate.com/",
      "status": 200,
      "title": "Warung Sate Pak Budi - Sate Kambing Jakarta",
      "description": "Sate kambing sejak 1998",
      "redirected": false,
      "parked": false,
      "reason": null,
      "match": 1
    }
  ]
}
```

Tanpa `name`, `best_match` bernilai `null` — tidak ada yang bisa dibandingkan,
dan barisnya masuk `review` persis seperti input URL pada `/api/places`. Isi
`name` kalau yang ingin dijawab adalah "apakah halaman ini benar milik usaha X".

#### Tiga keadaan, bukan dua

| Keadaan | Contoh | Jawaban API |
| ------- | ------ | ----------- |
| Hidup | `200`, halaman berisi | `200`, `found: true` |
| Mati | DNS tidak ada, koneksi ditolak, `404`/`410`, domain parkir | `200`, `found: false` + `reason` |
| **Tidak terbaca** | timeout, `5xx`, atau `401`/`403`/`429` | `503`, `website_*` |

`401`/`403`/`429` sengaja **tidak** dihitung mati. Ketiganya berarti halamannya
ada tetapi kita tidak diizinkan melihatnya — biasanya karena situsnya memblokir
bot. Memvonisnya mati akan menghapus website yang sebenarnya hidup.

Nilai `reason` yang mungkin saat `found: false`: `dns_not_found`,
`connection_refused`, `unreachable`, `tls_error`, `too_many_redirects`,
`parked`, dan `http_<status>`.

#### Domain parkir

Domain yang sudah dijual atau diparkir dijawab `found: false` dengan
`reason: "parked"`. Pengenalannya sengaja dibuat sempit — hanya frasa penjualan
yang eksplisit, atau tautan ke layanan parkir pada halaman yang memang kosong.
Halaman "coming soon" dan "under construction" **tidak** dihitung parkir; halaman
seperti itu memang hidup, hanya belum berisi. Salah tuduh di sini menghapus
website usaha yang sebenarnya ada, jadi ambangnya dipasang tinggi.

#### Alamat internal ditolak

Berbeda dari dua sumber lain yang host-nya terkunci ke Google dan Instagram,
sumber ini membuka URL yang ditentukan pemanggil. Tanpa penjagaan, siapa pun
yang dapat memanggil API ini bisa memakainya sebagai perantara untuk menjangkau
apa yang hanya terlihat dari dalam jaringan — inilah SSRF.

Yang ditolak dengan `403 blocked_address`:

| Golongan | Contoh |
| -------- | ------ |
| Loopback | `127.0.0.1`, `::1`, `localhost` |
| Jaringan privat | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` |
| Link-local & metadata cloud | `169.254.169.254` |
| CGNAT dan rentang cadangan | `100.64.0.0/10`, `0.0.0.0/8`, multicast |
| IPv6 internal | `fc00::/7`, `fe80::/10`, `::ffff:127.0.0.1` |

Tiga hal yang membuatnya bukan sekadar daftar hitam nama:

1. **Yang diperiksa adalah alamat hasil resolusi, bukan namanya.** Domain publik
   bisa saja diarahkan ke `127.0.0.1` — dan `localtest.me` memang begitu.
   Pemeriksaan berbasis nama tidak akan melihatnya.
2. **Tiap lompatan pengalihan ikut diperiksa.** Rantai pengalihan diselesaikan
   lebih dulu di luar browser, karena `route.continue()` pada Playwright hanya
   memanggil handler untuk request pertama — pengalihan sesudahnya diikuti
   browser tanpa melewatinya lagi. URL publik yang mengalihkan ke `169.254.169.254`
   karena itu tetap tertahan.
3. **Skema selain `http`/`https` ditolak**, termasuk bila muncul sebagai tujuan
   pengalihan.

Pemeriksaannya berjalan dua kali: di Phoenix sebelum permintaan dikirim, dan di
sidecar untuk tiap lompatan. Baris batch yang menunjuk alamat internal ditolak
`422` di depan, bukan setelah job diterima.

**Sisa risiko yang diketahui:** sub-resource halaman (script, stylesheet) hanya
diperiksa pada host langsungnya. Sub-resource yang mengalihkan ke alamat internal
masih bisa menghasilkan satu permintaan, meski isinya tidak pernah dibaca maupun
dikembalikan. Kalau service ini dibuka ke pemanggil yang tidak tepercaya,
tempatkan sidecar di jaringan yang memang tidak punya akses ke apa pun.

#### Biayanya

Halaman mati dijawab tanpa membuka browser sama sekali — cukup satu permintaan
HTTP, sekitar 0,2 detik. Halaman hidup butuh satu context Chromium karena judul
pada situs SPA baru terisi setelah JavaScript-nya jalan; hitungannya 1–3 detik.

### Marketplace `/api/marketplace`

Memastikan apakah sebuah toko ada di **Tokopedia** atau **Shopee**. Platform
ditentukan dari host, jadi masukannya wajib berupa URL toko — bukan nama toko
telanjang.

```bash
curl "http://localhost:4000/api/marketplace?query=tokopedia.com/samsung&name=Samsung"
curl "http://localhost:4000/api/marketplace?query=shopee.co.id/samsung.id"
```

| Nama | Tipe | Default | Keterangan |
| ---- | ---- | ------- | ---------- |
| `query` | string | *wajib* | URL toko, mis. `tokopedia.com/samsung`. Skema boleh dihilangkan |
| `name` | string | — | Nama yang diharapkan. Tanpa ini `best_match` bernilai `1` saat toko ditemukan |
| `lang` / `country` | string | `id` / `ID` | Bahasa dan region halaman |

**Nama toko telanjang ditolak.** `samsung` ada di kedua platform sebagai toko
yang berbeda, jadi `"samsung"` tidak punya jawaban tunggal. Sebutkan host-nya.

```json
{
  "type": "marketplace",
  "platform": "shopee",
  "query": "shopee.co.id/samsung.id",
  "found": true,
  "best_match": 1,
  "count": 1,
  "reason": null,
  "results": [
    {
      "platform": "shopee",
      "slug": "samsung.id",
      "store_name": "Sam Sung ID",
      "store_url": "https://shopee.co.id/samsung.id",
      "shop_id": 326058955,
      "followers": 2,
      "items": 2,
      "rating": 0,
      "match": 1
    }
  ]
}
```

Kolom `shop_id`, `followers`, `items`, dan `rating` hanya terisi untuk Shopee —
Tokopedia tidak menyediakannya lewat jalur yang dipakai di sini.

#### Dua platform, dua cara baca yang berlawanan

Ini hasil pengukuran, bukan pilihan gaya:

| | Tokopedia | Shopee |
| --- | --- | --- |
| HTTP biasa | **berhasil** — `og:title` memuat nama toko | shell identik untuk toko ada maupun tidak |
| Browser | **ditolak** — `ERR_HTTP2_PROTOCOL_ERROR` | satu-satunya jalan |
| Toko tidak ada | **`410 Gone`** | API membalas `error: 1000000` |
| Biaya per baris | **~0,3–1 dtk, tanpa context Chromium** | ~2–4 dtk, satu context |

Karena Tokopedia tidak memakai browser sama sekali, barisnya **tidak ikut
menghitung slot `MAX_CONCURRENT_SCRAPES`**. Batch Tokopedia karena itu jauh
lebih murah daripada sumber lain mana pun di proyek ini.

Shopee tidak pernah merender nama toko untuk kita dan API-nya menolak permintaan
biasa dengan `403`. Tetapi di dalam browser, API yang sama dipanggil
frontend-nya sendiri dan berhasil — jadi halamannya dibuka, lalu responsnya
disadap.

#### Verifikasi bot Tokopedia

Sebagian toko Tokopedia dilindungi Bot Manager Akamai. Yang dikirim bukan status
error, melainkan halaman `200` berukuran kecil berisi meta-refresh ke URL
ber-token `bm-verify`. Perilakunya konsisten per toko, bukan acak: `samsung`
selalu ditantang, `erafone` tidak pernah.

Tantangan itu dijawab otomatis — URL-nya diikuti sekali dengan cookie yang baru
diberikan, dan halaman aslinya didapat. Kalau tantangannya masih muncul setelah
dijawab, jawabannya `503 tokopedia_challenged`: **tidak terbaca, bukan tidak
ada**.

#### Shopee: kode error yang generik

Shopee menjawab toko yang tidak ada dengan `error: 1000000, error_msg:
"service_err"` — konsisten pada seluruh pengujian, tetapi namanya jelas bukan
"toko tidak ada". Kode yang sama bisa saja muncul saat layanannya bermasalah.

Karena itu jawaban semacam itu **dikonfirmasi sekali lagi** sebelum divonis:
gangguan sesaat jarang terulang persis, sedangkan toko yang memang tidak ada
selalu menjawab sama. Itu sebabnya toko Shopee yang tidak ada memakan waktu
sekitar dua kali lipat (~4 dtk) dibanding yang ada (~2 dtk).

Kalau API-nya tidak pernah terpanggil sama sekali — kita diblokir, atau
halamannya tidak selesai — jawabannya `503 shopee_blocked`, dan antrean yang
mengulangnya.

#### Bagian paling rapuh di proyek ini

Jujur saja: pembacaan Shopee bergantung pada **API internal tanpa dokumentasi**
(`/api/v4/shop/get_shop_base_v2`) yang bentuknya bisa berubah kapan saja tanpa
pemberitahuan. Tokopedia jauh lebih aman karena bersandar pada `og:title` dan
status HTTP standar.

Kalau suatu hari batch Shopee mulai mengembalikan `shopee_blocked` secara
menyeluruh, periksa dulu apakah nama endpoint atau bentuk responsnya berubah —
itu penyebab yang paling mungkin, dan bukan sesuatu yang bisa dicegah dari sisi
sini.

### Error

```json
{ "error": { "code": "invalid_params", "field": "limit", "message": "harus di antara 1 dan 100" } }
```

| Status | `code` | Penyebab |
| ------ | ------ | -------- |
| `422` | `invalid_params` | Parameter tidak valid |
| `503` | `scraper_unavailable` | Sidecar belum jalan (`docker compose up`) |
| `503` | `busy` | Sidecar sedang penuh; ulangi sesuai header `Retry-After` |
| `503` | `instagram_blocked` | Instagram menolak melayani; ulangi nanti |
| `503` | `instagram_unreadable` | Profil tidak terbaca dalam batas waktu; ulangi nanti |
| `403` | `blocked_address` | URL menunjuk alamat internal; permanen, jangan diulang |
| `503` | `website_timeout` | Halaman tidak terbuka dalam batas waktu; ulangi nanti |
| `503` | `website_http_<status>` | Server tujuan menjawab 401/403/429/5xx; ulangi nanti |
| `503` | `tokopedia_challenged` | Tokopedia meminta verifikasi bot; ulangi nanti |
| `503` | `shopee_blocked` | Shopee tidak mengembalikan data toko; ulangi nanti |
| `504` | `timeout` | Scraping melewati batas waktu |

Tempat, akun, atau halaman yang tidak ditemukan **bukan** error: statusnya tetap
`200` dengan `found: false`. Sebaliknya, kode `instagram_*` dan `website_*` di
atas berarti *tidak tahu*, bukan *tidak ada* — jangan pernah menerjemahkannya
jadi `found: false`.

### Daur hidup browser

Sidecar **tidak** menyalakan Chromium saat container start. Browser baru dibuat
ketika permintaan pertama masuk, lalu dipakai ulang oleh permintaan berikutnya —
yang dibuat per permintaan hanyalah `BrowserContext` (cookie dan cache sendiri),
bukan browser baru.

| Kondisi | Proses Chromium | Memori container |
| ------- | --------------- | ---------------- |
| Baru start, belum ada permintaan | 0 | ~44 MB |
| Setelah permintaan pertama | 7 | ~144 MB |
| Idle, sebelum timeout | 6–7 | ~136 MB |
| Setelah idle timeout | 0 | ~44 MB |

Menyalakan browser hampir tidak menambah waktu: permintaan pertama setelah
restart terukur 5,86 detik sementara permintaan berikutnya 6,36 dan 5,75 detik —
biaya `chromium.launch()` tenggelam oleh waktu muat halaman Google Maps.

Dua batas menjaga browser tidak hidup selamanya:

| Variabel | Default | Keterangan |
| -------- | ------- | ---------- |
| `BROWSER_IDLE_TIMEOUT_MS` | `300000` | Tutup browser setelah sekian lama tanpa pemakaian. `0` mematikan |
| `BROWSER_MAX_CONTEXTS` | `200` | Tutup dan nyalakan ulang setelah sekian context. `0` mematikan |

Yang dihitung `BROWSER_MAX_CONTEXTS` adalah **context**, bukan permintaan HTTP:
satu pencarian biasa memakai 1 context, sedangkan pencarian dengan `detail=true`
memakai 1 context ditambah satu per hasil yang diperkaya.

**Keduanya tidak pernah memotong scraping yang sedang berjalan.** Penutupan hanya
terjadi saat jumlah context aktif nol; kalau kuota habis di tengah permintaan,
browser baru ditutup setelah context terakhir selesai. Alasan penutupan dicatat
di log:

```
[scraper] menutup browser (idle 300000 ms)
[scraper] menutup browser (kuota 200 context)
```

Keadaannya dapat diamati lewat `GET /health` pada sidecar:

```json
{
  "status": "ok",
  "browser": {
    "mode": "launch", "running": true,
    "active_contexts": 0, "contexts_served": 12,
    "idle_timeout_ms": 300000, "max_contexts": 200, "retiring": false
  }
}
```

### Kebutuhan memori

Diukur dengan `docker stats`, sampling setiap ~0,5 detik selama permintaan
berjalan (bukan sesudahnya), pada mesin dengan RAM 19 GB.

| Kondisi | sidecar | Phoenix | total |
| ------- | ------- | ------- | ----- |
| Diam, browser belum menyala | 45 MB | 184 MB | **229 MB** |
| 1 pencarian sederhana (puncak) | 405 MB | 183 MB | 588 MB |
| 1 pencarian daftar, `limit=20` | 249 MB | 183 MB | 432 MB |
| 1 pencarian `detail=true limit=3` (4 context) | 404 MB | 183 MB | 587 MB |
| Validasi massal 10 query, concurrency 1 | 459 MB | 168 MB | 627 MB |
| Validasi massal 10 query, concurrency 3 | 772 MB | 184 MB | 956 MB |
| Validasi massal + `detail=true` (sampai 12 context) | 990 MB | 175 MB | **1,14 GB** |
| Setelah pekerjaan selesai | 256 MB | 184 MB | 440 MB |
| Setelah idle timeout | 45 MB | 184 MB | **229 MB** |

Angka pentingnya: **tiap context bersamaan menambah sekitar 155 MB.** Selisih
concurrency 1 dan 3 pada beban yang sama adalah 459 MB → 772 MB untuk dua context
tambahan.

Memori Phoenix rata di ~180 MB apa pun bebannya — BEAM mengalokasikan di depan
dan pekerjaan berat ada di sidecar, bukan di sini.

#### Dua concurrency itu saling mengalikan

`VALIDATION_CONCURRENCY` menentukan berapa query diproses bersamaan, dan tiap
query dengan `detail=true` membuka lagi sampai `DETAIL_CONCURRENCY` halaman.
Keduanya berlipat:

```
VALIDATION_CONCURRENCY=3  x  (1 + DETAIL_CONCURRENCY=3)  =  sampai 12 context
```

Itulah baris 1,14 GB pada tabel di atas. Kalau menaikkan salah satunya, hitung
hasil kalinya — bukan jumlahnya.

#### Ukuran server

| RAM | Cukup untuk |
| --- | ----------- |
| 1 GB | Tidak — beban puncak jauh melewatinya |
| 2 GB | Hanya untuk pencarian satuan. **Tidak cukup** untuk validasi massal dengan `detail=true`: puncaknya sendiri sudah 1,8 GB untuk kedua container, belum termasuk OS |
| **4 GB** | **Minimum yang disarankan.** Puncak terukur 1,8 GB menyisakan ruang untuk OS dan lonjakan |
| 8 GB | Longgar; perlu kalau Anda menaikkan `VALIDATION_CONCURRENCY` atau `DETAIL_CONCURRENCY` |

Kalau server Anda hanya 2 GB dan tetap ingin validasi massal, turunkan
pengalinya — misalnya `DETAIL_CONCURRENCY=1` dan `VALIDATION_CONCURRENCY=2`
(6 context, sekitar 0,9 GB) — dan turunkan limit di compose mengikutinya.

Batasi juga memori containernya lewat `deploy.resources.limits.memory` di Compose
supaya sidecar yang membengkak tidak menjatuhkan proses lain di server yang sama.
`docker-compose.prod.yml` sudah memasangnya.

#### Pengukuran ulang pada image produksi

Tabel di atas diukur pada alur development (Phoenix di host). Diukur ulang pada
image produksi — Phoenix dari release, sidecar dari image yang sama yang
dideploy — dengan batch 6 query, `limit=3`, `detail=true`, `VALIDATION_CONCURRENCY=3`:

| Kondisi | sidecar | app |
| ------- | ------- | --- |
| Container baru, browser belum pernah menyala | 44 MB | 176 MB |
| **Puncak, 12 context bersamaan** | **1608 MB** | 180 MB |
| Selesai kerja, browser masih hidup | 481 MB | 180 MB |
| Idle, browser sudah ditutup | 246 MB | 180 MB |

Tiga hal yang berbeda dari tabel sebelumnya dan mengubah keputusan ukuran server:

1. **Puncaknya lebih tinggi: 1,6 GB, bukan 990 MB.** Bentuk bebannya lebih berat
   — tiap query mengembalikan feed berisi 3 hasil, jadi keduabelas context
   benar-benar terpakai penuh.
2. **Sidecar tidak kembali ke 44 MB setelah idle, melainkan ke 246 MB.** Angka
   44 MB hanya berlaku untuk container yang belum pernah menjalankan browser
   sama sekali. Untuk menghitung kebutuhan server, pakai 246 MB sebagai lantai.
3. **Memori Phoenix tidak bergerak** — 176–180 MB apa pun bebannya, sesuai
   dugaan: pekerjaan berat ada di sidecar.

Marginalnya sekitar **113 MB per context bersamaan** di atas lantai 246 MB.
Batas atas sesungguhnya bukan 12 context melainkan:

```
MAX_CONCURRENT_SCRAPES=4  x  (1 + DETAIL_CONCURRENCY=3)  =  16 context  ~ 2,0 GB
```

Karena itu limit sidecar di `docker-compose.prod.yml` disetel **2560 MB**, bukan
1536 MB — nilai yang lebih rendah akan membuat container di-OOM-kill tepat pada
beban yang paling mungkin Anda jalankan.

### Validasi massal (antrean job)

Untuk memeriksa banyak query sekaligus, kirim satu batch dan ambil hasilnya
belakangan. Tiap baris menjadi satu job **Oban** yang tersimpan di SQLite, dan
paling banyak `VALIDATION_CONCURRENCY` baris dikerjakan bersamaan.

```bash
# kirim batch -> 202 Accepted
curl -X POST http://localhost:4000/api/validations \
  -H "content-type: application/json" \
  -d '{"queries": ["Monumen Nasional Jakarta", "Plaza Indonesia", "-6.1754,106.8272"]}'
# => {"job_id":"iq-9VDY7UabOrjHJ","status":"running","total":3, ...}

# ambil hasilnya
curl http://localhost:4000/api/validations/iq-9VDY7UabOrjHJ

# ringkasan antrean
curl http://localhost:4000/api/validations

# batch Instagram
curl -X POST http://localhost:4000/api/validations \
  -H "content-type: application/json" \
  -d '{"source": "instagram", "queries": ["kournicloud", "natgeo"], "name": "Kurniawan"}'

# batch website
curl -X POST http://localhost:4000/api/validations \
  -H "content-type: application/json" \
  -d '{"source": "website", "queries": ["warungsate.com", "contoh.co.id"], "name": "Warung Sate Pak Budi"}'

# batch marketplace
curl -X POST http://localhost:4000/api/validations \
  -H "content-type: application/json" \
  -d '{"source": "marketplace", "queries": ["tokopedia.com/samsung", "shopee.co.id/samsung.id"], "name": "Samsung"}'
```

| Method | Path | Keterangan |
| ------ | ---- | ---------- |
| `POST` | `/api/validations` | Kirim batch. Body: `source`, `queries` (daftar teks), dan opsi sumbernya — berlaku untuk seluruh baris |
| `GET`  | `/api/validations/:id` | Status dan hasil job |
| `GET`  | `/api/validations` | Ringkasan antrean |

#### Sumber

| `source` | Isi `queries` | Opsi yang berlaku |
| -------- | ------------- | ----------------- |
| `maps` (default) | Nama tempat, alamat, koordinat, URL Maps | `limit`, `detail`, `lang`, `country` |
| `instagram` | Username atau URL profil | `name`, `lang`, `country` |
| `website` | URL lengkap atau nama domain | `name`, `lang`, `country` |
| `marketplace` | URL toko Tokopedia/Shopee | `name`, `lang`, `country` |

Satu batch memeriksa satu sumber. Mencampurnya sengaja tidak didukung: opsi tiap
sumber berbeda, dan yang memanggil endpoint ini biasanya sedang memeriksa satu
kolom dari satu tabel.

Untuk `instagram` dan `website`, baris yang bentuknya tidak sah ditolak di depan
dengan `422` — bukan diterima lalu gagal satu per satu. Baris seperti itu tidak
akan pernah berhasil betapa pun sering diulang, jadi memberi tahu sekarang lebih
jujur daripada membuat klien menunggu hasil polling yang sudah pasti sia-sia.
Untuk `website` itu termasuk baris yang menunjuk alamat internal.

Opsi `name` berlaku untuk **seluruh batch**. Kalau tiap baris punya nama
pembanding sendiri, kirim satu batch per nama — atau pakai `/api/instagram`
per baris.

Bentuk kandidatnya mengikuti sumbernya. Untuk `maps` berisi `place_id`/`cid`/
`ftid` dan koordinat; untuk `instagram` berisi `username`, `full_name`,
`profile_url`, `followers`, `verified`, dan `private`; untuk `website` berisi
`url`, `final_url`, `status`, `title`, `description`, `redirected`, dan `parked`;
untuk `marketplace` berisi `platform`, `slug`, `store_name`, `store_url`, dan —
khusus Shopee — `shop_id`, `followers`, `items`, `rating`.

Hasil tiap baris dipadatkan ke jawaban validasinya — `found`, `best_match`,
`verdict`, dan beberapa **kandidat** terurut dari yang paling cocok. Untuk daftar
hasil lengkap sebuah query, pakai `/api/places`.

Kandidatnya sengaja lebih dari satu. `best_match` diambil dari seluruh hasil, jadi
tempat yang paling cocok bisa berada di posisi kedua atau ketiga versi Google —
kalau hanya yang teratas yang dibawa, jawaban yang benar ikut terbuang sebelum
sempat dinilai.

```json
{
  "job_id": "iq-9VDY7UabOrjHJ",
  "status": "done",
  "total": 6,
  "counts": { "pending": 0, "running": 0, "ok": 6, "error": 0 },
  "verdicts": { "match": 4, "review": 1, "no_match": 1 },
  "results": [
    {
      "index": 0,
      "query": "Monumen Nasional Jakarta",
      "status": "ok",
      "attempts": 1,
      "found": true,
      "best_match": 1,
      "verdict": "match",
      "candidates": [
        { "name": "Monumen Nasional", "address": "...", "maps_url": "...",
          "place_id": null, "cid": "4407571450964851912", "ftid": "0x2e69f5d2e764b12d:0x3d2ad6e1e0e9bcc8",
          "latitude": -6.1753083, "longitude": 106.8271106, "match": 1 }
      ]
    }
  ]
}
```

#### Vonis

`verdict` bernilai tiga arah, bukan dua — karena keputusan akhir yang butuh
pertimbangan sebaiknya diambil di luar service ini (mis. membandingkan alamat
hasil scraping dengan alamat yang sudah Anda simpan):

| `verdict` | Kapan | Tindak lanjut |
| --------- | ----- | ------------- |
| `match` | `best_match >= VALIDATION_MATCH_THRESHOLD` **dan** kandidat teratas unggul jelas | Cukup meyakinkan, tidak perlu dinilai lagi |
| `review` | Skor di antara kedua ambang, `best_match` `null`, **atau** dua kandidat teratas berimpit | Kirim kandidatnya ke penilai di luar |
| `no_match` | `found == false`, tanpa kandidat, atau skor di bawah `VALIDATION_REVIEW_THRESHOLD` | Tidak ada yang layak dinilai |

`best_match` bernilai `null` ketika skor kemiripan memang tidak berlaku — input
berupa URL atau koordinat. Itu **bukan** bukti cocok, jadi barisnya masuk `review`.

**Kandidat berimpit juga masuk `review`, setinggi apa pun skornya.** Skor menjawab
"ada yang cocok", bukan "yang mana yang cocok". Ketika kandidat teratas hanya
unggul `VALIDATION_AMBIGUITY_MARGIN` atau kurang dari kandidat berikutnya,
pertanyaan kedua belum terjawab. Ini sering terjadi pada `detail=true`: alamat
lengkap membuat beberapa tempat berbeda di kecamatan yang sama memuat kata yang
persis sama, sehingga semuanya berskor penuh. Tanpa aturan ini, baris yang paling
perlu dinilai justru yang tidak pernah dikirim.

#### Alamat: `detail=false` vs `detail=true`

Ini menentukan untuk pembandingan alamat, dan selisihnya besar (diukur pada
`apotek gambir jakarta pusat`):

| | Panjang alamat | Isi |
| --- | --- | --- |
| `detail=false` (kartu feed) | 35–61 karakter | jalan + RT/RW saja |
| `detail=true` (halaman tempat) | 123–144 karakter | + kelurahan, kecamatan, kota, provinsi, kode pos |

Karena `address` ikut masuk hitungan `best_match`, pilihan ini mengubah skornya —
pada contoh di atas dari `0.5 / 0.25 / 0.25` menjadi `1 / 1 / 1`. Kalau tujuannya
membandingkan alamat, `detail=true` dengan `limit` kecil (3–5) biasanya yang
Anda mau; pada `limit` sekecil itu halaman detail dibuka paralel sehingga waktunya
hampir tidak bertambah, dan yang bertambah adalah jumlah context.

Konsekuensinya skor jadi kurang membedakan — justru karena itu aturan kandidat
berimpit di atas ada.

Vonis ini sengaja murah dan kasar: gunanya memilah baris mana yang perlu dinilai
lebih lanjut, bukan menjadi keputusan akhir. Kedua ambangnya perlu disetel ulang
begitu sebaran skor data Anda terlihat — nilai bawaannya titik awal, bukan hasil
pengukuran. Perlu diingat `best_match` berbutir kasar untuk query pendek: dengan
dua kata bermakna, skor yang mungkin hanya 0, 0.5, dan 1.

`status` job bernilai `running` atau `done`. Status tiap baris: `pending` (menunggu
giliran atau menunggu retry), `running`, `ok`, `error`.

#### Retry

Kegagalan **sementara** diulang otomatis dengan jeda yang menggandakan diri
(1 detik, 2 detik, 4 detik, … dengan sedikit acak agar tidak serempak):

| Penyebab | Diulang? |
| -------- | -------- |
| Sidecar mati / tidak dapat dihubungi | ya |
| Timeout scraping | ya |
| Error 5xx dari sidecar | ya |
| Context-nya sendiri meledak | ya |
| Sidecar penuh (`503 busy`) | ya — dan **tanpa menghabiskan jatah percobaan** |
| Parameter tidak valid | **tidak** — hasilnya tidak akan berubah |
| URL menunjuk alamat internal | **tidak** — tidak akan berubah jadi publik |

Selama menunggu giliran ulang, barisnya berstatus `pending` dan membawa
`last_error` sehingga penyebabnya terlihat tanpa harus membuka log:

```json
{ "index": 0, "status": "pending", "attempts": 1,
  "last_error": { "code": "scraper_unavailable", "message": "Sidecar tidak dapat dihubungi" } }
```

Satu baris yang gagal tidak menggagalkan baris lain dalam batch yang sama.

#### Setelan

Lewat environment, tanpa rebuild:

| Variabel | Default | Keterangan |
| -------- | ------- | ---------- |
| `VALIDATION_CONCURRENCY` | `3` | Ukuran antrean Oban: baris diproses bersamaan. Jangan melebihi kapasitas sidecar |
| `DATABASE_PATH` | *(lihat bawah)* | Berkas SQLite antrean. Di Docker **wajib** menunjuk volume |
| `VALIDATION_MAX_ATTEMPTS` | `3` | Termasuk percobaan pertama (jadi 3 = 1 jalan + 2 ulang) |
| `VALIDATION_BACKOFF_MS` | `1000` | Jeda dasar sebelum percobaan ulang |
| `VALIDATION_MAX_BACKOFF_MS` | `30000` | Batas atas jeda |
| `VALIDATION_MAX_BATCH` | `500` | Baris maksimum per batch |
| `VALIDATION_JOB_TTL_MS` | `86400000` | Hasil batch bisa diambil selama ini setelah selesai (1 hari). `0` mematikan |
| `VALIDATION_CLEANUP_CRON` | `0 20 * * *` | Jadwal penyapuan harian, notasi cron **UTC** (= 03.00 WIB) |
| `VALIDATION_MAX_JOBS` | `1000` | Batas jumlah batch tersimpan. `0` mematikan |
| `VALIDATION_MAX_CANDIDATES` | `5` | Kandidat yang dibawa tiap baris hasil |
| `VALIDATION_MATCH_THRESHOLD` | `0.8` | Di atas ini divonis `match` |
| `VALIDATION_REVIEW_THRESHOLD` | `0.3` | Di bawah ini divonis `no_match` |
| `VALIDATION_AMBIGUITY_MARGIN` | `0.1` | Selisih skor dua kandidat teratas yang masih dianggap berimpit |

#### Ketahanan terhadap restart

Antrean berjalan di atas **Oban dengan SQLite** (`Oban.Engines.Lite`), jadi
batch tersimpan di disk, bukan di memori proses. Yang terjadi saat aplikasi
berhenti di tengah batch:

| Cara berhenti | Yang terjadi |
| ------------- | ------------ |
| `docker stop` / SIGTERM | Oban menuntaskan baris yang sedang jalan, sisanya menunggu di antrean dan dilanjutkan setelah start |
| Mati mendadak (OOM, SIGKILL, mesin padam) | Baris yang menunggu langsung dilanjutkan. Baris yang sedang jalan dibebaskan **saat start berikutnya**, lalu dikerjakan ulang |

Terukur: batch 12 baris di-`SIGKILL` saat 2 baris selesai — 7 menunggu, 3 sedang
jalan. Setelah start ulang, batch selesai penuh 12/12 dalam hitungan detik.

Pembebasan job yatim saat start itu aman **karena deployment ini satu node**:
tidak mungkin ada pekerja lain yang sedang memegangnya. `Oban.Plugins.Lifeline`
tetap dipasang sebagai jaring pengaman kalau pekerjanya mati sementara
aplikasinya sendiri masih hidup.

#### Sidecar penuh tidak lagi merusak data

Saat sidecar menolak dengan `503 busy`, job **di-snooze**, bukan dihitung gagal.
Oban mengembalikan hitungan percobaan setiap kali job di-snooze, sehingga
kemacetan yang kita timbulkan sendiri tidak pernah menghabiskan jatah retry
milik kegagalan yang sesungguhnya.

Ini memperbaiki perilaku yang sebelumnya merusak: dengan antrean lama, menuntut
concurrency lebih dari kapasitas sidecar membuat baris **yang datanya sehat**
divonis gagal setelah percobaan ketiga. Terukur pada setelan cap=2 vs
concurrency=8: 5 dari 8 baris gagal sebagai `busy`, termasuk akun yang jelas ada.

Aturan kapasitasnya tetap berlaku dan tetap layak dijaga — `snooze` membuat
pelanggarannya tidak merusak, bukan membuat sidecar sanggup melayani lebih
banyak:

```
MAX_CONCURRENT_SCRAPES  ≥  VALIDATION_CONCURRENCY × context_per_baris
```

#### Retensi hasil

Hasil batch **tidak disimpan selamanya**: setelah `VALIDATION_JOB_TTL_MS`
(default **1 hari**) lewat, batch dibuang dan id-nya membalas `404`. Kalau
jumlah batch melewati `VALIDATION_MAX_JOBS`, yang dibuang lebih dulu adalah
batch selesai yang paling tua — batch yang masih berjalan tidak pernah
dikorbankan.

Penyapuan berjalan dari **dua arah**, dan keduanya perlu:

| Kapan | Kenapa |
| ----- | ------ |
| Saat batch baru masuk | Membersihkan tepat ketika ruang dibutuhkan |
| Terjadwal, sekali sehari | Yang pertama tidak pernah jalan kalau trafiknya berhenti — dan justru pada masa sepi itulah data mengendap paling lama |

Jadwalnya diatur `VALIDATION_CLEANUP_CRON`, dalam notasi cron **UTC**. Bawaannya
`0 20 * * *`, yang sama dengan pukul 03.00 WIB. (Oban butuh basis data zona
waktu untuk zona selain UTC — dependensi yang tidak sebanding untuk satu
pekerjaan harian.)

Batch yang **tidak pernah selesai** — pekerjanya hilang, atau job-nya dibuang
sebelum sempat menandai barisnya — ikut dibuang setelah tujuh kali TTL. Tanpa
jaring itu, batch seperti itu tidak memenuhi syarat penghapusan mana pun dan
mengendap selamanya.

#### Menghapus baris saja tidak mengecilkan berkasnya

SQLite di sini berjalan dengan `auto_vacuum = NONE`. Halaman bekas baris yang
dihapus masuk ke *freelist* dan dipakai ulang, tetapi **berkasnya tidak pernah
menyusut** — ia berhenti di ukuran tertinggi yang pernah dicapai. Satu batch
besar sekali saja cukup untuk membuatnya besar selamanya.

Terukur, dengan 200 batch × 25 baris berisi hasil berkolom lengkap:

| Tahap | Ukuran berkas |
| ----- | ------------- |
| Kosong | 0,04 MB |
| Terisi 5.000 baris | 3,52 MB |
| Sesudah `DELETE` semuanya | **3,52 MB** — tidak berubah, 890 halaman menganggur |
| Sesudah `VACUUM` | **0,04 MB** (7 ms) |

Karena itu penyapuan terjadwal diikuti `VACUUM`. Ia mengunci database selama
berjalan dan tidak boleh berada di dalam transaksi, jadi hanya dijalankan pada
penyapuan harian — bukan pada tiap batch yang masuk — dan hanya kalau memang
ada yang terhapus.

Kalau `VACUUM` gagal, penyapuannya tetap dianggap berhasil: yang batal hanyalah
pengembalian ruang disk, bukan penghapusan datanya.

#### Kalau kelak perlu lebih dari satu node

SQLite mengikat antrean ke satu mesin. Menjalankan beberapa instance berarti
pindah ke Postgres: `Oban.Engines.Lite` diganti `Oban.Engines.Basic`, tambahkan
`postgrex`, dan hapus pembebasan job yatim saat start — dengan banyak node,
job berstatus `executing` belum tentu yatim. Selebihnya tidak berubah.

### Menjalankan seluruhnya di Docker

`Dockerfile` di akar proyek membangun aplikasi Phoenix sebagai OTP release;
sidecar punya `scraper/Dockerfile` sendiri. Image aplikasi dibangun dua tahap,
sehingga hasil akhirnya tidak memuat Elixir, Mix, maupun kode sumber.

Service `app` memakai profile Compose agar `docker compose up -d` biasa tetap
hanya menyalakan sidecar — alur development (Phoenix di host) tidak berubah.

```bash
# siapkan secret sekali saja
echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" >> .env

# jalankan keduanya: sidecar + Phoenix
docker compose --profile app up -d --build

curl http://localhost:4000/api/health
```

Tanpa `--profile app`, hanya sidecar yang menyala:

```bash
docker compose up -d          # sidecar saja, untuk development
```

| Variabel | Wajib | Keterangan |
| -------- | ----- | ---------- |
| `SECRET_KEY_BASE` | **ya** | Hasilkan dengan `mix phx.gen.secret`. Container menolak start tanpa ini |
| `APP_PORT` | tidak | Port di host untuk Phoenix (default `4000`) |
| `PHX_HOST` | tidak | Nama host publik, dipakai membentuk URL (default `localhost`) |

Di dalam jaringan Compose, Phoenix menghubungi sidecar lewat nama servicenya
(`SCRAPER_URL=http://scraper:3000`) — sudah diatur otomatis. Service `app` juga
menunggu sidecar berstatus `healthy` sebelum dijalankan.

#### Membangun image saja

```bash
docker build -t maps-scraper-app:latest .

docker run --rm -p 4000:4000 \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e SCRAPER_URL=http://host.docker.internal:3000 \
  maps-scraper-app:latest
```

#### Hal yang perlu diketahui

- **HTTPS dipaksa di produksi.** `config/prod.exs` menyalakan `force_ssl`, jadi
  permintaan HTTP dialihkan ke HTTPS — kecuali untuk host `localhost` dan
  `127.0.0.1`, yang sengaja dikecualikan supaya pengujian lokal dan healthcheck
  container tetap jalan. Di produksi, taruh image ini di belakang reverse proxy
  yang menangani TLS dan meneruskan header `x-forwarded-proto`.
- **Healthcheck container menganggap `503` tetap sehat.** `/api/health` membalas
  `503` saat sidecar mati; yang diperiksa di sini adalah Phoenix-nya hidup atau
  tidak. Kesehatan sidecar diperiksa pada servicenya sendiri.
- **Versi dipatok** di `ARG` teratas `Dockerfile` (Elixir 1.18.4 / OTP 28.0.3).
  Samakan dengan versi pengembangan; cek dengan `elixir --version`.
- Release dijalankan sebagai user `nobody`, bukan root.

### Menjalankan dengan n8n

n8n tersedia di `docker-compose.yml` sebagai profil tersendiri, dan berada di
jaringan yang sama dengan service lain — jadi dari alur kerja n8n, API ini
dipanggil cukup dengan nama service:

```
http://app:4000/api/places
http://app:4000/api/validations
```

Tidak perlu IP, tidak perlu `network_mode`, tidak perlu `links`. Semua service
dalam satu berkas compose otomatis berbagi jaringan `default`, dan DNS internal
Docker menjawab nama service maupun `container_name`.

Cara menjalankannya bergantung di mana Phoenix hidup:

```bash
# Phoenix ikut sebagai container -> n8n memanggil http://app:4000
docker compose --profile app --profile n8n up -d

# Phoenix dijalankan di host dengan `mix phx.server`
# -> n8n memanggil http://host.docker.internal:4000
docker compose --profile n8n up -d
```

Skenario kedua tetap bekerja di Linux karena compose sudah memetakan
`host.docker.internal` ke gateway host; tanpa itu nama tersebut hanya ada di
Docker Desktop.

> **Jangan arahkan n8n ke `http://scraper:3000`.** Itu sidecar internal — tanpa
> antrean, tanpa validasi parameter, tanpa vonis, dan tanpa retry. Pintu masuknya
> `app`. Di `docker-compose.prod.yml` porta sidecar bahkan tidak dipublikasikan
> sama sekali.

#### Catatan: `force_ssl` dan pemanggil internal

`config/prod.exs` menyalakan `force_ssl`, dan pengecualiannya semula hanya
`localhost` dan `127.0.0.1`. Akibatnya permintaan ke `http://app:4000` dari dalam
jaringan Docker dijawab **301 ke `https://PHX_HOST`** — dan gagal di sana, karena
tidak ada TLS di jaringan internal. Nama service internal kini ikut dikecualikan:

```elixir
exclude: [hosts: ["localhost", "127.0.0.1", "app", "maps_scraper_app"]]
```

Terukur dari dalam container n8n sesudahnya:

| `Host:` | Hasil |
| ------- | ----- |
| `app:4000`, `maps_scraper_app:4000`, `localhost` | `200` |
| `api.contoh.test` (host publik) | `301` — pengalihan HTTPS tetap berlaku |

Jadi lalu lintas publik tetap dipaksa HTTPS; hanya pemanggil internal yang
dilewatkan. Kalau Anda mengganti nama service di compose, atau menambah pemanggil
internal lain, perbarui daftar itu — kalau tidak gejalanya persis seperti di atas:
`301` ke host yang tidak melayani apa pun.

Antarmuka n8n ada di `http://localhost:5678`. Alur kerja, kredensial, dan riwayat
eksekusinya disimpan di volume bernama `n8n_data`, jadi selamat dari
`docker compose down` — hanya `down -v` yang menghapusnya.

Untuk memanggil endpoint massal dari n8n, ingat pola dua langkahnya: node HTTP
Request pertama `POST /api/validations` (membalas `202` + `job_id`), lalu node
kedua `GET /api/validations/{{ $json.job_id }}` yang diulang — biasanya dengan
node **Wait** di antaranya — sampai `status` menjadi `done`.

### Produksi

`docker-compose.yml` ditujukan untuk development — ia **membangun** image dari
source. Produksi memakai berkas tersendiri yang **menarik image jadi** dari
registry:

| | Development | Produksi |
| --- | --- | --- |
| Asal image | `build:` dari source | `image:` dari registry |
| Porta sidecar | dipublikasikan `3000:3000` | **tidak dipublikasikan sama sekali** |
| Porta Phoenix | `0.0.0.0:4000` | `127.0.0.1:4000` (di belakang reverse proxy) |
| Phoenix | di balik profil `app` | selalu menyala |
| Batas memori | tidak ada | sidecar 1,5 GB, Phoenix 512 MB |
| Log | tak terbatas | dirotasi, 10 MB × 5 |
| `stop_grace_period` | bawaan 10 detik | 30 detik |

Ia **berdiri sendiri, bukan override.** Menumpuknya di atas `docker-compose.yml`
(`-f ... -f ...`) tidak akan menghasilkan yang diinginkan: override hanya bisa
menambah, tidak bisa mencabut — dan `ports:` sidecar justru yang paling perlu
hilang.

Karena tidak ada `build:`, berkas ini bisa disalin **sendirian** ke server tujuan
tanpa source code, cukup ditemani `.env` di sebelahnya.

#### 1. Bangun dan dorong image

Keduanya sekaligus lewat `script.sh`:

```bash
./script.sh                  # bangun + dorong keduanya, tag :latest
./script.sh -t v1.2.0        # tag :v1.2.0 sekaligus :latest
./script.sh --no-push        # bangun saja
./script.sh --scraper-only   # hanya sidecar
./script.sh -n namespace-anda
```

Setelah mendorong, skrip mencetak baris `APP_IMAGE=` dan `SCRAPER_IMAGE=` yang
sudah berisi digest — tinggal disalin ke `.env` produksi.

| Opsi | Guna |
| ---- | ---- |
| `-t, --tag TAG` | Tag versi; `:latest` ikut ditandai kecuali `--no-latest` |
| `-n, --namespace NS` | Ganti namespace registry (default `kurniawan026`) |
| `--app-only` / `--scraper-only` | Hanya salah satu image |
| `--no-push` | Bangun saja, jangan terbitkan |
| `-y, --yes` | Lewati konfirmasi sebelum mendorong |

Karena mendorong berarti menerbitkan ke registry publik, skrip meminta
konfirmasi lebih dulu — kecuali diberi `-y` atau dijalankan tanpa terminal (CI).
Repo-nya bisa ditimpa penuh lewat `APP_REPO` / `SCRAPER_REPO`.

Kalau ingin manual:

```bash
docker build -t kurniawan026/maps_validator:latest .          && docker push kurniawan026/maps_validator:latest
docker build -t kurniawan026/maps_scraper_sidecar:latest ./scraper && docker push kurniawan026/maps_scraper_sidecar:latest
```

Dorongan pertama sidecar memakan waktu — lapisan Playwright-nya beberapa giga
(~3,5 GB). Dorongan berikutnya jauh lebih ringan selama base image-nya tidak
berubah; image Phoenix hanya ~192 MB.

#### 2. Jalankan di server

```bash
export SECRET_KEY_BASE=$(mix phx.gen.secret)   # sekali saja, lalu simpan
export PHX_HOST=api.domain-anda.com

docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps
```

Nama image bisa ditimpa lewat `APP_IMAGE` dan `SCRAPER_IMAGE` tanpa menyentuh
berkas compose-nya.

#### Patok dengan digest, bukan `:latest`

`:latest` berpindah tanpa jejak — Anda tidak bisa tahu versi mana yang sedang
jalan, dan tidak punya jalan pulang saat rilis bermasalah. Untuk produksi,
pakai digest yang dicetak `docker push`:

```bash
APP_IMAGE=kurniawan026/maps_validator@sha256:b1412011270110f17a616b707e0a11fed0fa7857314217391b172ea841c0b315
```

Rollback jadi sekadar mengganti digest dan `up -d` lagi.

Selama masih memakai tag bergerak, `pull_policy: always` pada kedua service
mencegah jebakan klasik: `up -d` yang diam-diam menjalankan image lama dari cache
host karena tag-nya kebetulan sama.

Tiga hal yang perlu dipahami sebelum menyalakannya:

- **Sidecar sengaja tidak punya porta yang dipublikasikan.** Ia menerima `query`
  berupa URL lalu membukanya dengan browser sungguhan, tanpa autentikasi apa pun.
  Mempublikasikannya berarti menyerahkan browser itu ke siapa saja yang bisa
  menjangkau porta tersebut. Phoenix menghubunginya lewat nama service di jaringan
  internal. Untuk memeriksanya saat berjalan, pakai
  `docker compose -f docker-compose.prod.yml exec scraper node -e "fetch('http://127.0.0.1:3000/health').then(r=>r.text()).then(console.log)"`.
- **`SECRET_KEY_BASE` dan `PHX_HOST` wajib** — tanpa keduanya `up` gagal dengan
  pesan yang menyebut variabel mana yang kosong, bukan menyala dengan nilai
  contoh.
- **Reverse proxy wajib meneruskan `X-Forwarded-Proto: https`.** Tanpa itu
  `force_ssl` akan mengalihkan ke HTTPS terus-menerus.

Batas memorinya diambil dari tabel di [Kebutuhan memori](#kebutuhan-memori):
puncak terukur sidecar 990 MB, Phoenix rata ~184 MB. Kalau Anda menaikkan
`VALIDATION_CONCURRENCY` atau `DETAIL_CONCURRENCY`, naikkan juga limitnya —
ingat keduanya saling mengalikan.

### Postman

Di `postman/` ada koleksi dan environment yang bisa langsung diimpor:

| Berkas | Isi |
| ------ | --- |
| `MapsScraper.postman_collection.json` | 11 request dalam 3 folder (Health, Places, Validations) |
| `MapsScraper.local.postman_environment.json` | `baseUrl` = `http://localhost:4000` |

Alur tercepat: jalankan **Health**, lalu **Validations → Kirim batch** (skrip
test-nya menyimpan `job_id` ke variabel `jobId` secara otomatis), lalu
**Ambil hasil job** berulang sampai `status` menjadi `done`.

Koleksinya memuat contoh untuk keempat bentuk input (nama, koordinat, URL, dan
`detail=true`) beserta dua contoh error, dan tiap request menjelaskan hal yang
mudah mengejutkan — `202` yang bukan hasil, job yang hilang setelah TTL, serta
arti `verdict` dan kandidat berimpit.

Naikkan timeout Postman kalau perlu: scraping sungguhan makan beberapa detik
sampai puluhan detik per query.

### Menempatkan scraper di server lain

Sidecar tidak terikat pada Phoenix maupun pada Docker. Satu-satunya tali ke Phoenix
adalah `SCRAPER_URL`; sisanya diatur environment. Ada tiga cara menjalankannya, dan
`GET /health` selalu melaporkan mode mana yang aktif:

```json
{ "status": "ok", "uptime": 4, "browser": { "mode": "connect", "endpoint": "ws://..." } }
```

**1. Bawa browser sendiri (default, dipakai di development)**

```bash
docker compose up -d --build     # mode: launch
```

**2. Server sudah punya Playwright — sambung ke Playwright server**

Di server tujuan, jalankan Playwright server-nya:

```bash
npx playwright run-server --host 0.0.0.0 --port 3001
```

lalu arahkan sidecar ke sana:

```bash
PLAYWRIGHT_WS_ENDPOINT=ws://host-playwright:3001/ docker compose up -d
```

Sidecar tidak lagi menjalankan browser apa pun. **Versi Playwright di kedua sisi
harus sama persis** (protokolnya terikat versi) — sidecar ini memakai `1.59.1`,
lihat `scraper/package.json`.

**3. Tanpa Docker sama sekali**

Butuh Node ≥ 20. Kalau browser Playwright sudah terpasang di server:

```bash
cd scraper
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --omit=dev
PLAYWRIGHT_BROWSERS_PATH=/path/ke/ms-playwright PORT=3000 node src/server.js
```

Atau sambungkan ke Chrome yang sudah berjalan dengan `--remote-debugging-port`:

```bash
PLAYWRIGHT_CDP_ENDPOINT=http://127.0.0.1:9222 node src/server.js
```

| Variabel | Default | Keterangan |
| -------- | ------- | ---------- |
| `PORT` / `HOST` | `3000` / `0.0.0.0` | Alamat sidecar |
| `PLAYWRIGHT_WS_ENDPOINT` | — | Pakai Playwright server yang sudah ada |
| `PLAYWRIGHT_CDP_ENDPOINT` | — | Pakai Chrome yang sudah berjalan |
| `DETAIL_CONCURRENCY` | `3` | Halaman detail yang dibuka bersamaan |
| `DETAIL_BUDGET_MS` | `60000` | Anggaran seluruh fase `detail=true`. Harus sejalan dengan `:detail_budget_ms` di `config/config.exs` |
| `MAX_CONCURRENT_SCRAPES` | `4` | Permintaan `/scrape` bersamaan; selebihnya dijawab `503 busy`. `0` mematikan |
| `SHUTDOWN_GRACE_MS` | `10000` | Batas waktu berhenti sebelum proses dihentikan paksa |
| `TZ` | `Asia/Jakarta` | Zona waktu, memengaruhi jam buka |

Di sisi Phoenix, cukup satu variabel:

```bash
SCRAPER_URL=http://alamat-server:3000 mix phx.server
```

### Catatan

- Google Maps tidak punya HTML yang stabil. Selektor DOM terkumpul di
  `scraper/src/extract.js` — itu berkas pertama yang perlu disesuaikan kalau suatu
  saat kolom mulai kosong.
- Panel Google terisi bertahap, jadi halaman dibaca berulang sampai dua pembacaan
  berturut-turut identik (`extractWhenStable` di `scraper/src/maps.js`).
- `detail=true` membuka satu halaman browser per hasil, jadi jauh lebih lambat.
  Atur `DETAIL_CONCURRENCY` di `docker-compose.yml` untuk menyeimbangkan kecepatan
  dan penggunaan memori.
- Kalau Phoenix ikut dijalankan di dalam Docker, arahkan `SCRAPER_URL` ke
  `http://scraper:3000`.
- Waktu tipikal: 2–6 detik per query; URL tidak lengkap paling lama (~20 detik)
  karena harus mencoba halaman tempat dulu sebelum jatuh ke pencarian.
