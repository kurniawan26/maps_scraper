ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.3
ARG DEBIAN_VERSION=trixie-20260610

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}-slim"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

COPY config/runtime.exs config/

RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/maps_scraper ./

ENV DATABASE_PATH=/app/data/maps_scraper.db
RUN mkdir -p /app/data && chown nobody:root /app/data
VOLUME ["/app/data"]

USER nobody

EXPOSE 4000

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=5 \
  CMD code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/api/health) \
      && { [ "$code" = "200" ] || [ "$code" = "503" ]; }

CMD ["/app/bin/maps_scraper", "start"]
