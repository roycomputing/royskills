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
    panel = Panel(Text(body), title="RoySkill · Rex Server", style="white on #17466a")
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
  true) kind="computer" ;;
  false) kind="container" ;;
  *) message 'Open this skill from the Computer or Container dashboard so it can find your SSH address.' >&2; exit 1 ;;
esac

confirm "Install Rex Server on this $kind?" "" \
  "Rex lets you work with remote terminal sessions from your own computer. Yes installs Rex if needed and starts a personal server for your SSH account." "" \
  "When it is ready, we will show you how to connect. Click Yes or No, or use Left and Right, then Enter." || {
  status=$?
  if (( status != 3 )); then exit "$status"; fi
  message 'Installation cancelled.'
  exit 0
}

if ! ip=$(/usr/bin/python3 -c 'import ipaddress, sys; print(ipaddress.IPv4Address(sys.argv[1]))' "${ROYCOMPUTING_IPV4:-}" 2>/dev/null); then
  message 'Could not find the public IPv4 address. Reopen this terminal from the dashboard and try again.' >&2
  exit 1
fi

if [[ $kind == computer ]]; then
  port=2999
else
  if ! port=$(sudo curl -fsS --unix-socket /dev/incus/sock http://localhost/1.0/devices |
    jq -er '.ssh | select(.type == "proxy" and .bind == "host" and .connect == "tcp:127.0.0.1:22")
      | .listen | capture("^tcp:0[.]0[.]0[.]0:(?<port>[0-9]{1,5})$").port | tonumber
      | select(. >= 1 and . <= 65535 and . != 2999)'); then
    message "Could not find this container's forwarded SSH port. Check that its SSH proxy is available and run this skill again." >&2
    exit 1
  fi
fi

if ! command -v rex >/dev/null; then
  message "Installing Rex from Superlogical's Linux package repository. This can take a minute."
  installer=$(mktemp)
  trap 'rm -f -- "$installer"' EXIT
  if ! curl -fsSL -o "$installer" https://pkgs.superlogical.com/rex/install.sh || ! sh "$installer"; then
    message 'Rex installation failed. Check the installer message above and run this skill again.' >&2
    exit 1
  fi
fi

# Keep the personal server under the SSH account. The package installer handles sudo itself.
if systemctl --user show-environment >/dev/null 2>&1; then
  message 'Setting up your personal Rex server to start at boot.'
  if ! rex server install; then
    message 'Rex could not set up your personal service. Check the message above and try again.' >&2
    exit 1
  fi
else
  message 'Starting your personal Rex server. Without a systemd user service, rerun this skill after a reboot or reconnect with Rex to start it again.'
  if ! rex server start; then
    message 'Rex could not start. Check the message above and try again.' >&2
    exit 1
  fi
fi

if ! rex --autostart=false server status >/dev/null; then
  message 'The Rex server did not answer its status check. Run "rex server status" in this terminal for details.' >&2
  exit 1
fi

ssh_user=$(id -un)
address="ssh://$ssh_user@$ip:$port"
message "Rex Server is ready on this $kind." \
  "Use a computer whose SSH key you have added to this $kind. In Rex for Mac, choose Add Remote Host… and paste this address:"
printf '%s\n' "$address"
message 'To connect from your own terminal with the Rex CLI, run:'
printf 'rex -S %s ls\n' "$address"
message 'To connect with SSH directly, run:'
printf 'ssh -p %s %s@%s\n' "$port" "$ssh_user" "$ip"
