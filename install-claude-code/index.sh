#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
  printf '\033[2J\033[H'
fi

# Rich (supplied with Textual) prints static panels without requesting terminal input.
message() {
  /usr/bin/python3 - "$@" <<'PYTHON'
import sys

from rich.console import Console
from rich.padding import Padding
from rich.panel import Panel
from rich.text import Text

body = "\n".join(sys.argv[1:])
console = Console()
if console.is_terminal and not console.is_dumb_terminal:
    panel = Panel(Text(body), title="RoySkill · Claude Code", style="white on #17466a")
    console.print(Padding(panel, (1, 1)))
else:
    print(body)
PYTHON
}

# Feed Python its source on fd 3 so Textual can read keys and clicks from stdin.
confirm() {
  /usr/bin/python3 /dev/fd/3 "$@" 3<<'PYTHON'
import os
import select
import sys
import termios
import time
import tty

from textual.app import App
from textual.containers import Horizontal
from textual.widgets import Button, Static


class Confirmation(App[bool]):
    AUTO_FOCUS = "#yes"
    BINDINGS = [
        ("left", "focus('yes')", "Yes"),
        ("right", "focus('no')", "No"),
        ("escape", "quit", "Cancel"),
        ("ctrl+c", "quit", "Cancel"),
    ]
    CSS = """
    Screen { height: auto; background: transparent; }
    Static { height: auto; padding: 1 2; margin: 0 1; background: #17466a; color: white; }
    Horizontal { dock: bottom; height: 3; margin: 0 1; }
    Button { width: 1fr; min-width: 0; }
    Button:focus { background: #17659a; text-style: bold reverse; }
    """

    def compose(self):
        yield Static("\n".join(sys.argv[1:]), markup=False)
        with Horizontal():
            yield Button("Yes", id="yes")
            yield Button("No", id="no")

    def on_button_pressed(self, event: Button.Pressed):
        self.exit(event.button.id == "yes")


def finish_terminal_input(fd):
    # The terminal processes this status query after Textual's mouse-off sequence.
    # Its reply follows any in-flight input reports on the same SSH stream.
    sys.stderr.write("\x1b[5n")
    sys.stderr.flush()
    deadline = time.monotonic() + 2
    tail = b""
    while not tail.endswith(b"\x1b[0n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            break
        byte = os.read(fd, 1)
        if not byte:
            break
        tail = tail[-3:] + byte


if not (sys.stdin.isatty() and sys.stdout.isatty() and sys.stderr.isatty()):
    sys.exit("Open this skill in an interactive terminal to confirm installation.")

fd = sys.stdin.fileno()
original = termios.tcgetattr(fd)
try:
    # Keep echo off across Textual's shutdown until the terminal has replied.
    tty.setcbreak(fd, termios.TCSANOW)
    app = Confirmation()
    answer = app.run(inline=True, inline_no_clear=True)
    finish_terminal_input(fd)
finally:
    termios.tcsetattr(fd, termios.TCSANOW, original)

if app.return_code:
    sys.exit(app.return_code)
if answer is not True:
    sys.exit(3)
PYTHON
}

case "${ROYCOMPUTING_IS_HOST:-}" in
  true) kind="host computer" ;;
  false) kind="container" ;;
  *) kind="machine" ;;
esac
target="RoyComputing $kind '$(hostname)'"

# The native installer places claude here even if this shell predates the installation.
if ! command -v claude >/dev/null; then
  export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v claude >/dev/null; then
  confirm "Install Claude Code on the $target?" "" \
    "Claude Code is a coding assistant you can talk to in this terminal." \
    "Yes downloads Anthropic's official installer and installs Claude Code for your user. Then we'll help you sign in with your Claude subscription." "" \
    "Click Yes to continue or No to leave. You can also use Left and Right, then Enter." || {
    status=$?
    if (( status != 3 )); then exit "$status"; fi
    message 'Installation cancelled.'
    exit 0
  }

  message 'Installing Claude Code. Keep this terminal open.'
  installer=$(mktemp)
  trap 'rm -f -- "$installer"' EXIT
  if ! curl -fsSL -o "$installer" https://claude.ai/install.sh; then
    message "Couldn't download Claude Code. Check your internet connection and run this skill again." >&2
    exit 1
  fi
  if ! bash "$installer" || ! command -v claude >/dev/null; then
    message "Claude Code didn't finish installing. Check the installer message above, then run this skill again." >&2
    exit 1
  fi
  rm -f -- "$installer"
  trap - EXIT
fi

subscription_signed_in() {
  # Check the CLI's active login without reading credentials or sending a paid prompt.
  claude auth status | /usr/bin/python3 -c '
import json
import sys
from datetime import datetime, timezone

try:
    status = json.load(sys.stdin)
    signed_in = status.get("loggedIn") is True and status.get("authMethod") in ("claude.ai", "oauth_token")
    expires = status.get("loginExpiresAt")
    if signed_in and expires:
        signed_in = datetime.fromisoformat(expires.replace("Z", "+00:00")) > datetime.now(timezone.utc)
except (AttributeError, TypeError, ValueError):
    signed_in = False
sys.exit(0 if signed_in else 1)
'
}

if ! subscription_signed_in; then
  message "Sign in to Claude Code on the $target." "" \
    "1. Open the sign-in link printed below in a browser on your own computer or phone." \
    "2. Use the Claude account that has your subscription and approve the sign-in." \
    "3. If the browser gives you a code, paste it back into this terminal and press Enter."
  if ! claude auth login --claudeai; then
    message "Sign-in didn't finish. You can run this skill again when you're ready." >&2
    exit 1
  fi
  if ! subscription_signed_in; then
    message "Claude Code still doesn't report an active Claude subscription login." \
      "Run 'claude auth status --text' to see which account or sign-in method is active. If it shows an API key or a cloud provider, check that configuration before trying this skill again." >&2
    exit 1
  fi
fi

message "Opening Claude Code on the $target." \
  "When you see its prompt, type a question and press Enter. Type /exit to return to this terminal."
exec claude
