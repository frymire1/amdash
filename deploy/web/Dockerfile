# Shared static-file server for all 4 web apps (physician/ems/admin
# Flutter web builds + marketing's Angular build) on Cloud Run,
# replacing Firebase Hosting. One image definition instead of 4 near-
# identical ones — see nginx.conf.template alongside this file for the
# SPA-fallback + caching behavior it replicates from firebase.json's
# per-target `"rewrites": [{"source": "**", "destination": "/index.html"}]`.
#
# Build from the REPO ROOT as context (not this directory), so it can
# reach any app's already-built output — this Dockerfile doesn't build
# the app itself, it only packages an existing `build/web` or
# `dist/browser` directory:
#   docker build -f deploy/web/Dockerfile \
#     --build-arg SRC_DIR=flutter/apps/physician/build/web \
#     -t physician-web .
FROM nginx:1.27-alpine

ARG SRC_DIR
COPY deploy/web/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY ${SRC_DIR} /usr/share/nginx/html

# Cloud Run sets $PORT (default 8080) and requires the container to
# listen on it. nginx:alpine's own docker-entrypoint.d/20-envsubst-on-
# templates.sh already runs envsubst over every file under
# /etc/nginx/templates/*.template into /etc/nginx/conf.d/ before nginx
# starts, substituting ${PORT} below — no custom entrypoint script
# needed. It only substitutes names that are actually set as real
# environment variables (built from `env` at container start), so
# nginx's own runtime variables in the template (`$uri`, `$host`, etc.)
# are left alone — they're not env vars, just similar-looking syntax.
EXPOSE 8080
