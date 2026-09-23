# Image untuk aplikasi Phoenix (JSON API).
#
# Sidecar Playwright punya Dockerfile sendiri di scraper/Dockerfile — keduanya
# disatukan oleh docker-compose.yml.
#
# Dibangun dua tahap: tahap builder memuat Elixir dan toolchain untuk menghasilkan
# OTP release, lalu isinya disalin ke image Debian polos. Hasil akhirnya tidak
# memuat Elixir, Mix, maupun kode sumber.
#
# Versi dipatok agar build dapat diulang. Pastikan ELIXIR_VERSION dan OTP_VERSION
# cocok dengan yang dipakai saat pengembangan (lihat `elixir --version`).

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.3
ARG DEBIAN_VERSION=trixie-20260610

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}-slim"


# ---------------------------------------------------------------------------
# Tahap 1 — membangun release
# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependensi disalin dan dikompilasi lebih dulu, terpisah dari kode aplikasi,
# supaya lapisan ini tetap ter-cache selama mix.exs/mix.lock tidak berubah.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY lib lib
RUN mix compile

# runtime.exs dibaca saat container dijalankan, bukan saat dikompilasi, jadi
# disalin paling akhir agar perubahannya tidak membatalkan cache kompilasi.
COPY config/runtime.exs config/

RUN mix release


# ---------------------------------------------------------------------------
# Tahap 2 — image yang dijalankan
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

# libstdc++/openssl/libncurses dibutuhkan runtime Erlang; curl dipakai healthcheck.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Release menjalankan kode Elixir yang mengasumsikan UTF-8.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/maps_scraper ./

# Antrean validasi tersimpan di SQLite, jadi aplikasi ini menulis ke disk —
# tepat satu direktori, yang harus dipasangi volume kalau antreannya memang
# diharapkan selamat dari penggantian container.
ENV DATABASE_PATH=/app/data/maps_scraper.db
RUN mkdir -p /app/data && chown nobody:root /app/data
VOLUME ["/app/data"]

# Selain direktori data di atas, aplikasi tidak menulis apa pun — jadi tidak
# perlu berjalan sebagai root.
USER nobody

EXPOSE 4000

# /api/health membalas 503 kalau sidecar scraper sedang mati. Untuk healthcheck
# container ini yang diperiksa adalah Phoenix-nya sendiri hidup atau tidak,
# maka 503 tetap dianggap sehat — kesehatan sidecar diperiksa di servicenya.
HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=5 \
  CMD code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/api/health) \
      && { [ "$code" = "200" ] || [ "$code" = "503" ]; }

CMD ["/app/bin/maps_scraper", "start"]
