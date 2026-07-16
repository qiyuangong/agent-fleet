ARG DIND_BASE_IMAGE=m.daocloud.io/docker.io/library/docker:28-dind
FROM ${DIND_BASE_IMAGE}

ARG ZELLIJ_VERSION=0.44.3

RUN set -eux; \
    apk add --no-cache \
      bash \
      coreutils \
      curl \
      findutils \
      git \
      gzip \
      jq \
      nodejs \
      npm \
      openssl \
      py3-pip \
      python3 \
      shadow \
      tar \
      tmux \
      util-linux \
      xz; \
    if ! apk add --no-cache zellij; then \
      arch="$(uname -m)"; \
      case "$arch" in \
        x86_64|amd64) zellij_arch="x86_64" ;; \
        aarch64|arm64) zellij_arch="aarch64" ;; \
        *) echo "Unsupported zellij architecture: $arch" >&2; exit 1 ;; \
      esac; \
      curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${zellij_arch}-unknown-linux-musl.tar.gz" \
        | tar -xz -C /usr/local/bin zellij; \
      chmod +x /usr/local/bin/zellij; \
    fi; \
    docker --version; \
    docker compose version; \
    python3 -c 'import pyexpat; print("python", __import__("sys").version)'; \
    zellij --version; \
    addgroup -S sii; \
    adduser -S -D -h /home/sii -s /bin/bash -G sii sii; \
    addgroup sii docker
