import Config

config :todoist_bot, TodoistBot.Repo, busy_timeout: 10_000, pool_size: 1, log: false
config :logger, level: :info
