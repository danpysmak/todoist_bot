# Railway deployment and operations

This runbook targets the attachment-support release, not the original `master` deployment. Read [change-brief.md](change-brief.md) and [operations.md](operations.md) before operating it. Examples are configuration templates, not evidence of a deployment. No live Railway, Telegram, or Todoist smoke test is claimed here.

## 1. Safety and prerequisites

**Use a new, privately owned test bot first.** Do not reuse the current bot token until its owner, current hosting service, update delivery mode, persisted database, deployment integration, and rollback route have been inspected. A token can have only one active delivery configuration: another deployment can steal its webhook or compete for polling updates. Never run a local poller against the production token.

Required access and decisions:

- Railway project, service, and environment selected by the owner; permission to deploy and attach a persistent volume; explicit billing approval on an existing plan. Do not purchase a plan or resource without approval.
- Repository and deployment branch selected by the owner. The owner installs/authorizes the GitHub integration for the intended repository only. Repository write permission alone does not grant Railway or billing access.
- Telegram bot owned by Daniel. In Telegram, the owner opens the verified **@BotFather**, uses `/newbot`, selects a name and unique bot username, and retains ownership. Creating a bot or accessing its token is an owner action, not implied by GitHub access. Disable group joining if appropriate; application-level private-chat/sender enforcement remains mandatory.
- Daniel's numeric Telegram user ID from a trusted, owner-controlled source. A username is not an ID; do not use an unrelated public ID bot as a credential prerequisite.
- Todoist application client ID and client secret, and Daniel available for one-time OAuth consent. Preserve per-user OAuth; a personal API token is not a substitute for this flow.
- Approved credential injection through the DN Agent vault wrapper by an authorized operator. Do not put credentials in this document, chat, commits, command history, screenshots, support logs, or a checked-in `.env`. This document does not retrieve or handle secrets.

Known discovery gates at handoff: Railway CLI 4.36.0 was installed but `whoami` was unauthorized; no matching Railway/Todoist/Telegram credential metadata was found in the approved DN Agent vault; Docker daemon access was denied. GitHub access to `danpysmak/todoist_bot` did not establish deployment ownership or production authorization. These are gates, not permission to work around access controls.

## 2. Release readiness gate

The original baseline had a Docker command that built a release instead of starting it, a release environment script that blanked injected variables, mandatory Discord logging, and no attachment checkpoint workflow. **Do not deploy that baseline using this runbook.** Verify the candidate branch implements the following before proceeding:

- Docker image builds a production release during image build and runs `bin/todoist_bot start` (from its release directory) as its foreground process. Railway should use the Dockerfile; no `mix release` start-command override.
- `rel/env.sh.eex` preserves Railway-injected environment variables.
- Runtime configuration matches the table below, including owner restriction, limits, and webhook validation.
- Startup runs database migrations after the runtime volume is mounted. **Do not configure a Railway pre-deploy migration command:** the application volume is not a build/pre-deploy database.
- `/healthz` checks database access; attachment processing is synchronous before webhook success acknowledgment or uses a durable inbox. A fire-and-forget task followed immediately by HTTP 200 is not safe delivery.
- Durable task/upload/comment checkpoints and stable Sync command UUIDs are included in the deployed schema/code.

The candidate includes these changes. Verify the deployed commit and exact-head CI before deploying; a previous green revision is not release evidence for a newer one.

## 3. Exact environment contract

Set variables in the chosen Railway **service/environment**, not in the Docker image. Boolean values below are literal lowercase strings.

