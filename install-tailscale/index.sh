#!/usr/bin/env bash
set -euo pipefail

case "${ROYCOMPUTING_IS_HOST:-}" in
  true) kind="host computer" ;;
  false) kind="container" ;;
  *) kind="machine" ;;
esac
machine_name=$(hostname)
target="RoyComputing $kind '$machine_name'"

cat <<EOF
You are in the $target.

Tailscale lets devices on the same private network reach each other.
Choosing yes will install Tailscale here if needed, start it now, and
set it to start after a reboot. If this $kind needs to join a network,
you'll sign in through your browser. If it's already signed in, it
will use its current Tailscale network.
EOF

while true; do
  printf '\nInstall and connect Tailscale on this %s? [yes/no, default no] ' "$kind"
  if ! read -r answer; then answer=no; fi
  case "${answer,,}" in
    yes|y) break ;;
    no|n|'') printf 'Cancelled. No changes made.\n'; exit 0 ;;
    *) printf 'Please type yes or no, then press Enter.\n' ;;
  esac
done

as_root=()
if (( EUID != 0 )); then as_root=(sudo); fi

if command -v tailscale >/dev/null; then
  printf '\nTailscale is already installed.\n'
else
  printf '\nInstalling Tailscale using its official Linux installer. This may take a minute.\n'
  installer=$(mktemp)
  trap 'rm -f -- "$installer"' EXIT
  if ! curl -fsSL -o "$installer" https://tailscale.com/install.sh; then
    printf 'Could not download the installer. Check the internet connection and try again.\n' >&2
    exit 1
  fi
  if ! sh "$installer"; then
    printf 'Installation failed. See the installer message above, then run this skill again.\n' >&2
    exit 1
  fi
fi

printf '\nStarting the Tailscale service on the %s.\n' "$target"
if ! "${as_root[@]}" systemctl enable --now tailscaled; then
  if [[ $kind == container && ! -c /dev/net/tun ]]; then
    printf 'This container is missing /dev/net/tun. Ask the host administrator to enable it for this container.\n' >&2
  fi
  printf 'To see why the service failed, run sudo systemctl status tailscaled\n' >&2
  exit 1
fi

cat <<EOF

Keep this terminal open. If a sign-in link appears below, open it in
your browser. New to Tailscale? You can create an account there.
If you already use Tailscale, choose the same account and network you
use on your other devices. Approve this $kind, then return here.
If your network asks for administrator approval, ask its admin to approve this device.
EOF
if ! "${as_root[@]}" tailscale up; then
  printf 'Could not connect to Tailscale. Check the message above, then run this skill again to retry.\n' >&2
  exit 1
fi

printf '\nThe %s is connected.\n' "$target"
printf 'Open Tailscale on your own computer or phone and sign in to the same network.\n'
if address=$(tailscale ip -1); then
  printf 'The private Tailscale address for %s is %s.\n' "$machine_name" "$address"
  printf 'To test the connection from your own computer, run\n\n  tailscale ping %s\n' "$address"
fi
printf '\nYou can also find this device on your Tailscale Machines page.\nhttps://login.tailscale.com/admin/machines\n'
