#!/bin/bash
set -euo pipefail

ENV_EXPORT_PATTERN='^(PASELI_|MONEYFORWARD_|TZ|RUBY|PATH$)'

{
  env -0 | while IFS='=' read -r -d '' name value; do
    if [[ "${name}" =~ ${ENV_EXPORT_PATTERN} ]]; then
      printf '%s=%q\n' "${name}" "${value}"
    fi
  done
} > /app/.env

cat <<-EOF > /app/run.sh
#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091
cd /app
bundle exec ruby src/main.rb
EOF
chmod +x /app/run.sh

if [[ "${1:-}" == "--test" ]]; then
  echo "[docker-entrypoint] Test mode enabled. Running scheduled job immediately..."
  /app/run.sh
else
  echo "[docker-entrypoint] Starting cron daemon..."
  exec tini cron -- -f -L 15
fi