| Variable | Required / value | Purpose |
| --- | --- | --- |
| `BOT_TOKEN` | Required; private injection | Token for the selected owner-controlled bot. |
| `OWNER_TELEGRAM_ID` | Required in production personal mode; numeric user ID | Authorizes the actual sender in a private chat before database/OAuth/task work. |
| `ALLOW_MULTI_USER` | Leave unset or `false` | Explicit `true` permits compatibility multi-user mode instead of requiring an owner ID; not recommended for this personal deployment. Private-chat enforcement still applies. |
| `TODOIST_APP_CLIENT_ID` | Required | Todoist OAuth application client ID. |
| `TODOIST_APP_CLIENT_SECRET` | Required; private injection | Todoist OAuth client secret. |
| `APP_HOST` | Required; canonical `https://your-domain/` | Public HTTPS base URL, including the trailing slash. No query or fragment. Used for authorization links and webhook construction. |
| `DB_PATH` | Required; `/data/todoist_bot.db` | SQLite file on the persistent Railway volume mounted at `/data`. |
| `PORT` | Provided by Railway | HTTP listening port; takes precedence over `APP_PORT`. Configure public networking to route to this port. |
| `APP_PORT` | Optional; defaults to `8080` when `PORT` is absent | Local/non-Railway fallback. Do not override Railway's `PORT` unnecessarily. |
| `USE_WEBHOOK` | Set `true` on Railway; default `false` | Webhook mode recommended. `false` selects polling, not both. |
| `WEBHOOK_TOKEN` | Required when `USE_WEBHOOK=true`; random 32–256 characters from `A-Z a-z 0-9 _ -` | URL path segment and Telegram secret-header value. Generate/inject privately; no default/shared placeholder. Treat the resulting webhook URL as sensitive. |
| `WEBHOOK_MAX_CONNECTIONS` | Optional; default `1` | Keep at `1` for the single-instance SQLite deployment. |
| `MAX_ATTACHMENT_BYTES` | Optional; default `5000000`, hard maximum `20000000` | Per-file byte ceiling, not a count of attachments. Keep default unless the account's actual Todoist upload allowance is verified. |
| `DISCO_LOG_TOKEN` | Leave unset | External Discord logging is disabled by default; no need to enable it for deployment. |
| `DISCO_INFO_CHANNEL_ID`, `DISCO_ERROR_CHANNEL_ID` | Leave unset | Discord is disabled in this release; setting these variables does not enable it. |

`WEBHOOK_URL` is unused. The endpoint is `POST /:token/`, for example `https://your-domain/<private-path-segment>/`; never paste the real URL into public tickets. Startup registers Telegram `secret_token=WEBHOOK_TOKEN`. Every request must also carry `X-Telegram-Bot-Api-Secret-Token: <WEBHOOK_TOKEN>`; knowing just the path is insufficient. It is not the bot token.

Keep standard platform logs sanitized. Do not log raw Telegram updates, OAuth codes/state, access tokens, token-bearing file URLs, attachment contents, or upstream error bodies. Do not enable Discord logging to diagnose a deployment.

## 4. Configure Railway and Todoist

1. Create/select the approved project and environment, then a single service linked to the approved GitHub repository and feature/release branch. Review auto-deploy behavior so unrelated branch pushes cannot unexpectedly deploy. Do not merge or push merely to trigger a deployment without authorization.
2. Use the repository Dockerfile build. Configure **one replica** and no competing service, worker, cron process, or local runner using this bot token. Ensure deployment replacement stops the old process before starting another consumer; do not rely on a nominal replica count to guarantee no rolling overlap.
3. Attach a persistent Railway volume to this service at **`/data`**. Set `DB_PATH=/data/todoist_bot.db`. Container-local storage, build artifacts, and files outside that mount do not preserve OAuth/checkpoint state across replacement.
4. Allocate a public Railway HTTPS domain (or an approved custom domain) and record the final canonical `APP_HOST` with trailing slash. Configure routing to the runtime HTTP port.
5. In Todoist's developer application settings, register the exact redirect URI **`https://your-domain/authorization/finish`**. It must match the bot's public host, path, and HTTPS scheme. Do not add a trailing slash to that callback path unless the implementation and provider registration explicitly agree.
6. Populate the environment contract using the approved injection mechanism. Keep optional Discord settings absent. Set Railway healthcheck path to **`/healthz`**. There is no pre-deploy migration command.
7. Deploy the candidate after the readiness gate. Startup must migrate the mounted database and keep the release running. Check sanitized logs for startup/migration/port errors, not credentials.
8. Confirm `GET https://your-domain/healthz` succeeds. This proves HTTP/database readiness only, not Telegram delivery, authorization, or Todoist upload success.
9. With approved operator tooling, inspect Telegram `getWebhookInfo`: expected private endpoint, `max_connections=1`, and no persistent delivery error. Do not paste its URL or raw output into reports. Startup manages webhook registration; don't add a second registration script racing the application.
10. Send `/help` to the new bot in Daniel's private chat and complete the OAuth smoke test below before using real attachments.

