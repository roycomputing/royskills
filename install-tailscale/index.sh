#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
  printf '\033[2J\033[H'
fi

# Leave each fzf panel in scrollback without waiting for a keypress.
message() {
  local rows columns height color='bg:24,bg+:24,fg:15,fg+:15,border:39,label:15'
  local -a lines
  if [[ ! -t 1 || ${TERM:-dumb} == dumb ]] || ! read -r rows columns < <(stty size </dev/tty) || (( columns < 12 )); then
    printf '%s\n' "$@"
    return
  fi

  mapfile -t lines < <(printf '%s\n' "$@" | fold -s -w "$((columns - 8))")
  height=$((${#lines[@]} + 2))
  if (( height >= rows )); then
    printf '%s\n' "${lines[@]}"
    printf '\n'
    return
  fi
  if [[ -n ${NO_COLOR:-} ]]; then color=bw; fi
  printf '%s\n' "${lines[@]}" | FZF_DEFAULT_OPTS= FZF_DEFAULT_OPTS_FILE= fzf \
    --sync --layout=reverse --no-input --height="$height" --margin=0,1 --border=rounded \
    --border-label=' RoySkill · Tailscale ' --border-label-pos=3 --color="$color" \
    --pointer='' --no-scrollbar --no-clear --bind='load:accept' >/dev/null
  # fzf leaves the cursor at the panel's top edge.
  tput cud "$((height - 1))"
  printf '\n\n'
}

if ! command -v fzf >/dev/null; then
  printf 'This skill needs fzf to display its instructions.\n' >&2
  exit 1
fi

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
# The padding rows belong to each choice, so clicking them also selects it.
answer=$(printf ' \n%s\n \0' Yes No | FZF_DEFAULT_OPTS= FZF_DEFAULT_OPTS_FILE= fzf \
  --read0 --delimiter=$'\n' --accept-nth=2 --sync --height=6 --layout=reverse \
  --no-input --no-scrollbar --highlight-line --bind='left-click:accept,left:up,right:down') || {
  if (( $? != 130 )); then
    printf 'Could not open the confirmation menu. This skill needs fzf in an interactive terminal.\n' >&2
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
message 'You can also find this device on your Tailscale Machines page.'
printf '%s\n' 'https://login.tailscale.com/admin/machines'
