#!/bin/bash
set -euo pipefail

ENV_EXPORT_PATTERN='^(PASELI_|MONEYFORWARD_|TZ|RUBY|PATH$)'

{
  env -0 | while IFS='=' read -r -d '' name value; do
    if [[ "${name}" =~ ${ENV_EXPORT_PATTERN} ]]; then
      printf '%s=%q\n' "${name}" "${value}"
    fi
  done
  printf '%s=%q\n' 'BUNDLE_APP_CONFIG' '/usr/local/bundle'
  printf '%s=%q\n' 'BUNDLE_PATH' '/usr/local/bundle'
  printf '%s=%q\n' 'BUNDLE_BIN_PATH' '/usr/local/bundle/bin'
} > /app/.cron_env

if [[ ${1:-} == "--test" ]]; then
  echo "[docker-entrypoint] Test mode enabled. Running scheduled job immediately..."
  (
    set -a
    # shellcheck disable=SC1091
    source /app/.cron_env
    set +a
    cd /app
    bundle exec ruby src/main.rb
  )
else
  echo "[docker-entrypoint] Starting cron daemon..."
  exec cron -f -L 15
fi
