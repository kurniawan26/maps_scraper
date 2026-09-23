import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/maps_scraper start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Alamat sidecar scraper dapat ditimpa lewat environment, misalnya saat Phoenix
# ikut dijalankan di dalam Docker (SCRAPER_URL=http://scraper:3000). Sama seperti
# di atas, hanya kunci yang benar-benar diisi yang ditimpa.
# String.to_integer/1 menjatuhkan boot dengan ArgumentError tanpa menyebut
# variabel mana yang salah. Di sini nilainya diperiksa lebih dulu supaya pesan
# kegagalannya langsung menunjuk penyebabnya.
env_int = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      case Integer.parse(String.trim(value)) do
        {parsed, ""} ->
          parsed

        _ ->
          raise "environment variable #{name} harus berupa bilangan bulat, dapat: #{inspect(value)}"
      end
  end
end

env_float = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      case Float.parse(String.trim(value)) do
        {parsed, ""} ->
          parsed

        _ ->
          raise "environment variable #{name} harus berupa bilangan, dapat: #{inspect(value)}"
      end
  end
end

scraper_overrides =
  [
    base_url: System.get_env("SCRAPER_URL"),
    timeout: env_int.("SCRAPER_TIMEOUT_MS")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if scraper_overrides != [] do
  config :maps_scraper, :scraper, scraper_overrides
end

instagram_overrides =
  [timeout: env_int.("INSTAGRAM_TIMEOUT_MS")]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if instagram_overrides != [] do
  config :maps_scraper, :instagram, instagram_overrides
end

# Antrean validasi massal dapat disetel per-deployment tanpa rebuild.
#
# Berkas ini dievaluasi untuk SEMUA environment, termasuk test. Karena itu hanya
# kunci yang environment variable-nya benar-benar diisi yang ditimpa — kalau tidak,
# nilai dari config/test.exs akan tergilas dan test kehilangan setelannya.
validation_overrides =
  [
    concurrency: env_int.("VALIDATION_CONCURRENCY"),
    max_attempts: env_int.("VALIDATION_MAX_ATTEMPTS"),
    backoff_ms: env_int.("VALIDATION_BACKOFF_MS"),
    max_backoff_ms: env_int.("VALIDATION_MAX_BACKOFF_MS"),
    max_batch: env_int.("VALIDATION_MAX_BATCH"),
    job_ttl_ms: env_int.("VALIDATION_JOB_TTL_MS"),
    max_jobs: env_int.("VALIDATION_MAX_JOBS"),
    max_candidates: env_int.("VALIDATION_MAX_CANDIDATES"),
    match_threshold: env_float.("VALIDATION_MATCH_THRESHOLD"),
    review_threshold: env_float.("VALIDATION_REVIEW_THRESHOLD"),
    ambiguity_margin: env_float.("VALIDATION_AMBIGUITY_MARGIN")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if validation_overrides != [] do
  config :maps_scraper, :validation, validation_overrides
end

if System.get_env("PHX_SERVER") do
  config :maps_scraper, MapsScraperWeb.Endpoint, server: true
end

config :maps_scraper, MapsScraperWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :maps_scraper, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :maps_scraper, MapsScraperWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :maps_scraper, MapsScraperWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :maps_scraper, MapsScraperWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
