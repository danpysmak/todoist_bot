# TodoistBot

Forward text, photos, or files to your private Telegram bot to create tasks in your Todoist Inbox. Files are uploaded to Todoist and attached to task comments, not linked through Telegram's private download URL.

- Photos (largest resolution), documents, audio/voice, videos/video notes, animations, and all sticker formats.
- Captions become task titles; filename/type fallback for file-only messages. Albums share one task and keep a comment per item.
- Persistent SQLite inbox and checkpoints, retry-safe Todoist Sync writes, and `/retry` replies to original messages.
- Existing `/help`, `/about`, `/logout` and per-user Todoist OAuth retained; personal owner restriction required by default in production.
- Default 5 MB per-file cap; configurable to 20 MB maximum, still subject to the Todoist account plan.

## Deploy / operate

Read [Railway runbook](docs/railway.md) and [operations](docs/operations.md). Configure an approved new bot/service first; do not attach a second deployment to an existing production token.

Production uses a Docker release, a persistent `/data` volume, and OAuth scope `data:read_write`. A Todoist personal token is not the implemented authorization flow. Old `task:add` users must log out and authorize again.

## Verify locally

Use the versions in `.tool-versions` (Elixir 1.19.5 / OTP 28.3.1).

```sh
MIX_ENV=test mix local.hex --force
MIX_ENV=test mix local.rebar --force
MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix format --check-formatted
MIX_ENV=test mix test
MIX_ENV=prod mix release --overwrite
```

Tests use synthetic fixtures and Req/Mox test adapters, not real provider credentials. They do not prove live uploads or Railway deployment. CI also builds and smoke-starts the Docker image.

![Original bot demo](demo.png)
