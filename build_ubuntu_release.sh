#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Export the already-built release without ever starting a Telegram consumer.
docker buildx build --load --platform linux/amd64 -t todoist-bot-builder:latest .
mkdir -p ./_build/ubuntu/rel/todoist_bot
container="$(docker create todoist-bot-builder:latest)"
trap 'docker rm "$container" >/dev/null' EXIT
docker cp "$container:/app/." ./_build/ubuntu/rel/todoist_bot/
printf 'Release exported to _build/ubuntu/rel/todoist_bot\n'
