#!/usr/bin/env python3
import json, sys, pathlib, os, subprocess

# Read input JSON from file or stdin
if len(sys.argv) > 1 and sys.argv[1] != "-":
    with open(sys.argv[1]) as f:
        data = json.load(f)
else:
    data = json.load(sys.stdin)

# --- Line 1: path, branch, model ---
cwd = data.get("workspace", {}).get("current_dir") or data.get("cwd", "")
model = data.get("model", {}).get("display_name", "")

home = os.environ.get("HOME", "")
short_cwd = cwd.replace(home, "~", 1) if home else cwd

git_branch = ""
try:
    r = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
        capture_output=True, timeout=2
    )
    if r.returncode == 0:
        r2 = subprocess.run(
            ["git", "-C", cwd, "-c", "core.fsmonitor=false", "symbolic-ref", "--short", "HEAD"],
            capture_output=True, text=True, timeout=2
        )
        if r2.returncode == 0:
            git_branch = r2.stdout.strip()
        else:
            r3 = subprocess.run(
                ["git", "-C", cwd, "-c", "core.fsmonitor=false", "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True, timeout=2
            )
            git_branch = r3.stdout.strip()
except Exception:
    pass

line1 = f"\033[34m{short_cwd}\033[0m"
if git_branch:
    line1 += f" \033[33m({git_branch})\033[0m"
if model:
    line1 += f" \033[36m[{model}]\033[0m"

sys.stdout.write(line1)

# --- Line 2: progress bars ---
BLOCKS = " \u258f\u258e\u258d\u258c\u258b\u258a\u2589\u2588"
R = "\033[0m"


def gradient(pct):
    if pct < 50:
        r = int(pct * 5.1)
        return f"\033[38;2;{r};200;80m"
    else:
        g = int(200 - (pct - 50) * 4)
        return f"\033[38;2;255;{max(g, 0)};60m"


def bar(pct, width=10):
    pct = min(max(pct, 0), 100)
    filled = pct * width / 100
    full = int(filled)
    frac = int((filled - full) * 8)
    b = "\u2588" * full
    if full < width:
        b += BLOCKS[frac]
        b += "\u2591" * (width - full - 1)
    return b


def fmt(label, pct):
    p = round(pct)
    return f"{label} {gradient(pct)}{bar(pct)} {p}%{R}"


parts = []
ctx = data.get("context_window", {}).get("used_percentage")
if ctx is not None:
    parts.append(fmt("ctx", ctx))

five = data.get("rate_limits", {}).get("five_hour", {}).get("used_percentage")
if five is not None:
    parts.append(fmt("5h", five))

week = data.get("rate_limits", {}).get("seven_day", {}).get("used_percentage")
if week is not None:
    parts.append(fmt("7d", week))

if parts:
    sys.stdout.write("\n" + "\033[2m\u2502\033[0m".join(f" {p} " for p in parts))

# --- Line 3: tokens, MCP, plugins ---
ctx_win = data.get("context_window", {})
input_tokens = ctx_win.get("total_input_tokens", 0)
output_tokens = ctx_win.get("total_output_tokens", 0)


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
    info_parts.append(f"\033[32mMCP:{','.join(mcp_names)}\033[0m")
if plugin_names:
    info_parts.append(f"\033[34m{','.join(plugin_names)}\033[0m")

sys.stdout.write("\n" + "\033[2m\u2502\033[0m".join(f" {p} " for p in info_parts))
sys.stdout.write("\n")
sys.stdout.flush()
