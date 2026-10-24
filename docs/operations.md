# Project operations

## Scope and ownership

- Source fork: `danpysmak/todoist_bot`; default branch `master`; baseline `81253e9b1256147838520e76b8c3ab93b0974bcb`.
- Candidate work is on `feat/telegram-attachments`. Publish a PR; never merge or replace the current bot merely because GitHub WRITE access exists.
- Actual production bot owner, host, deployment identity, token, and rollback remain unverified. No deployment was performed. Railway CLI is installed but unauthorized; no relevant credential metadata was found among the approved vault's eleven records.
- Secret source: DN Agent 1Password vault, accessed through the approved `/Users/dp-mac-mini/agent/scripts/op-sa` wrapper. No credentials belong in this repo or logs.
- The requested `docs/AGENTS.md` could not be written: host policy requires interactive approval for agent-instruction files. This human-readable operations guide preserves the operational handoff; it is not a claim that the protected file was created.

## Architecture / invariants

1. Webhook validates URL path and Telegram secret header, then inserts the complete update into SQLite before 200. Poller inserts before acknowledging `getUpdates` offset. Inbox identity includes bot numeric identity and Telegram `update_id`.
2. One serialized inbox worker processes updates. Delayed responses/crashes back off; ten failures are retained as dead letters, without starving subsequent messages. Completed rows discard their payload. Task/caption/title checkpoints and Todoist URLs remain private persisted data.
3. The actual sender/private-chat owner is checked before user, OAuth, or capture work. Never authorize forwarded origin/username instead. Production requires owner ID or explicit multi-user opt-in.
4. Capture keys include bot identity, sender, chat, message/album. Same-key capture is locked within the single instance. SQLite persists task, uploaded attachment metadata, and comment identifiers. Replaying uses the same command UUIDs; `/retry` must reply to the original message. A fresh send is a new request.
5. Todoist `item_add`/`note_add` use the current v1 Sync API, not removed `X-Request-Id` REST semantics. File upload uses the documented raw-binary endpoint with sanitized filename/MIME headers. Upload itself is not exactly-once: a crash before checkpointing can orphan an upload.
6. OAuth requests `data:read_write`; exact unpredictable state is verified before exchange, then rotated on success. Logout side effects have a durable callback checkpoint. Replayed confirmations cannot delete newly reauthorized credentials.
7. Production Ecto parameter logging is disabled (`log: false`), Logger is `:info`, Discord is disabled, and request paths are not logged. Don't turn SQL logging/debug tracing on for live payloads. Do not log raw errors or inspect complete interactions/Req structs.
8. A fixed Telegram download host, validated relative paths, no redirects, raw non-decoding download, and streaming byte ceiling keep token links and files server-side. No arbitrary user URL fetching is implemented.

## Verification

See README for tests/build commands and `docs/railway.md` for live acceptance. `scripts/smoke_release.exs` configures a global Req fake before startup and uses only explicitly synthetic environment values; it exercises the real production release, migrations, and a TCP HTTP health request. `scripts/check_smoke_log.py` checks captured output for success and private marker leaks without echoing marker values. CI runs tests, release smoke, Docker build, and an offline Docker runtime smoke with external networking disabled.

Do not equate test adapters, synthetic fixtures, or offline release startup with live Telegram/Todoist/Railway acceptance. Docker was unavailable locally; its actual CI result must be recorded against the exact PR head.

## Queue inspection / recovery

On the authorized service, use a private operator console or SQLite client against the mounted database. These read-only queries return counters only:

```sql
SELECT COUNT(*) AS pending FROM incoming_updates WHERE done = 0;
SELECT COUNT(*) AS dead_letters FROM incoming_updates WHERE done = 1 AND attempts >= 10;
```

`/healthz` checks DB/HTTP readiness, not providers or queue emptiness. Investigate content-free dead-letter alerts. Stop the writer and make a consistent backup before manual repair; inspect payloads privately only if needed. Once the cause is corrected, requeue only the reviewed row using a parameterized update, never a broad mass reset:

```sql
UPDATE incoming_updates
SET done = 0, attempts = 0, next_attempt_at = NULL
WHERE key = ? AND attempts >= 10;
```

Restart the same single service/database, verify that exact row completes, and read back the task/comment. Don't delete capture checkpoints, reset all users, or publish raw payloads. Caption/file pipeline errors that were successfully reported to Telegram are completed inbox rows; use `/retry` to the original message instead of requeueing arbitrary entries.

## Dependencies / residual advisories

The original lockfile had multiple high-severity HTTP/parser advisories. Dependencies were refreshed and exercised with tests/release builds. Current Hex still reports advisories for Req 0.5.x (multipart header injection and automatic decompression) and one Cowlib link-header encoder advisory. This implementation avoids Req multipart by using raw upload headers after sanitization, and file downloads are streamed with `raw: true`/`decode_body: false`; it does not construct untrusted Cowlib Link headers. Provider JSON responses remain trusted HTTPS responses and do not decode user files. These mitigations do not mean the dependencies are advisory-free; recheck before deployment and upgrade to compatible patched releases when available.

## Deployment/update boundary

Use the full Railway runbook. One persistent `/data` volume, one replica/consumer, migrations at startup, no pre-deploy migration, no rolling overlap with the same bot token. Preserve backups and review current-code/current-data rollback compatibility. Never invoke a restored copy against the live Telegram identity without stopping its previous consumer.

One-time autonomy prerequisites: owner-selected Railway project/service/environment IDs plus a scoped deploy token and approved existing-plan budget; owner-installed Railway GitHub integration limited to this repo/approved branch; verified bot ownership and privately stored token; Todoist OAuth app credentials and Daniel's consent. Missing grants are deployment gates, not reasons to use another bot's credentials or purchase infrastructure.
