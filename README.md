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

Fase `detail=true` punya anggaran waktu sendiri (`DETAIL_BUDGET_MS`, default 60
detik untuk seluruh permintaan). Tanpa batas itu lamanya tumbuh mengikuti `limit`
dan selalu melewati batas waktu pemanggil. Tempat yang tidak kebagian waktu
ditandai `"detail_skipped": true` — kolom dari kartu hasil tetap terisi, hanya
kolom yang butuh membuka halaman yang kosong.

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
| `503` | `busy` | Sidecar sedang penuh; ulangi sesuai header `Retry-After` |
| `504` | `timeout` | Scraping melewati batas waktu |

Tempat yang tidak ditemukan **bukan** error: statusnya tetap `200` dengan
`found: false`.

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
| 1 GB | Tidak disarankan — beban puncak sudah melewatinya |
| **2 GB** | Minimum. Pakai default (`VALIDATION_CONCURRENCY=3`), hindari validasi massal dengan `detail=true` |
| **4 GB** | Nyaman. Seluruh beban di tabel muat dengan sisa lega |

Batasi juga memori containernya lewat `deploy.resources.limits.memory` di Compose
supaya sidecar yang membengkak tidak menjatuhkan proses lain di server yang sama.
`BROWSER_IDLE_TIMEOUT_MS` mengembalikan pemakaian ke 229 MB saat sepi.

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
| `VALIDATION_JOB_TTL_MS` | `900000` | Hasil job bisa diambil selama ini setelah selesai. `0` mematikan |
| `VALIDATION_MAX_JOBS` | `1000` | Batas jumlah job tersimpan. `0` mematikan |

#### Batasan yang perlu diketahui

Antrean ini ada **di memori**. Kalau aplikasi di-restart, job yang belum selesai
ikut hilang dan `GET /api/validations/:id` membalas `404`. Untuk fase development
itu sepadan dengan kesederhanaannya.

Karena itu pula hasil job **tidak disimpan selamanya**: setelah `VALIDATION_JOB_TTL_MS`
lewat, job dibuang dan id-nya membalas `404`. Kalau jumlah job melewati
`VALIDATION_MAX_JOBS`, yang dibuang lebih dulu adalah job selesai yang paling tua —
job yang masih berjalan tidak pernah dikorbankan. Ambil hasilnya sebelum TTL habis.

Sebelum dipakai produksi, job perlu disimpan di penyimpanan yang tahan restart
agar batch panjang tidak hilang saat deploy dan bisa dikerjakan beberapa node
sekaligus. Perlu diingat proyek ini **tidak lagi memasang Ecto/Postgres**, jadi
langkah itu berarti menambahkan kembali `ecto_sql` + `postgrex` (atau memakai
penyimpanan lain), bukan sekadar memindahkan state.

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
