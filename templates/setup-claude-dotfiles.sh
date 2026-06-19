#!/usr/bin/env bash
set -euo pipefail

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
  fi

  if [ -e "$old_dst" ] && [ "$old_dst" != "$dst" ]; then
    if [ -e "$dst" ]; then
      tmp="$(mktemp)"
      jq -s '.[0] * .[1] | del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$dst" "$old_dst" > "$tmp"
      mv "$tmp" "$dst"
      rm -f "$old_dst"
    else
      mv "$old_dst" "$dst"
    fi
  fi

  if [ -e "$src" ] && [ -e "$dst" ]; then
    tmp="$(mktemp)"
    jq -s '.[0] * .[1] | del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$dst" "$src" > "$tmp"
    mv "$tmp" "$dst"
    rm -f "$src"
  elif [ -e "$src" ]; then
    mv "$src" "$dst"
  elif [ ! -e "$dst" ]; then
    printf '{}\n' > "$dst"
  fi

  tmp="$(mktemp)"
  jq 'del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$dst" > "$tmp"
  mv "$tmp" "$dst"
  ln -s "$dst" "$src"
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
  fi

  tmp="$(mktemp)"
  if [ -e "$dst" ]; then
    jq -s '.[0] * (.[1] | del(.remoteControlAtStartup, .agentPushNotifEnabled))' "$dst" "$src" > "$tmp"
  else
    jq 'del(.remoteControlAtStartup, .agentPushNotifEnabled)' "$src" > "$tmp"
  fi
  mv "$tmp" "$dst"
}

persist_global_config
migrate_legacy_paths
write_container_settings
link_item "hooks"
link_item "statusline-command.sh"
link_item "statusline.py"
link_item "skills"
link_item "CLAUDE.md"

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
