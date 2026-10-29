# Privileged update sidecar. It needs the Docker CLI + compose, git for tag
# checkout, node for the endpoint, and a shell/tar for the apply path.
FROM docker:27-cli

RUN apk add --no-cache nodejs git bash docker-cli-compose curl

COPY updater.mjs /usr/local/bin/dsh-updater.mjs
WORKDIR /repo
ENTRYPOINT ["node", "/usr/local/bin/dsh-updater.mjs"]
