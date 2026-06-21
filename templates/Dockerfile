FROM debian:bookworm-slim

ENV PNPM_HOME=/home/user/.local/share/pnpm
ENV MISE_INSTALL_PATH=/home/user/.local/bin/mise
ENV PATH="/home/user/.local/bin:/home/user/.local/share/mise/shims:${PNPM_HOME}:${PATH}"

# ---- 基本ツール + Docker CLI(dindデーモン操作用) + tmux + ssh ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git tmux openssh-client autossh procps jq python3 bash \
        tar xz-utils unzip \
        build-essential pkg-config libpq-dev postgresql-client \
        fonts-noto-cjk fonts-liberation tesseract-ocr tesseract-ocr-jpn tesseract-ocr-jpn-vert \
        ripgrep fd-find bat \
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
        libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
        libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 \
        libatspi2.0-0 libxshmfence1 \
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

# ---- rust 系 CLI の補助: 別名 symlink + eza(apt 未提供なので release から DL) ----
# fd-find は Debian 都合で binary 名が fdfind、bat は batcat なので
# claude/人間が打つ素の名前で叩けるよう symlink を /usr/local/bin に置く。
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && ARCH=$(dpkg --print-architecture) \
 && case "$ARCH" in \
        amd64) EZA_TARGET=x86_64-unknown-linux-gnu ;; \
        arm64) EZA_TARGET=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/eza.tar.gz \
        "https://github.com/eza-community/eza/releases/latest/download/eza_${EZA_TARGET}.tar.gz" \
 && tar -xzf /tmp/eza.tar.gz -C /usr/local/bin \
 && chmod 0755 /usr/local/bin/eza \
 && rm /tmp/eza.tar.gz

# ---- GitHub CLI (gh) ----
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# ---- 認証情報ディレクトリ + known_hosts + ssh エイリアス ----
# ※ private な git サーバを使う場合は github.com を案件のホストに差し替える。
# host の ~/.ssh/config にある github-gg 等のエイリアスはコンテナに無いので、
# ここで github.com へ解決する最小 config を焼き込む。鍵は SSH_AUTH_SOCK で
# 転送された host の ssh-agent を使う(IdentityFile は指定しない)。
RUN mkdir -p /home/user/.claude /home/user/.config/gh /home/user/.ssh \
 && ssh-keyscan github.com >> /home/user/.ssh/known_hosts 2>/dev/null || true \
 && printf '%s\n' \
      '# host の ssh config エイリアスをコンテナ内でも解決する。' \
      '# 鍵は転送された ssh-agent を使うため IdentityFile は指定しない。' \
      'Host github-gg github' \
      '  HostName github.com' \
      '  User git' \
      '' \
      '# GPU リモート(riku-dx-spare-gpu)。鍵は転送された ssh-agent を使う。' \
      '# 利用前にホストで:  ssh-add ~/ssh_keys/gg/riku-dx-spare-gpu/av_araidaisuke/riku-dx-spare-gpu_av_araidaisuke_ed25519' \
      'Host riku-dx-spare-gpu-user' \
      '  HostName 211.14.11.141' \
      '  Port 3331' \
      '  User av_araidaisuke' \
      '  StrictHostKeyChecking accept-new' \
    > /home/user/.ssh/config \
 && chmod 600 /home/user/.ssh/config \
 && chown -R user:user /home/user/.claude /home/user/.config /home/user/.ssh \
 && chmod 700 /home/user/.ssh

COPY setup-claude-dotfiles.sh /usr/local/bin/setup-claude-dotfiles
COPY claude-docker-info.sh /usr/local/bin/claude-docker-info
COPY scutil /usr/local/bin/scutil
COPY docker /usr/local/bin/docker
COPY statusline.py /usr/local/bin/claude-statusline
COPY .claude-docker.json /usr/local/share/claude-docker/manifest.json
RUN chmod 755 /usr/local/bin/setup-claude-dotfiles /usr/local/bin/claude-docker-info /usr/local/bin/scutil /usr/local/bin/docker /usr/local/bin/claude-statusline \
 && mkdir -p /Users/dai \
 && ln -s /home/user/.claude /Users/dai/.claude \
 && printf '%s\n' \
      'export PNPM_HOME=/home/user/.local/share/pnpm' \
      'export PATH=/home/user/.local/bin:/home/user/.local/share/mise/shims:${PNPM_HOME}:${PATH}' \
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
 && curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=9.15.0 SHELL="$(command -v bash)" sh - \
 && pnpm add -g @biomejs/biome

# ---- Playwright Chromium (headless 起動できる状態で焼き込む) ----
# system lib(libnss3/libnspr4 等)は上の apt ブロックで導入済み。ここでは
# browser binary 本体だけを image に落とす。案件側の playwright が異なる
# バージョンを要求した場合は初回起動時に追加 DL される。
ENV PLAYWRIGHT_BROWSERS_PATH=/home/user/.cache/ms-playwright
RUN mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" \
 && pnpm dlx playwright@latest install chromium

# ---- Claude Code (native installer; background auto-update対応) ----
RUN curl -fsSL https://claude.ai/install.sh | bash

# ---- uv (latest at image build time) ----
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && uv python install 3.13

WORKDIR /workspace