### OAuth and existing users

The flow starts with the bot's authorization button, serves `/authorize`, and returns to `/authorization/finish`. Request Todoist scope **`data:read_write`** for task/comment/upload access. OAuth state must be cryptographically random, matched exactly before exchanging the code, and consumed after successful authorization; a callback without the expected state must not authorize anyone.

An old token granted only `task:add` is insufficient for attachments. Use `/logout`, confirm, then initiate authorization again and have Daniel grant the new scope. Confirm logout and existing `/help` and `/about` behavior remain available. Consent is a human action; do not attempt to automate Daniel's provider login or bypass it.

## 5. Webhook versus polling

Use webhook mode for Railway. Telegram must reach the public HTTPS endpoint. The handler commits the update into SQLite before returning 200; a single background inbox worker performs remote task/upload/comment writes. A failed database commit must not acknowledge success. Queue failures are isolated as described below.

Polling is an alternative with `USE_WEBHOOK=false`. HTTP remains needed for OAuth and health checks. Before switching modes:

1. Record the known-good revision, mode, host, volume, and rollback plan without exposing secrets; stop the old consumer.
2. For polling, ensure the old webhook is deleted through the application's supported startup behavior or approved operator tooling. For webhook mode, ensure no poller remains and verify the new registration.
3. Start exactly one replacement and inspect delivery status. Preserve pending updates; never use `drop_pending_updates=true` casually. Any intentional discard requires owner approval and a documented loss assessment.
4. Test a fresh benign message and check the resulting task. Do not start a second poller as a diagnostic probe.

## 6. Attachment behavior and limits

- Text creates an Inbox task. Supported media are the largest Telegram photo variant, documents, audio, voice, video, video notes, animations, and **static, animated, and video stickers**.
- Media are downloaded as native original file bytes and uploaded to Todoist hosting, then attached to a task comment. Telegram token-bearing download links never become Todoist attachment links. No thumbnail fallback, conversion, or protected-content bypass is provided.
- An individual media message creates a task with one attachment comment. Initial caption supplies the title; otherwise a safe filename/type fallback does. Unicode filenames should survive sanitization without allowing header/path injection.
- Todoist task titles are limited to 500 characters. Longer text retains its full original value in the task description; media captions also remain in the attachment comment. Unsupported non-file messages such as contacts, locations, polls, and paid media are not converted into files. These messages are explicitly rejected, even if captioned, rather than silently dropping their unsupported content.
- An album shares **one task per chat and `media_group_id`**, with one attachment comment per incoming item. A late caption is retained in comments; it need not rewrite the task title. Telegram supplies no perfect album-complete marker, so do not expect a debounce timer or atomic all-or-nothing album completion.
- Todoist previews vary: `.tgs` animated stickers, `.webm` video stickers, and other formats can be downloadable attachments without an inline preview. Missing preview is not proof of corrupt upload; verify downloaded bytes/type.
- Default cap is **5,000,000 bytes** per file for conservative free-plan compatibility. Todoist plan limits can differ; inspect the actual account allowance before increasing it. The bot's absolute ceiling and Telegram cloud `getFile` download ceiling are **20,000,000 bytes**. A higher Todoist plan does not lift Telegram's cloud limit.
- Metadata and streamed download size must both be bounded. Unsupported, oversized, unavailable, or failed uploads receive explicit feedback, not a false “Task added” for a missing attachment. A task may remain after a later upload/comment failure.

Telegram download URLs contain the bot token and are temporary (documented validity at least one hour). Keep them server-side, use the fixed HTTPS Telegram host with validated relative paths and no redirects, and reacquire file information on an authorized retry rather than storing a public link.

## 7. Persistence, retry, and recovery

SQLite stores OAuth users and attachment stage checkpoints on `/data`. The checkpoint identity includes bot identity plus chat/message; an album additionally shares its task key by chat/media group. Processing for the same key must be serialized. Persisted progress distinguishes task creation, upload, and comment creation so a partial failure resumes the missing stage rather than creating another task.

Task and comment creation use stable Todoist Sync **`item_add`/`note_add` command UUIDs** for retry safety, with bounded retries. Do not add an `X-Request-Id` header as an imagined idempotency fix: the latest API/official SDK changelog removed that mechanism. Upload is a separate operation and is not made transactionally atomic with SQLite by a Sync UUID.

