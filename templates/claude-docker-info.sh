#!/usr/bin/env bash
set -euo pipefail

echo "claude-docker:"
if [ -e /usr/local/share/claude-docker/manifest.json ]; then
  echo "  image_manifest_sha256: $(sha256sum /usr/local/share/claude-docker/manifest.json | awk '{print $1}')"
  jq -r '
    "  compose_name: \(.compose_name // "")",
    "  project: \(.project // "")",
    "  managed_files: \([.files[].path] | join(","))"
  ' /usr/local/share/claude-docker/manifest.json 2>/dev/null || true
else
  echo "  image_manifest: missing"
fi

echo
echo "container:"
echo "  hostname: $(hostname)"
echo "  user: $(id -un)"
echo "  home: ${HOME}"
echo "  DOCKER_HOST: ${DOCKER_HOST:-unset}"
echo "  docker_cli: $(command -v docker 2>/dev/null || printf 'missing')"

echo
echo "claude:"
if [ -e "${HOME}/.claude.json" ]; then
  echo "  global_config: ${HOME}/.claude.json -> $(readlink "${HOME}/.claude.json" 2>/dev/null || printf 'regular-file')"
  echo "  state_dir: ${CLAUDE_STATE_DIR:-${HOME}/.claude-state}"
  jq -r '
    "  machineID: \(.machineID // "")",
    "  userID: \(.userID // "")",
    "  oauth_email: \(.oauthAccount.emailAddress // "")",
    "  firstStartTime: \(.firstStartTime // "")",
    "  migrationVersion: \(.migrationVersion // "")"
  ' "${HOME}/.claude.json" 2>/dev/null || true
else
  echo "  global_config: missing"
fi

if [ -e "${HOME}/.claude/.credentials.json" ]; then
  echo "  credentials: present ($(jq -r 'keys | join(",")' "${HOME}/.claude/.credentials.json" 2>/dev/null || printf 'unreadable'))"
else
  echo "  credentials: missing"
fi

if command -v claude >/dev/null 2>&1; then
  echo
  claude auth status 2>/dev/null | jq -r '
    "auth:",
    "  loggedIn: \(.loggedIn)",
    "  authMethod: \(.authMethod // "")",
    "  email: \(.email // "")",
    "  subscriptionType: \(.subscriptionType // "")"
  ' || true
fi
