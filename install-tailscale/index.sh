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
    panel = Panel(Text(body), title="RoySkill · Tailscale", style="white on #17466a")
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

confirm "Install and connect Tailscale on the $target?" "" \
  "Tailscale lets your devices reach each other on a private network." "" \
  "Yes installs Tailscale here if needed and starts it now and after each reboot. If this $kind needs to join a network, you'll sign in through your browser. If it's already signed in, it will use its current network." "" \
  "The local user roy will be able to manage Tailscale without sudo." "" \
  "Click a button, or use Left and Right then Enter. Escape cancels." || {
  status=$?
  if (( status != 3 )); then exit "$status"; fi
  message 'Cancelled. No changes made.'
  exit 0
}

as_root=()
if (( EUID != 0 )); then as_root=(sudo); fi

if command -v tailscale >/dev/null; then
  message 'Tailscale is already installed.'
else
  message 'Installing Tailscale using its official Linux installer. This may take a minute.'
  installer=$(mktemp)
  trap 'rm -f -- "$installer"' EXIT
  if ! curl -fsSL -o "$installer" https://tailscale.com/install.sh; then
    message 'Could not download the installer. Check the internet connection and try again.' >&2
    exit 1
  fi
  if ! sh "$installer"; then
    message 'Installation failed. Check the installer message above, then run this skill again.' >&2
    exit 1
  fi
fi

message "Starting the Tailscale service on the $target."
if ! "${as_root[@]}" systemctl enable --now tailscaled; then
  if [[ $kind == container && ! -c /dev/net/tun ]]; then
    message 'This container is missing /dev/net/tun. Ask the host administrator to enable it for this container.' >&2
  fi
  message 'For details about the service, run' 'sudo systemctl status tailscaled' >&2
  exit 1
fi

message 'Keep this terminal open. If a sign-in link appears below, open it in your browser. New to Tailscale? You can create an account there.' "" \
  "If you already use Tailscale, choose the same account and network you use on your other devices. Approve this $kind, then return here." "" \
  'If your network asks for administrator approval, ask its admin to approve this device.'
if ! "${as_root[@]}" tailscale up; then
  message 'Could not connect to Tailscale. Check the message above, then run this skill again.' >&2
  exit 1
fi

message 'Giving roy permission to manage Tailscale on this device.'
if ! "${as_root[@]}" tailscale set --operator=roy; then
  message 'Tailscale connected, but setting roy as its operator failed. To retry, run' \
    'sudo tailscale set --operator=roy' >&2
  exit 1
fi

message "The $target is connected. The user roy can now manage Tailscale here without sudo." "" \
  'Open Tailscale on your own computer or phone and sign in to the same network.'
if address=$(tailscale ip -1); then
  message "The private Tailscale address for this $kind is $address." "" \
    'To test the connection from your own computer, run' "tailscale ping $address"
fi
message 'You can also find this device on your Tailscale Machines page.'
printf '%s\n' 'https://login.tailscale.com/admin/machines'
