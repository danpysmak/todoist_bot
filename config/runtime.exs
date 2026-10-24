import Config

if config_env() == :prod do
  owner = System.get_env("OWNER_TELEGRAM_ID")

  if is_nil(owner) and System.get_env("ALLOW_MULTI_USER") != "true" do
    raise "Set OWNER_TELEGRAM_ID for a personal bot, or explicitly ALLOW_MULTI_USER=true"
  end

  host = System.fetch_env!("APP_HOST")

  uri = URI.parse(host)

  unless uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
           uri.path == "/" and is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo),
         do: raise("APP_HOST must be a canonical HTTPS origin with a trailing slash")

  webhook = System.get_env("USE_WEBHOOK", "false")
  secret = System.get_env("WEBHOOK_TOKEN", "")

  if webhook == "true" and not Regex.match?(~r/\A[A-Za-z0-9_-]{32,256}\z/, secret),
    do: raise("WEBHOOK_TOKEN must be 32-256 URL-safe random characters")

  limit = System.get_env("MAX_ATTACHMENT_BYTES", "5000000") |> String.to_integer()
  if limit < 1 or limit > 20_000_000, do: raise("MAX_ATTACHMENT_BYTES must be 1..20000000")

  config :todoist_bot, TodoistBot.Repo, database: System.fetch_env!("DB_PATH")
  config :disco_log, enable: false

  config :todoist_bot,
    owner_telegram_id: if(owner, do: String.to_integer(owner), else: nil),
    bot_token: System.fetch_env!("BOT_TOKEN"),
    app_port: String.to_integer(System.get_env("PORT") || System.get_env("APP_PORT", "8080")),
    app_host: host,
    todoist_app_client_id: System.fetch_env!("TODOIST_APP_CLIENT_ID"),
    todoist_app_client_secret: System.fetch_env!("TODOIST_APP_CLIENT_SECRET"),
    use_webhook: webhook,
    webhook_token: secret,
    max_attachment_bytes: limit,
    webhook_max_connections: System.get_env("WEBHOOK_MAX_CONNECTIONS", "1") |> String.to_integer()
end
