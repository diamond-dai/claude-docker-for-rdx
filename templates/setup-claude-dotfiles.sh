#!/usr/bin/env bash
set -euo pipefail

# 複数の task(zellij layout 内 dev / claude pane 等)から deps: [up] 経由で
# 同時起動されると、link 系処理が race して dst を dir として見てしまい、
# RO mount の dotfiles 配下に書き込もうとして EROFS で失敗する。
# flock で直列化する(他 instance は終わるまで待つ)。
exec 200>/tmp/setup-claude-dotfiles.lock
flock 200

src_root="${CLAUDE_DOTFILES_DIR:-/dotfiles/claude}"
dst_root="${HOME}/.claude"
state_root="${CLAUDE_STATE_DIR:-${HOME}/.claude-state}"

if [ ! -d "$src_root" ]; then
  echo "claude dotfiles not found: $src_root" >&2
  exit 0
fi

mkdir -p "$dst_root"
mkdir -p "$state_root"

backup_root="${dst_root}/.claude-docker-backup/$(date +%Y%m%d%H%M%S)"

migrate_legacy_paths() {
  local file tmp

  for file in \
    "${dst_root}/plugins/known_marketplaces.json" \
    "${dst_root}/plugins/installed_plugins.json"
  do
    [ -f "$file" ] || continue
    grep -q '/home/node/.claude' "$file" || continue

    mkdir -p "${backup_root}/plugins"
    cp "$file" "${backup_root}/plugins/$(basename "$file")"
    tmp="$(mktemp)"
    sed "s#/home/node/.claude#${dst_root}#g" "$file" > "$tmp"
    mv "$tmp" "$file"
  done
}

persist_global_config() {
  local src="${HOME}/.claude.json"
  local dst="${state_root}/.claude.json"
  local old_dst="${dst_root}/.claude.json"
  local tmp

  if [ -L "$src" ]; then
    rm -f "$src"
  elif [ -e "$src" ] && [ ! -f "$src" ]; then
    # ディレクトリ等の予期せぬ実体は merge できないので消す。
    rm -rf "$src"
  fi

  if [ -e "$old_dst" ] && [ "$old_dst" != "$dst" ]; then
    if [ -e "$dst" ]; then
      tmp="$(mktemp)"
      jq -s '.[0] * .[1] | del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$dst" "$old_dst" > "$tmp"
      install -m 0600 "$tmp" "$dst" && rm -f "$tmp"
      rm -f "$old_dst"
    else
      mv "$old_dst" "$dst"
    fi
  fi

  if [ -e "$src" ] && [ -e "$dst" ]; then
    tmp="$(mktemp)"
    jq -s '.[0] * .[1] | del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$dst" "$src" > "$tmp"
    install -m 0600 "$tmp" "$dst" && rm -f "$tmp"
    rm -f "$src"
  elif [ -e "$src" ]; then
    mv "$src" "$dst"
  elif [ ! -e "$dst" ]; then
    printf '{}\n' > "$dst"
  fi

  tmp="$(mktemp)"
  jq 'del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$dst" > "$tmp"
  install -m 0600 "$tmp" "$dst" && rm -f "$tmp"
  # 既存ファイル(claude が初回起動時に勝手に作る等)があっても上書きする。
  ln -sf "$dst" "$src"
}

link_item() {
  local rel="$1"
  local src="${src_root}/${rel}"
  local dst="${dst_root}/${rel}"

  if [ ! -e "$src" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$dst")"

  if [ -L "$dst" ]; then
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    mkdir -p "$(dirname "${backup_root}/${rel}")"
    mv "$dst" "${backup_root}/${rel}"
  fi

  ln -s "$src" "$dst"
}

write_container_settings() {
  local src="${src_root}/settings.json"
  local dst="${dst_root}/settings.json"
  local tmp

  if [ ! -e "$src" ]; then
    return 0
  fi

  if [ -L "$dst" ]; then
    rm -f "$dst"
  elif [ -e "$dst" ] && [ ! -f "$dst" ]; then
    # ディレクトリ等の予期せぬ実体(過去の失敗 run / Docker volume mount の残骸)
    # は merge できないので消す。
    rm -rf "$dst"
  fi

  tmp="$(mktemp)"
  if [ -f "$dst" ]; then
    jq -s '.[0] * (.[1] | del(.remoteControlAtStartup, .agentPushNotifEnabled))' "$dst" "$src" > "$tmp"
  else
    jq 'del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$src" > "$tmp"
  fi
  install -m 0600 "$tmp" "$dst" && rm -f "$tmp"

  # container 専用 statusline で強制上書き(dotfiles 側のホスト用 statusline は無視)。
  if [ -x /usr/local/bin/claude-statusline ]; then
    tmp="$(mktemp)"
    jq '.statusLine = {type: "command", command: "/usr/local/bin/claude-statusline"}' "$dst" > "$tmp"
    install -m 0600 "$tmp" "$dst" && rm -f "$tmp"
  fi
}

persist_global_config
migrate_legacy_paths
write_container_settings
link_item "hooks"
link_item "skills"
link_item "CLAUDE.md"

# git identity: compose 経由で渡された GIT_USER_NAME / GIT_USER_EMAIL を
# git config --global に焼く。空なら何もしない(他経路で設定済みでも壊さない)。
if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi

# statusline: container 専用 wrapper を実体として配置する。
# 案件リポの .claude/settings.local.json が `bash ~/.claude/statusline-command.sh`
# を呼ぶケースを取り込むため、user settings の statusLine override だけでは不十分。
# dotfiles 側の statusline-command.sh / statusline.py は host 用なので link しない。
if [ -x /usr/local/bin/claude-statusline ]; then
  rm -f "${dst_root}/statusline-command.sh" "${dst_root}/statusline.py"
  cat > "${dst_root}/statusline-command.sh" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/claude-statusline
EOF
  chmod 755 "${dst_root}/statusline-command.sh"
fi

if [ -d "${src_root}/plugins" ]; then
  mkdir -p "${dst_root}/plugins/marketplaces"
  if [ -L "${dst_root}/plugins/marketplaces/custom-lsp" ]; then
    rm -f "${dst_root}/plugins/marketplaces/custom-lsp"
  elif [ -e "${dst_root}/plugins/marketplaces/custom-lsp" ]; then
    mkdir -p "${backup_root}/plugins/marketplaces"
    mv "${dst_root}/plugins/marketplaces/custom-lsp" "${backup_root}/plugins/marketplaces/custom-lsp"
  fi
  ln -s "${src_root}/plugins" "${dst_root}/plugins/marketplaces/custom-lsp"
fi
