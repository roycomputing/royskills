#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
  printf '\033[2J\033[H'
fi

# Feed Python its source on fd 3 so Textual can read keys and clicks from stdin.
ui() {
  /usr/bin/python3 /dev/fd/3 "$@" 3<<'PYTHON'
import sys

from rich.text import Text
from textual.app import App
from textual.containers import Horizontal
from textual.widgets import Button, Static

confirming = sys.argv[1] == "confirm"
body = "\n".join(sys.argv[2:])


class TailscalePanel(App[bool]):
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
        yield Static(body, markup=False)
        if confirming:
            with Horizontal():
                yield Button("Yes", id="yes")
                yield Button("No", id="no")

    def on_mount(self):
        if not confirming:
            self.call_after_refresh(self.finish_message)

    def finish_message(self):
        # Keep all instructions in scrollback even when the panel exceeds the viewport.
        clipped = self.query_one(Static).outer_size.height > self.screen.content_size.height
        self.exit(message=Text(body) if clipped else None)

    def on_button_pressed(self, event: Button.Pressed):
        self.exit(event.button.id == "yes")


if not (sys.stdin.isatty() and sys.stdout.isatty() and sys.stderr.isatty()):
    if confirming:
        sys.exit("Open this skill in an interactive terminal to confirm installation.")
    print(body)
else:
    app = TailscalePanel()
    answer = app.run(inline=True, inline_no_clear=True, mouse=confirming)
    if app.return_code:
        sys.exit(app.return_code)
    if confirming and answer is not True:
        sys.exit(3)
PYTHON
}

case "${ROYCOMPUTING_IS_HOST:-}" in
  true) kind="host computer" ;;
  false) kind="container" ;;
  *) kind="machine" ;;
esac
target="RoyComputing $kind '$(hostname)'"

ui confirm "Install and connect Tailscale on the $target?" "" \
  "Tailscale lets your devices reach each other on a private network." "" \
  "Yes installs Tailscale here if needed and starts it now and after each reboot. If this $kind needs to join a network, you'll sign in through your browser. If it's already signed in, it will use its current network." "" \
  "The local user roy will be able to manage Tailscale without sudo." "" \
  "Click a button, or use Left and Right then Enter. Escape cancels." || {
  status=$?
  if (( status != 3 )); then exit "$status"; fi
  ui message 'Cancelled. No changes made.'
  exit 0
}

as_root=()
if (( EUID != 0 )); then as_root=(sudo); fi

if command -v tailscale >/dev/null; then
  ui message 'Tailscale is already installed.'
else
  ui message 'Installing Tailscale using its official Linux installer. This may take a minute.'
  installer=$(mktemp)
  trap 'rm -f -- "$installer"' EXIT
  if ! curl -fsSL -o "$installer" https://tailscale.com/install.sh; then
    ui message 'Could not download the installer. Check the internet connection and try again.' >&2
    exit 1
  fi
  if ! sh "$installer"; then
    ui message 'Installation failed. Check the installer message above, then run this skill again.' >&2
    exit 1
  fi
fi

ui message "Starting the Tailscale service on the $target."
if ! "${as_root[@]}" systemctl enable --now tailscaled; then
  if [[ $kind == container && ! -c /dev/net/tun ]]; then
    ui message 'This container is missing /dev/net/tun. Ask the host administrator to enable it for this container.' >&2
  fi
  ui message 'For details about the service, run' 'sudo systemctl status tailscaled' >&2
  exit 1
fi

ui message 'Keep this terminal open. If a sign-in link appears below, open it in your browser. New to Tailscale? You can create an account there.' "" \
  "If you already use Tailscale, choose the same account and network you use on your other devices. Approve this $kind, then return here." "" \
  'If your network asks for administrator approval, ask its admin to approve this device.'
if ! "${as_root[@]}" tailscale up; then
  ui message 'Could not connect to Tailscale. Check the message above, then run this skill again.' >&2
  exit 1
fi

ui message 'Giving roy permission to manage Tailscale on this device.'
if ! "${as_root[@]}" tailscale set --operator=roy; then
  ui message 'Tailscale connected, but setting roy as its operator failed. To retry, run' \
    'sudo tailscale set --operator=roy' >&2
  exit 1
fi

ui message "The $target is connected. The user roy can now manage Tailscale here without sudo." "" \
  'Open Tailscale on your own computer or phone and sign in to the same network.'
if address=$(tailscale ip -1); then
  ui message "The private Tailscale address for this $kind is $address." "" \
    'To test the connection from your own computer, run' "tailscale ping $address"
fi
ui message 'You can also find this device on your Tailscale Machines page.'
printf '%s\n' 'https://login.tailscale.com/admin/machines'