**Known crash window:** Todoist can accept a file upload before its result is checkpointed locally. A crash in that interval can leave an orphan upload and a replay can upload the file again. Do not promise exactly-once upload or automatic orphan garbage collection. Similarly, a remote success with an ambiguous response must be reconciled using persisted identifiers/UUIDs rather than blind manual recreation.

Both webhook and polling persist updates before acknowledgement. Polling advances `getUpdates` offsets only after inserting each update; restart replays any unacknowledged updates into the same deduplicated inbox. The worker resumes pending entries after restart. Completed entries retain only their identity and discard the original update payload. Capture rows retain titles and Todoist file URLs; protect the volume accordingly.

After a visible task/upload/comment failure, reply **`/retry` to your ORIGINAL message** in the same bot chat. This resumes the saved task/upload/comment stages without changing the original message identity. Do not reply to the bot's error response. Following 401, reauthorize first and then retry. A 403 can be a plan or scope restriction: verify the plan and, for old `task:add` grants, logout/reauthorize; retry alone cannot fix permission.

If delivery of the bot's own response fails or processing crashes, the inbox backs off (5 seconds per attempt, capped at 60 seconds) without blocking later entries. After ten unsuccessful attempts it retains a dead-letter (`done=true`, `attempts=10`, original payload retained) and emits a content-free error. Inspect pending/dead-letter counters using the operator procedure in [operations.md](operations.md); `/healthz` proves DB/HTTP readiness, not an empty queue. The operator may requeue a reviewed dead-letter by resetting its `done`, `attempts`, and `next_attempt_at` fields in the same database. Do not expose payloads in logs. Telegram response-message delivery itself is at-least-once: a lost acknowledgement can repeat a confirmation, but task/comment Sync UUIDs and logout checkpoints prevent repeating their side effects.

Forwarding/sending the content again creates a new Telegram message and intentionally requests a **new task**; a re-forwarded album may also receive a new group ID. It is not the same as replaying the original update. Explain this before recommending resend, especially when a task already exists.

## 8. Backups and rollback

Treat the database and backups as credentials-bearing private data. Include retention, access restrictions, and a restore drill in operational ownership.

- Prefer a consistent SQLite online backup or a supported volume snapshot with documented consistency. SQLite WAL mode can have `todoist_bot.db-wal` and `todoist_bot.db-shm` beside the main file. Copying only the active `.db` file is not a safe backup.
- If an online backup mechanism is unavailable, stop the single writer, checkpoint/close SQLite cleanly, then copy the database using authorized tooling. Preserve the original volume and any WAL state until consistency has been established. Do not delete WAL files to “repair” a live database.
- Before a release that changes schema, record a known-good code revision and make a verified restorable backup. Test restore in isolation without a production bot token: starting a restored copy with the same token can steal delivery or duplicate work.
- For application rollback, stop the failing consumer first. Determine whether the old code can read the migrated schema. Redeploy a compatible prior revision against the same persistent volume; do not replace or detach the volume by accident.
- If schema rollback requires restoring an earlier backup, get approval for the lost OAuth/checkpoint interval and reconcile remote Todoist tasks/comments created since that backup. Restoring old checkpoints can repeat remote work; stable stored UUIDs help only where they survive the restore.
- Do not run an irreversible migration down or restore an old database merely because a `Release.rollback` function exists. Agree on the exact recovery boundary first.
- Verify `/healthz`, delivery mode, authorization, and a benign task after rollback. Retain the failed revision and sanitized evidence for diagnosis.

## Cost profile

Railway bills RAM and CPU per minute while the container runs; memory is almost the whole bill. Three settings keep it near zero:

- **Serverless sleep** (`sleepApplication`) is on. The container stops after about 10 minutes without outbound traffic. The next webhook or OAuth request wakes it, adding a few seconds of cold start to that first message. Telegram retries a webhook that fails during the wake, and the inbox persists the update before it acknowledges, so nothing is lost. Do not add a keep-alive ping, Discord logging or any other periodic outbound call: it would keep the container awake 24/7.
- **Two schedulers** (`rel/vm.args.eex`). The container sees every host CPU (48), so by default the VM started 48 schedulers plus 48 dirty CPU schedulers, 112 threads in total.
- **Interactive code loading** (`RELEASE_MODE=interactive` in `rel/env.sh.eex`) loads modules on first use instead of preloading about 1,200 at boot.

