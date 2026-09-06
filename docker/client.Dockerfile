FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install the xray binary directly (unzip release asset) instead of via
# install-release.sh, which refuses to run on a container with no systemd.
RUN apt-get update && \
    apt-get install -y curl ca-certificates jq iproute2 netcat-openbsd python3 unzip && \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) XRAY_ARCH="64" ;; \
      arm64) XRAY_ARCH="arm64-v8a" ;; \
      *) echo "unsupported arch $ARCH" && exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" && \
    unzip -o /tmp/xray.zip -d /usr/local/bin xray && \
    chmod +x /usr/local/bin/xray && \
    rm -f /tmp/xray.zip && \
    rm -rf /var/lib/apt/lists/*

CMD ["sleep", "infinity"]
