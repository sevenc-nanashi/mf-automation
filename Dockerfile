FROM ruby:3.4

WORKDIR /app

ENV BUNDLE_APP_CONFIG=/app/.bundle

RUN apt-get update \
  && apt-get install -y --no-install-recommends cron tini \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN --mount=type=cache,target=/app/.cache/bundle \
     bundle config set path '.cache/bundle' \
  && bundle install --jobs 4 --retry 3 \
  && mkdir -p /app/vendor/bundle \
  && cp -a .cache/bundle/. /app/vendor/bundle/ \
  && bundle config set --local path 'vendor/bundle'


COPY . .

RUN chmod +x /app/docker-entrypoint.sh \
  && echo 'SHELL=/bin/bash' > /etc/cron.d/mf-automation \
  && echo 'PATH=/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /etc/cron.d/mf-automation \
  && echo '0 0 * * * root /app/run.sh >> /proc/1/fd/1 2>&1' >> /etc/cron.d/mf-automation \
  && chmod 0644 /etc/cron.d/mf-automation

ENTRYPOINT ["/app/docker-entrypoint.sh"]
