#!/bin/bash
set -euo pipefail

ENV_EXPORT_PATTERN='^(PASELI_|MONEYFORWARD_|TZ|BUNDLE_|RUBY|PATH$)'

{
  env -0 | while IFS='=' read -r -d '' name value; do
    if [[ "${name}" =~ ${ENV_EXPORT_PATTERN} ]]; then
      printf '%s=%q\n' "${name}" "${value}"
    fi
  done
} > /app/.cron_env

exec cron -f -L 15
