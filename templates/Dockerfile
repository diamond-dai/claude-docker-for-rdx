FROM node:22

# ---- 基本ツール + Docker CLI(dindデーモン操作用) + tmux + ssh ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git tmux openssh-client \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# ---- GitHub CLI (gh) ----
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# ---- 認証情報ディレクトリ + known_hosts ----
# ※ private な git サーバを使う場合は github.com を案件のホストに差し替える。
RUN mkdir -p /home/node/.claude /home/node/.config/gh /home/node/.ssh \
 && ssh-keyscan github.com >> /home/node/.ssh/known_hosts 2>/dev/null || true \
 && chown -R node:node /home/node/.claude /home/node/.config /home/node/.ssh \
 && chmod 700 /home/node/.ssh

USER node
ENV PATH="/home/node/.local/bin:${PATH}"

# ---- Claude Code (native installer; background auto-update対応) ----
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /workspace
