#!/usr/bin/env bash
# Host preparation for the Firecracker sandbox backend. Idempotent; run it again after an update.
#   - checks KVM and installs the packages the backend and the kernel build need
#   - installs firecracker + jailer (pinned release, checked against its SHA-256)
#   - creates the unprivileged user the VMs run as, the state directories and the manager's SSH key
#   - installs the VM network policy (nftables) as a systemd unit, so it is back after every reboot
#
#   sudo ./setup-host.sh                  # set up
#   sudo ./setup-host.sh --print-packages # just list the packages that are missing (host-setup.sh installs them)
#   sudo ./setup-host.sh --remove         # undo everything above except packages; VM disks are deleted
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

FC_VERSION="v1.10.1"
# From the release's firecracker-v1.10.1-<arch>.tgz.sha256.txt (github.com/firecracker-microvm/firecracker).
declare -A FC_SHA256=(
  [x86_64]=36112969952b0e34fadcfca769d48a55dc22cbba99af17e02bd0e24fc35adc77
  [aarch64]=9e3641071de140979afaac0c52fdc107baeba398bdb5709c12f77ee469207fcd
)
BIN_DIR=/usr/local/bin
LIB_DIR=/usr/local/lib/shellhouse-firecracker
VM_HOME=/var/lib/agent-vm
JAIL_USER=shellhouse-fc
NET_UNIT=/etc/systemd/system/shellhouse-vm-net.service
DOCKER_DROPIN=/etc/systemd/system/docker.service.d/50-shellhouse-vm-net.conf
SYSCTL_FILE=/etc/sysctl.d/99-shellhouse-vm.conf
ARCH="$(uname -m)"
MODE="${1:-setup}"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

if command -v apt-get >/dev/null; then
  PM=apt
  PACKAGES=(curl tar e2fsprogs openssh-client nftables iproute2 procps python3 python3-venv
            build-essential flex bison bc libelf-dev libssl-dev xz-utils)
  installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
elif command -v dnf >/dev/null; then
  PM=dnf
  PACKAGES=(curl tar e2fsprogs openssh-clients nftables iproute procps-ng python3
            gcc make flex bison bc elfutils-libelf-devel openssl-devel perl xz)
  installed() { rpm -q "$1" >/dev/null 2>&1; }
else
  echo "Only apt (Debian/Ubuntu) and dnf (Fedora/RHEL) hosts are supported." >&2; exit 1
fi
missing_packages() { for p in "${PACKAGES[@]}"; do installed "$p" || echo "$p"; done; }

if [[ "$MODE" == "--print-packages" ]]; then
  missing_packages
  exit 0
fi

if [[ "$MODE" == "--remove" ]]; then
  echo "==> Removing the Firecracker host setup"
  systemctl disable --now shellhouse-vm-net.service >/dev/null 2>&1 || true
  rm -f "$NET_UNIT" "$DOCKER_DROPIN"
  rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true
  systemctl daemon-reload
  pkill -KILL -u "$JAIL_USER" -x firecracker 2>/dev/null || true
  for t in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep '^fctap' || true); do ip link del "$t" || true; done
  [[ -x "$LIB_DIR/vm-net.sh" ]] && "$LIB_DIR/vm-net.sh" down || true
  rm -f "$SYSCTL_FILE"     # forwarding itself stays on: Docker needs it too
  rm -rf "$VM_HOME" /var/log/agent-vm "$LIB_DIR"
  rm -f "$BIN_DIR/firecracker" "$BIN_DIR/jailer"
  id "$JAIL_USER" >/dev/null 2>&1 && userdel "$JAIL_USER" 2>/dev/null || true
  getent group "$JAIL_USER" >/dev/null && groupdel "$JAIL_USER" 2>/dev/null || true
  echo "    done"
  exit 0
fi

echo "==> Checking KVM"
if [[ ! -c /dev/kvm ]]; then
  echo "ERROR: /dev/kvm is missing. Firecracker needs hardware virtualization:" >&2
  echo "  bare metal: enable VT-x/AMD-V in the firmware; cloud: a metal or nested-virtualization instance type." >&2
  exit 1
fi
[[ -n "${FC_SHA256[$ARCH]:-}" ]] || { echo "Firecracker has no $ARCH build." >&2; exit 1; }

