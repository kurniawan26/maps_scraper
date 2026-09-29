import Config

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

apify_overrides =
  [
    token: System.get_env("APIFY_TOKEN"),
    enabled:
      case System.get_env("APIFY_FALLBACK") do
        nil -> nil
        value -> String.downcase(String.trim(value)) not in ["false", "0", "off", ""]
      end,
    timeout_s: env_int.("APIFY_TIMEOUT_S"),
    max_charge_usd: env_float.("APIFY_MAX_CHARGE_USD"),
    maps_max_places: env_int.("APIFY_MAPS_MAX_PLACES")
  ]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if apify_overrides != [] do
  config :maps_scraper, :apify, apify_overrides
end

tiktok_overrides =
  [timeout: env_int.("TIKTOK_TIMEOUT_MS")]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if tiktok_overrides != [] do
  config :maps_scraper, :tiktok, tiktok_overrides
end

if max_concurrency = env_int.("SUBJECT_MAX_CONCURRENCY") do
  config :maps_scraper, :subject, max_concurrency: max_concurrency
end

marketplace_overrides =
  [timeout: env_int.("MARKETPLACE_TIMEOUT_MS")]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if marketplace_overrides != [] do
  config :maps_scraper, :marketplace, marketplace_overrides
end

website_overrides =
  [timeout: env_int.("WEBSITE_TIMEOUT_MS")]
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)

if website_overrides != [] do
  config :maps_scraper, :website, website_overrides
end

if cron = System.get_env("VALIDATION_CLEANUP_CRON") do
  config :maps_scraper, Oban,
    plugins: [
      {Oban.Plugins.Lifeline, rescue_after: {5, :minutes}},
      {Oban.Plugins.Pruner, max_age: {1, :day}},
      {Oban.Plugins.Cron, crontab: [{cron, MapsScraper.Validation.Cleaner}]}
    ]
end

if concurrency = env_int.("VALIDATION_CONCURRENCY") do
  config :maps_scraper, Oban, queues: [validation: concurrency]
end

if database = System.get_env("DATABASE_PATH") do
  config :maps_scraper, MapsScraper.Repo, database: database
end

validation_overrides =
  [
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
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :maps_scraper, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :maps_scraper,
         :ssl_exclude_hosts,
         System.get_env("SSL_EXCLUDE_HOSTS", "")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)

  config :maps_scraper, MapsScraperWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
