FROM debian:bookworm-slim

ENV PNPM_HOME=/home/user/.local/share/pnpm
ENV MISE_INSTALL_PATH=/home/user/.local/bin/mise
ENV PATH="/home/user/.local/bin:/home/user/.local/share/mise/shims:${PNPM_HOME}/bin:${PATH}"

# ---- 基本ツール + Docker CLI(dindデーモン操作用) + tmux + ssh ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git tmux openssh-client jq python3 bash \
        tar xz-utils unzip \
        build-essential pkg-config libpq-dev postgresql-client \
        fonts-noto-cjk tesseract-ocr tesseract-ocr-jpn tesseract-ocr-jpn-vert \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# ---- 非rootユーザー ----
RUN groupadd --gid 1000 user \
 && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash user

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
RUN mkdir -p /home/user/.claude /home/user/.config/gh /home/user/.ssh \
 && ssh-keyscan github.com >> /home/user/.ssh/known_hosts 2>/dev/null || true \
 && chown -R user:user /home/user/.claude /home/user/.config /home/user/.ssh \
 && chmod 700 /home/user/.ssh

COPY setup-claude-dotfiles.sh /usr/local/bin/setup-claude-dotfiles
COPY claude-docker-info.sh /usr/local/bin/claude-docker-info
COPY scutil /usr/local/bin/scutil
COPY docker /usr/local/bin/docker
COPY .claude-docker.json /usr/local/share/claude-docker/manifest.json
RUN chmod 755 /usr/local/bin/setup-claude-dotfiles /usr/local/bin/claude-docker-info /usr/local/bin/scutil /usr/local/bin/docker \
 && mkdir -p /Users/dai \
 && ln -s /home/user/.claude /Users/dai/.claude \
 && printf '%s\n' \
      'export PNPM_HOME=/home/user/.local/share/pnpm' \
      'export PATH=/home/user/.local/bin:/home/user/.local/share/mise/shims:${PNPM_HOME}/bin:${PATH}' \
      > /etc/profile.d/claude-docker-path.sh

USER user
ENV UV_HTTP_TIMEOUT=120 \
    UV_PYTHON=3.13 \
    PNPM_FETCH_TIMEOUT=120000 \
    PNPM_FETCH_RETRIES=5 \
    PNPM_FETCH_RETRY_MIN_TIMEOUT=10000 \
    PNPM_FETCH_RETRY_MAX_TIMEOUT=60000 \
    NEXT_TELEMETRY_DISABLED=1

# ---- mise + language runtimes ----
# ベースイメージは言語非依存にし、案件で必要なランタイムだけ mise で入れる。
# riku_dx_web は Node/pnpm と Go を使うため、現テンプレートではここで入れる。
RUN curl https://mise.run | sh \
 && mise use -g node@24 go@latest \
 && corepack enable \
 && corepack prepare pnpm@latest --activate \
 && mise reshim node@24 \
 && mkdir -p "${PNPM_HOME}/bin" \
 && pnpm add -g @biomejs/biome

# ---- Claude Code (native installer; background auto-update対応) ----
RUN curl -fsSL https://claude.ai/install.sh | bash

# ---- uv (latest at image build time) ----
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && uv python install 3.13

WORKDIR /workspace
