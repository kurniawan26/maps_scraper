# MapsScraper

JSON API untuk memverifikasi keberadaan sebuah tempat di Google Maps.

Aplikasi ini **hanya menyajikan JSON API**: tanpa frontend, database, email,
maupun terjemahan. Dependensi untuk semua itu — esbuild, Tailwind, LiveView,
Ecto/Postgres, Swoosh, Gettext — sengaja tidak dipasang, sehingga `mix setup`
cukup mengunduh dependensi Elixir saja dan tidak menyiapkan database apa pun.

## Maps Scraper API

API untuk **memastikan apakah sebuah tempat benar-benar ada di Google Maps**, dari
input yang bervariasi: nama tempat, alamat/lokasi, koordinat, atau URL Google Maps.
Scraping dikerjakan sidecar Playwright di Docker; Phoenix menyajikannya sebagai
HTTP API ber-response JSON.

```
klien  ->  Phoenix /api/places  ->  sidecar :3000 (Playwright)  ->  Google Maps
```

### Menjalankan

```bash
cp .env.example .env           # semua nilai sudah punya default, aman dibiarkan
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
| `GET`  | `/api/places?query=...` | Verifikasi lewat query string |
| `POST` | `/api/places` | Verifikasi lewat body JSON |
| `GET`  | `/api/health` | Status Phoenix + sidecar |

### Parameter

| Nama | Tipe | Default | Keterangan |
| ---- | ---- | ------- | ---------- |
| `query` | string | *wajib* | Nama tempat, alamat/lokasi, koordinat `lat,lng`, atau URL Google Maps |
| `limit` | integer | `20` | Jumlah maksimum hasil, 1–100 (hanya untuk pencarian) |
| `detail` | boolean | `false` | Buka tiap hasil untuk mengambil telepon, website, jam buka |
| `lang` | string | `id` | Bahasa hasil |
| `country` | string | `ID` | Region hasil |

### Membaca hasilnya

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

### Contoh

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

### Bentuk response

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

`rating` dan `reviews_count` bersifat sekunder dan tidak dijamin terisi — kartu
berbayar (`sponsored: true`) memang tidak memuatnya, dan Google merendernya menyusul.
Jangan pakai keduanya sebagai dasar keputusan.

### Error

```json
{ "error": { "code": "invalid_params", "field": "limit", "message": "harus di antara 1 dan 100" } }
```

| Status | `code` | Penyebab |
| ------ | ------ | -------- |
| `422` | `invalid_params` | Parameter tidak valid |
| `503` | `scraper_unavailable` | Sidecar belum jalan (`docker compose up`) |
| `504` | `timeout` | Scraping melewati batas waktu |

Tempat yang tidak ditemukan **bukan** error: statusnya tetap `200` dengan
`found: false`.

### Validasi massal (antrean job)

Untuk memeriksa banyak query sekaligus, kirim satu batch dan ambil hasilnya
belakangan. Pekerjaannya dijalankan `MapsScraper.Validation.Queue` — sebuah
GenServer yang menahan seluruh job di state-nya dan menjalankan paling banyak
`concurrency` query bersamaan.

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
```

| Method | Path | Keterangan |
| ------ | ---- | ---------- |
| `POST` | `/api/validations` | Kirim batch. Body: `queries` (daftar teks) + opsi `limit`/`detail`/`lang`/`country` yang berlaku untuk seluruh baris |
| `GET`  | `/api/validations/:id` | Status dan hasil job |
| `GET`  | `/api/validations` | Ringkasan antrean |

Hasil tiap baris sudah dipadatkan ke jawaban validasinya saja — `found`,
`best_match`, dan satu tempat teratas. Untuk daftar hasil lengkap sebuah query,
pakai `/api/places`.

```json
{
  "job_id": "iq-9VDY7UabOrjHJ",
  "status": "done",
  "total": 6,
  "valid_count": 4,
  "counts": { "pending": 0, "running": 0, "ok": 6, "error": 0 },
  "results": [
    {
      "index": 0,
      "query": "Monumen Nasional Jakarta",
      "status": "ok",
      "attempts": 1,
      "found": true,
      "best_match": 1,
      "place": { "name": "Monumen Nasional", "address": "...", "latitude": -6.1753083, "longitude": 106.8271106 }
    }
  ]
}
```

`valid_count` memakai aturan yang sama dengan bagian **Membaca hasilnya**:
`found == true` dan (`best_match == null` atau `best_match >= 0.5`). Jadi alamat
fiktif yang dijawab Google dengan tempat lain **tidak** ikut terhitung.

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
| Task-nya sendiri mati (crash, OOM) | ya |
| Parameter tidak valid | **tidak** — hasilnya tidak akan berubah |

Selama menunggu giliran ulang, barisnya berstatus `pending` dan membawa
`last_error` sehingga penyebabnya terlihat tanpa harus membuka log:

```json
{ "index": 0, "status": "pending", "attempts": 1,
  "last_error": { "code": "scraper_unavailable", "message": "Sidecar tidak dapat dihubungi" } }
```

Tiap baris dikerjakan task terpisah di bawah `Task.Supervisor` dan disambungkan
dengan `async_nolink/3`, sehingga task yang mati tidak menjatuhkan antrean —
kematiannya diperlakukan sebagai kegagalan sementara. Satu baris yang gagal juga
tidak menggagalkan baris lain dalam batch yang sama.

#### Setelan

Lewat environment, tanpa rebuild:

| Variabel | Default | Keterangan |
| -------- | ------- | ---------- |
| `VALIDATION_CONCURRENCY` | `3` | Query diproses bersamaan. Jangan melebihi kapasitas sidecar |
| `VALIDATION_MAX_ATTEMPTS` | `3` | Termasuk percobaan pertama (jadi 3 = 1 jalan + 2 ulang) |
| `VALIDATION_BACKOFF_MS` | `1000` | Jeda dasar sebelum percobaan ulang |
| `VALIDATION_MAX_BACKOFF_MS` | `30000` | Batas atas jeda |
| `VALIDATION_MAX_BATCH` | `500` | Baris maksimum per batch |

#### Batasan yang perlu diketahui

Antrean ini ada **di memori**. Kalau aplikasi di-restart, job yang belum selesai
ikut hilang dan `GET /api/validations/:id` membalas `404`. Untuk fase development
itu sepadan dengan kesederhanaannya.

Sebelum dipakai produksi, job perlu disimpan di penyimpanan yang tahan restart
agar batch panjang tidak hilang saat deploy dan bisa dikerjakan beberapa node
sekaligus. Perlu diingat proyek ini **tidak lagi memasang Ecto/Postgres**, jadi
langkah itu berarti menambahkan kembali `ecto_sql` + `postgrex` (atau memakai
penyimpanan lain), bukan sekadar memindahkan state.

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
