#!/bin/sh
# Registers Search's MCP helper with every coding agent found on this Mac:
# Claude Code, Codex and OpenCode. Run it once after putting Search.app in
# /Applications (or ~/Applications):
#
#   curl -fsSL https://github.com/neerajvipparla/Search/releases/latest/download/install-mcp.sh | sh
#
# or, from a checkout, ./install-mcp.sh. SEARCH_APP=/path/to/Search.app
# points it at a Search somewhere else. Running it again replaces the entry.
set -eu

APP="${SEARCH_APP:-}"
if [ -z "$APP" ]; then
  for candidate in /Applications/Search.app "$HOME/Applications/Search.app"; do
    if [ -d "$candidate" ]; then APP="$candidate"; break; fi
  done
fi
HELPER="$APP/Contents/Resources/search-mcp"
if [ -z "$APP" ] || [ ! -x "$HELPER" ]; then
  echo "Search.app not found. Put it in /Applications, or run with SEARCH_APP=/path/to/Search.app" >&2
  exit 1
fi

# The helper is a Python 3 script, started by the agent when it needs a tool.
if ! /usr/bin/env python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
  echo "warning: Python 3.8+ not found. Install it (xcode-select --install, or brew install python) before using the tools." >&2
fi

found=0
if command -v claude >/dev/null 2>&1; then
  claude mcp remove -s user search >/dev/null 2>&1 || true
  claude mcp add -s user search -- "$HELPER" && echo "Claude Code: added 'search'"
  found=1
fi
if command -v codex >/dev/null 2>&1; then
  codex mcp remove search >/dev/null 2>&1 || true
  codex mcp add search -- "$HELPER" && echo "Codex: added 'search'"
  found=1
fi
if command -v opencode >/dev/null 2>&1; then
  # OpenCode has no `mcp remove`: an entry already there is left as it is.
  if opencode mcp add search --global -- "$HELPER" >/dev/null 2>&1; then
    echo "OpenCode: added 'search'"
  else
    echo "OpenCode: 'search' is already set; its command belongs at mcp.search in ~/.config/opencode/opencode.json(c): $HELPER" >&2
  fi
  found=1
fi

if [ "$found" = 0 ]; then
  echo "No Claude Code, Codex or OpenCode found. Register this command with your agent by hand:" >&2
  echo "  $HELPER" >&2
  exit 1
fi
echo "Done. Open Search, then ask your agent to use the 'search' tools. Restart running agent sessions to pick it up."