Together the scheduler and code-loading changes cut resident memory by about 40% in a local Docker measurement (173 MB → 100 MB). `PORT=8080` is pinned on the service so the app, the public domain's target port and the healthcheck agree.

## 9. Acceptance / smoke checklist

Run against the new test bot and an approved Todoist account, then record candidate revision, environment, date, and pass/fail without private contents. These are required checks, **not checks claimed to have run**.

- [ ] Release starts; `/healthz` succeeds; an unavailable database causes health failure rather than a false healthy result.
- [ ] Only Daniel's private-chat messages/callbacks are accepted. Another sender and a group chat cannot create a user, start OAuth, or create tasks; don't temporarily enable multi-user mode to perform this test.
- [ ] `/help`, `/about`, `/logout` confirmation work. Fresh OAuth grants `data:read_write`; wrong/missing/reused state fails safely.
- [ ] Plain text creates one Inbox task; an attachment with a caption uses its caption title; captionless media has a safe fallback.
- [ ] Each supported media type, including all three sticker formats, uploads as original bytes and produces the expected comment. Download and compare an innocuous fixture where possible, rather than trusting preview alone.
- [ ] An album creates one task with one comment per item; a late caption survives in comments. A mixed success/failure album reports failure honestly.
- [ ] A controlled replay of the same original update and a same-key concurrent delivery do not duplicate task/comments. A fresh forward is intentionally treated as new.
- [ ] Over-limit, unsupported, protected/unavailable content, revoked Todoist access, network failure, and API rejection produce visible errors without secret-bearing logs.
- [ ] Restart/redeploy retains OAuth and checkpoints. Controlled interruption between stages resumes safely, with the upload-orphan exception understood.
- [ ] Backup restore and rollback have been exercised in an isolated environment before relying on them for production recovery.

Unit tests and a successful release build do not establish any of these live integration outcomes. Docker/image verification is a separate gate when the daemon is available.

## 10. Troubleshooting

| Symptom | Check / safe response |
| --- | --- |
| Container exits after build | Docker command must start the built release, not run `mix release` and exit. |
| Missing variables despite Railway settings | Inspect runtime config and release environment template; reject scripts that blank injected values. Never print the environment wholesale. |
| Failed healthcheck | Correct HTTP port/routing, `/data` mount and permissions, database access/migrations; do not change the path to a no-op endpoint to hide failure. |
| OAuth redirect error | Compare canonical `APP_HOST` and exact registered `/authorization/finish` URI; restart authorization with a fresh state. |
| Tasks work but attachments fail authorization | Old `task:add` grant; logout and obtain fresh `data:read_write` consent. |
| No updates or Telegram conflict | Inspect for another poller/service or stale webhook; stop the competing consumer rather than spawning another. |
| Telegram webhook errors / growing backlog | Inspect sanitized delivery status, route, secret header, persistent inbox/dead-letter counters, and dependency failures. Preserve backlog; don't drop updates to clear the error. |
| Todoist attachment has no preview | Download the original attachment; native sticker/animation preview support varies. No conversion fallback is promised. |
| File rejected | Compare byte cap, Telegram cloud download limit, Todoist account upload allowance, and actual received bytes. Do not bypass protected content. |
| Partial task after error | Reply `/retry` to your original message; it resumes saved stages. Fix plan/scope/auth restrictions first. Do not blindly resend. |
| State disappears on redeploy | Wrong `DB_PATH`, missing/wrong volume, or replacement environment. Stop and recover persisted state before accepting new work. |

## References

- [Telegram `getFile`: cloud limit and private download URL](https://core.telegram.org/bots/api#getfile)
- [Telegram webhooks and polling API](https://core.telegram.org/bots/api)
- [Todoist API v1: OAuth, uploads, comments, Sync](https://developer.todoist.com/api/v1/)
- [Official Todoist Python SDK changelog](https://github.com/Doist/todoist-api-python/blob/main/CHANGELOG.md)
- [Railway persistent volumes](https://docs.railway.com/guides/volumes)
