FROM node:22-bookworm-slim
ARG APP_VERSION
LABEL org.opencontainers.image.title="CodexShell" \
      org.opencontainers.image.version="${APP_VERSION}"
RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl git gosu iproute2 iptables dnsutils procps util-linux && command -v ps >/dev/null && rm -rf /var/lib/apt/lists/*
RUN npm install -g @openai/codex
ARG TARGETARCH
ARG TOOL_DOCKER_CLI=0
ARG TOOL_DOCKER_COMPOSE=0
ARG TOOL_PYTHON=0
ARG TOOL_GO=0
ARG TOOL_RUST=0
ARG TOOL_JAVA=0
ARG TOOL_MAKE=0
ARG TOOL_CMAKE=0
ARG TOOL_BUILD_ESSENTIAL=0
ARG TOOL_GH_CLI=0
ARG TOOL_POSTGRES=0
ARG TOOL_MONGODB=0
ARG TOOL_REDIS=0
ARG TOOL_PNPM=0
ARG TOOL_BUN=0
ARG TOOL_UV=0
ARG TOOL_SSH_CLIENT=0
ARG TOOL_RSYNC=0
ARG TOOL_JQ=0
ARG TOOL_YQ=0
ARG TOOL_WGET=0
COPY install-tools.sh /usr/local/bin/install-tools.sh
RUN bash /usr/local/bin/install-tools.sh
RUN groupadd -g 10001 codex && useradd -m -u 10001 -g codex -s /bin/bash codex && mkdir -p /workspace && chown codex:codex /workspace
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY codex-session.sh /usr/local/bin/codex-session.sh
COPY firewall.sh /usr/local/bin/firewall.sh
COPY allowed-domains.txt /etc/codexshell/allowed-domains.txt
COPY xcode-shims/ /usr/local/lib/codexshell-xcode/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/codex-session.sh /usr/local/bin/firewall.sh /usr/local/lib/codexshell-xcode/xcodebuild /usr/local/lib/codexshell-xcode/xcrun /usr/local/lib/codexshell-xcode/simctl
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
