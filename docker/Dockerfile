FROM node:22-bookworm-slim
ARG APP_VERSION
LABEL org.opencontainers.image.title="CodexShell" \
      org.opencontainers.image.version="${APP_VERSION}"
RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl git gosu iproute2 iptables dnsutils procps && command -v ps >/dev/null && rm -rf /var/lib/apt/lists/*
RUN npm install -g @openai/codex
RUN groupadd -g 10001 codex && useradd -m -u 10001 -g codex -s /bin/bash codex && mkdir -p /workspace && chown codex:codex /workspace
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY codex-session.sh /usr/local/bin/codex-session.sh
COPY firewall.sh /usr/local/bin/firewall.sh
COPY allowed-domains.txt /etc/codexshell/allowed-domains.txt
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/codex-session.sh /usr/local/bin/firewall.sh
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