need=($(missing_packages))
if [[ ${#need[@]} -gt 0 ]]; then
  echo "==> Installing ${need[*]}"
  if [[ "$PM" == apt ]]; then
    apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" >/dev/null
  else
    dnf install -y -q "${need[@]}" >/dev/null
  fi
fi

echo "==> Installing firecracker ${FC_VERSION}"
if [[ "$("$BIN_DIR/firecracker" --version 2>/dev/null | head -1)" != "Firecracker ${FC_VERSION}" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  TGZ="firecracker-${FC_VERSION}-${ARCH}.tgz"
  curl -fsSL -o "$TMP/$TGZ" "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/${TGZ}"
  echo "${FC_SHA256[$ARCH]}  $TMP/$TGZ" | sha256sum -c --quiet - \
    || { echo "The firecracker download doesn't match its pinned checksum; nothing was installed." >&2; exit 1; }
  tar -xzf "$TMP/$TGZ" -C "$TMP"
  install -m 0755 "$TMP/release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" "$BIN_DIR/firecracker"
  install -m 0755 "$TMP/release-${FC_VERSION}-${ARCH}/jailer-${FC_VERSION}-${ARCH}" "$BIN_DIR/jailer"
fi
echo "    $("$BIN_DIR/firecracker" --version | head -1)"

echo "==> Creating the user the VMs run as (${JAIL_USER})"
id "$JAIL_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$JAIL_USER"
echo "    uid $(id -u "$JAIL_USER")"

echo "==> Creating ${VM_HOME}"
install -d -m 0700 "$VM_HOME" "$VM_HOME/instances" "$VM_HOME/jail" "$VM_HOME/run"
install -d -m 0750 /var/log/agent-vm
[[ -f "$VM_HOME/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N "" -f "$VM_HOME/id_ed25519" -C "shellhouse-sandbox-manager"

echo "==> Installing the VM network policy"
install -d -m 0755 "$LIB_DIR"
# Each VM has its own routed tap (fctapN, a /30 out of 172.30.0.0/16); there is no shared bridge, so a VM can only
# reach anything through the host's forward chain, where this policy applies. Loaded as one table, replaced whole
# on every load; nothing else in the host's ruleset is touched (no `flush ruleset`).
cat > "$LIB_DIR/agent-vm.nft" <<'NFT'
table inet agentvm
delete table inet agentvm
table inet agentvm {
    chain forward {
        type filter hook forward priority -10; policy accept;

        # VMs may reach the public internet only: not cloud metadata (169.254.0.0/16), not the LAN, not other
        # VMs or Docker networks (both inside 172.16.0.0/12), not loopback, CGNAT, multicast or reserved space.
        # For an allowlist instead, drop everything from fctap* here and accept chosen destinations above it.
        iifname "fctap*" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                                    172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } drop
        iifname "fctap*" meta nfproto ipv6 drop
        # Nothing on the network may open a connection INTO a VM. (The host itself reaches VMs directly; that
        # traffic isn't forwarded.)
        oifname "fctap*" ct state { established, related } accept
        oifname "fctap*" drop
    }

    chain input {
        type filter hook input priority -10; policy accept;
        # VMs may not open connections to the host itself, on any of its addresses.
        iifname "fctap*" ct state { established, related } accept
        iifname "fctap*" drop
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 172.30.0.0/16 oifname != "fctap*" masquerade
    }
}
NFT
cat > "$LIB_DIR/vm-net.sh" <<'SH'
#!/bin/sh
# up | down | docker-user  (shellhouse-vm-net.service, and Docker's own unit after it restarts)
set -u
LIB=/usr/local/lib/shellhouse-firecracker
# Docker's FORWARD chain drops what it doesn't know; DOCKER-USER is where it lets you add exceptions.
docker_user() {
  command -v iptables >/dev/null 2>&1 && iptables -n -L DOCKER-USER >/dev/null 2>&1 || return 0
  for rule in "-i fctap+ -j ACCEPT" "-o fctap+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"; do
    # shellcheck disable=SC2086
    iptables -C DOCKER-USER $rule 2>/dev/null || iptables -I DOCKER-USER $rule
  done
}
case "${1:-}" in
  up)
    sysctl -qw net.ipv4.ip_forward=1
    nft -f "$LIB/agent-vm.nft" || exit 1
    docker_user ;;
  docker-user)
    docker_user ;;
  down)
    nft delete table inet agentvm 2>/dev/null
    if command -v iptables >/dev/null 2>&1 && iptables -n -L DOCKER-USER >/dev/null 2>&1; then
      while iptables -D DOCKER-USER -i fctap+ -j ACCEPT 2>/dev/null; do :; done
      while iptables -D DOCKER-USER -o fctap+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    fi ;;
  *) echo "usage: $0 up|down|docker-user" >&2; exit 2 ;;
esac
exit 0
SH
chmod 0755 "$LIB_DIR/vm-net.sh"
echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
cat > "$NET_UNIT" <<UNIT
[Unit]
Description=Shellhouse microVM network policy (nftables table inet agentvm)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB_DIR/vm-net.sh up
ExecStop=$LIB_DIR/vm-net.sh down

[Install]
WantedBy=multi-user.target
UNIT
if systemctl cat docker.service >/dev/null 2>&1; then
  install -d -m 0755 "$(dirname "$DOCKER_DROPIN")"
  printf '[Service]\nExecStartPost=-%s/vm-net.sh docker-user\n' "$LIB_DIR" > "$DOCKER_DROPIN"
fi
systemctl daemon-reload
systemctl enable shellhouse-vm-net.service >/dev/null 2>&1
systemctl restart shellhouse-vm-net.service
echo "    loaded; reapplied on every boot by shellhouse-vm-net.service"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "    NOTE: ufw is active. If its forward policy is DROP, VMs have no internet until you allow it, e.g.:" >&2
  echo "          sudo ufw route allow in on fctap+    (check with: ufw status verbose)" >&2
fi

cat <<EOF

Host is ready. Next:
  ./build-kernel.sh             # -> $VM_HOME/vmlinux
  sudo ./build-rootfs.sh        # -> $VM_HOME/rootfs.ext4
  sudo ./install-manager.sh --user <ssh user>
(scripts/host-setup.sh --with-firecracker does all of it.)
EOF
