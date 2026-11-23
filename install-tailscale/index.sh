#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
  printf '\033[2J\033[H'
fi

# Only RoySkill messages go through this function. Commands write directly to the terminal.
message() {
  local width=68 size columns line background='' reset=''
  if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
    if size=$(stty size 2>/dev/null); then
      columns=${size##* }
      if (( columns > 8 && columns < width + 8 )); then width=$((columns - 8)); fi
    fi
    if [[ -z ${NO_COLOR:-} ]]; then
      background=$'\033[97;48;5;24m'
      reset=$'\033[0m'
    fi
  fi

  printf '\n'
  printf '%s\n' "$@" | fmt -s -w "$width" | while IFS= read -r line; do
    printf '  %s %-*s %s\n' "$background" "$width" "$line" "$reset"
  done
  printf '\n'
}

case "${ROYCOMPUTING_IS_HOST:-}" in
  true) kind="host computer" ;;
  false) kind="container" ;;
  *) kind="machine" ;;
esac
target="RoyComputing $kind '$(hostname)'"

message "You are in the $target." "" \
  "Tailscale lets devices on the same private network reach each other." "" \
  "Choosing yes installs Tailscale here if needed and starts it now and after each reboot. You'll sign in through your browser if this $kind needs to join a network. If it's already signed in, it will use its current network." "" \
  "The local user roy will be able to manage Tailscale without sudo."

message "Install and connect Tailscale on this $kind?" \
  'Click Yes or No, or use the arrow keys and press Enter.'
answer=$(printf '%s\n' Yes No | FZF_DEFAULT_OPTS= FZF_DEFAULT_OPTS_FILE= fzf \
  --sync --height=2 --layout=reverse --no-input --bind='left-click:accept') || {
  if (( $? != 130 )); then
    message 'Could not open the confirmation menu. This skill needs fzf in an interactive terminal.' >&2
    exit 1
  fi
  answer=No
}
if [[ $answer != Yes ]]; then
  message 'Cancelled. No changes made.'
  exit 0
fi

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
message 'You can also find this device on your Tailscale Machines page.' \
  'https://login.tailscale.com/admin/machines'
