# syntax=docker/dockerfile:1
#
# DeepSeek Harness backend: web UI + Telegram adapter in one runtime.
#
# The container is the security boundary. Inside it the harness runs with
# DSH_PERMISSION_MODE=danger-full-access (set in compose), because a nested
# bwrap/Landlock sandbox is unreliable in containers and fails closed.
# Everything the agent can reach is what this image + the /data volume expose.
#
FROM node:24-bookworm-slim

ARG DSH_VERSION=0.2.1-rc.2
ARG DSH_SETUP_VERSION=0.2.1-rc.2-0.1.9
ENV DSH_SETUP_VERSION=${DSH_SETUP_VERSION}
# The connector's /about reports this; the runtime itself does not export it.
ENV DSH_RUNTIME_VERSION=${DSH_VERSION}
ARG DSH_UID=1000
ARG DSH_GID=1000

# Docker mounts /tmp with noexec. The native addon loader copies .node binaries
# into os.tmpdir() and dlopen's them from there, which fails with
# "failed to map segment from shared object" — so keep that cache on the data
# volume, which is a normal (exec-capable) filesystem.
ENV DEBIAN_FRONTEND=noninteractive \
    DSH_HOME=/data/home \
    DSH_WORKSPACE=/data/workspace \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NARB_NATIVE_CACHE_DIR=/data/.cache/native

# ca-certificates: api.telegram.org + npm; git: the adapter is a git dependency;
# tini: PID 1 that reaps the agent's subprocess zoo.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git tini \
 && rm -rf /var/lib/apt/lists/*

# pnpm is not optional: the Telegram adapter builds itself with a `prepare`
# script that shells out to `pnpm install`.
#
# --allow-scripts is not optional either: npm >= 11 skips dependency install
# scripts by default, and dsh needs node-pty's prebuild, koffi's prebuilt
# binding and dsh-subprocess-local's spawn helper. Without them the bash tool
# breaks at runtime, so the allowlist is spelled out.
RUN npm install -g \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      "@deepseek-ai/dsh@${DSH_VERSION}" pnpm@11 \
 && npm cache clean --force

# Unprivileged runtime user. UID/GID must match the owner of ./data on the host,
# otherwise rebuild: DSH_UID=$(id -u) DSH_GID=$(id -g) docker compose build
#
# The node base image already owns 1000:1000 as `node`, so in the common case we
# rename that account instead of adding a conflicting one.
RUN set -eux; \
    if [ "${DSH_UID}" = "1000" ] && [ "${DSH_GID}" = "1000" ]; then \
      groupmod -n dsh node; \
      usermod -l dsh -d /data/home -s /bin/bash node; \
    else \
      groupadd -g "${DSH_GID}" dsh; \
      useradd -u "${DSH_UID}" -g "${DSH_GID}" -d /data/home -M -s /bin/bash dsh; \
    fi

ENV HOME=/data/home

COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
COPY healthcheck.sh /usr/local/bin/dsh-healthcheck
COPY supervisor.mjs /usr/local/bin/dsh-supervisor
COPY git-credentials.mjs /usr/local/bin/dsh-git-credentials.mjs
RUN printf '#!/bin/sh\nexec node /usr/local/bin/dsh-git-credentials.mjs "$@"\n' > /usr/local/bin/dsh-git-credentials \
 && chmod 0755 /usr/local/bin/dsh-entrypoint /usr/local/bin/dsh-healthcheck /usr/local/bin/dsh-supervisor /usr/local/bin/dsh-git-credentials /usr/local/bin/dsh-git-credentials.mjs

RUN mkdir -p /data/home /data/workspace && chown -R "${DSH_UID}:${DSH_GID}" /data

WORKDIR /data/workspace
USER dsh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dsh-entrypoint"]
CMD ["serve"]
