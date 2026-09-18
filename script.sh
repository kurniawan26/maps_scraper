#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${REGISTRY_NAMESPACE:-kurniawan026}"
APP_REPO="${APP_REPO:-}"
SCRAPER_REPO="${SCRAPER_REPO:-}"
TAG="latest"
PUSH=1
ALSO_LATEST=1
ASSUME_YES=0
BUILD_APP=1
BUILD_SCRAPER=1

die() { printf '\n[script] GAGAL: %s\n' "$*" >&2; exit 1; }
say() { printf '\n[script] %s\n' "$*"; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//' | head -n -1
  cat <<'EOF'
Opsi:
  -t, --tag TAG        Tag versi (default: latest)
  -n, --namespace NS   Namespace registry (default: kurniawan026)
      --app-only       Hanya image Phoenix
      --scraper-only   Hanya image sidecar
      --no-push        Bangun saja, jangan dorong
      --no-latest      Jangan ikut menandai :latest saat -t dipakai
  -y, --yes            Jangan tanya konfirmasi sebelum mendorong
  -h, --help           Tampilkan bantuan ini

Variabel lingkungan yang dikenali: REGISTRY_NAMESPACE, APP_REPO, SCRAPER_REPO
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tag)       TAG="${2:?-t butuh argumen}"; shift 2 ;;
    -n|--namespace) NAMESPACE="${2:?-n butuh argumen}"; shift 2 ;;
    --app-only)     BUILD_SCRAPER=0; shift ;;
    --scraper-only) BUILD_APP=0; shift ;;
    --no-push)      PUSH=0; shift ;;
    --no-latest)    ALSO_LATEST=0; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "opsi tidak dikenal: $1 (coba --help)" ;;
  esac
done

APP_REPO="${APP_REPO:-${NAMESPACE}/maps_validator}"
SCRAPER_REPO="${SCRAPER_REPO:-${NAMESPACE}/maps_scraper_sidecar}"
[ "$TAG" = "latest" ] && ALSO_LATEST=0

cd "$(dirname "$0")"
command -v docker >/dev/null 2>&1 || die "docker tidak ditemukan di PATH"
docker info >/dev/null 2>&1 || die "daemon Docker tidak dapat dihubungi"
[ -f Dockerfile ] && [ -f scraper/Dockerfile ] || die "dijalankan dari luar root proyek"

# Daftar apa yang akan dikerjakan, sebelum mengerjakannya.
targets=()
[ "$BUILD_APP" = 1 ]     && targets+=("${APP_REPO}:${TAG}|.|app (Phoenix)")
[ "$BUILD_SCRAPER" = 1 ] && targets+=("${SCRAPER_REPO}:${TAG}|./scraper|scraper (Playwright, ~3,5 GB)")
[ ${#targets[@]} -gt 0 ] || die "--app-only dan --scraper-only tidak bisa dipakai bersamaan"

say "Rencana:"
for t in "${targets[@]}"; do
  IFS='|' read -r image _ label <<<"$t"
  printf '  %-14s %s\n' "$label" "$image"
  [ "$ALSO_LATEST" = 1 ] && printf '  %-14s %s\n' "" "${image%:*}:latest"
done
printf '  %-14s %s\n' "dorong" "$([ "$PUSH" = 1 ] && echo ya || echo tidak)"

# Mendorong berarti menerbitkan image ke registry publik, jadi dikonfirmasi dulu
# kecuali diminta lain atau dijalankan tanpa terminal (CI).
if [ "$PUSH" = 1 ] && [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
  printf '\nDorong ke registry setelah build? [y/N] '
  read -r answer
  case "$answer" in [yY]*) ;; *) say "dibatalkan"; exit 1 ;; esac
fi

if [ "$PUSH" = 1 ] && ! grep -q '"auths"[[:space:]]*:[[:space:]]*{[[:space:]]*"' "${HOME}/.docker/config.json" 2>/dev/null; then
  say "Catatan: belum terlihat kredensial registry. Kalau push ditolak, jalankan 'docker login' lebih dulu."
fi

build_one() {
  local image="$1" context="$2" label="$3" start elapsed
  say "Membangun ${label} -> ${image}"
  start=$SECONDS
  docker build -t "$image" "$context"
  [ "$ALSO_LATEST" = 1 ] && docker tag "$image" "${image%:*}:latest"
  elapsed=$((SECONDS - start))
  say "Selesai dalam ${elapsed}s"
}

push_one() {
  local image="$1" start elapsed
  say "Mendorong ${image}"
  start=$SECONDS
  docker push "$image"
  [ "$ALSO_LATEST" = 1 ] && docker push "${image%:*}:latest"
  elapsed=$((SECONDS - start))
  say "Terdorong dalam ${elapsed}s"
}

for t in "${targets[@]}"; do
  IFS='|' read -r image context label <<<"$t"
  build_one "$image" "$context" "$label"
done

if [ "$PUSH" = 1 ]; then
  for t in "${targets[@]}"; do
    IFS='|' read -r image _ _ <<<"$t"
    push_one "$image"
  done

  # Digest baru diketahui setelah push. Ini yang sebaiknya dipakai di produksi:
  # tag bergerak tidak meninggalkan jejak versi dan tidak bisa di-rollback.
  say "Patok di .env produksi dengan digest berikut:"
  echo
  for t in "${targets[@]}"; do
    IFS='|' read -r image _ _ <<<"$t"
    repo="${image%:*}"
    digest=$(docker image inspect "$image" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
             | grep "^${repo}@" | head -1 || true)
    var=$([ "$repo" = "$APP_REPO" ] && echo APP_IMAGE || echo SCRAPER_IMAGE)
    if [ -n "$digest" ]; then
      echo "  ${var}=${digest}"
    else
      echo "  ${var}=${image}   # digest tidak terbaca, pakai tag"
    fi
  done
  echo
  say "Lalu: docker compose -f docker-compose.prod.yml pull && docker compose -f docker-compose.prod.yml up -d"
else
  say "Build selesai, tidak didorong (--no-push)."
fi
