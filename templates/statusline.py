#!/usr/bin/env python3
# container 専用の claude statusline。
# - line1: [CLAUDE_ENV_NAME] cwd (branch) [model] v.. [⚠200k+]
# - line2: ctx バー (rate_limits は Enterprise で payload に来ないので省略)
# - line3: in:/out:/$cost / MCP / plugins
import json
import os
import pathlib
import subprocess
import sys

if len(sys.argv) > 1 and sys.argv[1] != "-":
    with open(sys.argv[1]) as f:
        data = json.load(f)
else:
    data = json.load(sys.stdin)

env_name = os.environ.get("CLAUDE_ENV_NAME", "")
cwd = data.get("workspace", {}).get("current_dir") or data.get("cwd", "")
model = data.get("model", {}).get("display_name", "")
version = data.get("version", "")
exceeds = data.get("exceeds_200k_tokens", False)

git_branch = ""
try:
    r = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
        capture_output=True, timeout=2,
    )
    if r.returncode == 0:
        r2 = subprocess.run(
            ["git", "-C", cwd, "-c", "core.fsmonitor=false", "symbolic-ref", "--short", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        if r2.returncode == 0:
            git_branch = r2.stdout.strip()
        else:
            r3 = subprocess.run(
                ["git", "-C", cwd, "-c", "core.fsmonitor=false", "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True, timeout=2,
            )
            git_branch = r3.stdout.strip()
except Exception:
    pass

line1_parts = []
if env_name:
    line1_parts.append(f"\033[35;1m[{env_name}]\033[0m")
if cwd:
    line1_parts.append(f"\033[34m{cwd}\033[0m")
if git_branch:
    line1_parts.append(f"\033[33m({git_branch})\033[0m")
if model:
    line1_parts.append(f"\033[36m[{model}]\033[0m")
if version:
    line1_parts.append(f"\033[2mv{version}\033[0m")
if exceeds:
    line1_parts.append("\033[31m⚠200k+\033[0m")

sys.stdout.write(" ".join(line1_parts))

BLOCKS = " ▏▎▍▌▋▊▉█"
R = "\033[0m"


def gradient(pct):
    if pct < 50:
        r = int(pct * 5.1)
        return f"\033[38;2;{r};200;80m"
    g = int(200 - (pct - 50) * 4)
    return f"\033[38;2;255;{max(g, 0)};60m"


def bar(pct, width=10):
    pct = min(max(pct, 0), 100)
    filled = pct * width / 100
    full = int(filled)
    frac = int((filled - full) * 8)
    b = "█" * full
    if full < width:
        b += BLOCKS[frac]
        b += "░" * (width - full - 1)
    return b


def fmt_bar(label, pct):
    return f"{label} {gradient(pct)}{bar(pct)} {round(pct)}%{R}"


parts2 = []
ctx = data.get("context_window", {}).get("used_percentage")
if ctx is not None:
    parts2.append(fmt_bar("ctx", ctx))
if parts2:
    sys.stdout.write("\n" + "\033[2m│\033[0m".join(f" {p} " for p in parts2))

ctx_win = data.get("context_window", {})
input_tokens = ctx_win.get("total_input_tokens", 0)
output_tokens = ctx_win.get("total_output_tokens", 0)
cost_usd = data.get("cost", {}).get("total_cost_usd")


def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


token_parts = [
    f"\033[36min:{fmt_tokens(input_tokens)}\033[0m",
    f"\033[35mout:{fmt_tokens(output_tokens)}\033[0m",
]
if cost_usd is not None:
    token_parts.append(f"\033[33m${cost_usd:.3f}\033[0m")

settings_path = (pathlib.Path.home() / ".claude" / "settings.json").resolve()
mcp_names = []
plugin_names = []
try:
    with open(settings_path) as f:
        settings = json.load(f)
    mcp_names = sorted(settings.get("mcpServers", {}).keys())
    plugin_names = sorted(
        k.split("@")[0]
        for k, v in settings.get("enabledPlugins", {}).items()
        if v
    )
except Exception:
    pass

info_parts = [" ".join(token_parts)]
if mcp_names:
    mcp_list = ",".join(mcp_names)
    info_parts.append(f"\033[32mMCP:{mcp_list}\033[0m")
if plugin_names:
    plugin_list = ",".join(plugin_names)
    info_parts.append(f"\033[34m{plugin_list}\033[0m")

sys.stdout.write("\n" + "\033[2m│\033[0m".join(f" {p} " for p in info_parts))
sys.stdout.write("\n")
sys.stdout.flush()
