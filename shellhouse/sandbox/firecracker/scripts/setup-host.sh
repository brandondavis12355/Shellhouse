#!/usr/bin/env bash
# One-time host preparation for the Firecracker sandbox provider:
#   - verify KVM
#   - install firecracker + jailer
#   - create the VM bridge and NAT
#   - install nftables rules that BLOCK the things §22/§41 of the architecture
#     doc call out: cloud metadata, host services, and private ranges
#
#   sudo ./setup-host.sh
set -euo pipefail

FC_VERSION="${FC_VERSION:-v1.10.1}"
BRIDGE="${FIRECRACKER_BRIDGE:-fcbr0}"
VM_SUBNET="172.30.0.0/16"
BIN_DIR=/usr/local/bin
JAIL_UID="${FIRECRACKER_UID:-1234}"
JAIL_GID="${FIRECRACKER_GID:-1234}"

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

echo "==> Checking KVM"
if [[ ! -e /dev/kvm ]]; then
  echo "ERROR: /dev/kvm missing. Firecracker needs hardware virtualization."
  echo "  Bare metal: enable VT-x/AMD-V in BIOS."
  echo "  Cloud VM:   you need a nested-virt or metal instance type."
  exit 1
fi
[[ -w /dev/kvm ]] || echo "WARN: /dev/kvm not writable; add your user to the 'kvm' group"

echo "==> Installing firecracker ${FC_VERSION}"
ARCH="$(uname -m)"
if [[ ! -x "$BIN_DIR/firecracker" ]]; then
  TMP="$(mktemp -d)"
  curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz" \
    | tar -xz -C "$TMP"
  install -m 0755 "$TMP/release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" "$BIN_DIR/firecracker"
  install -m 0755 "$TMP/release-${FC_VERSION}-${ARCH}/jailer-${FC_VERSION}-${ARCH}" "$BIN_DIR/jailer"
  rm -rf "$TMP"
fi
"$BIN_DIR/firecracker" --version

echo "==> Creating the jailer user (uid ${JAIL_UID})"
getent group "$JAIL_GID" >/dev/null || groupadd -g "$JAIL_GID" fcjail
getent passwd "$JAIL_UID" >/dev/null || \
  useradd -u "$JAIL_UID" -g "$JAIL_GID" -M -s /usr/sbin/nologin fcjail

echo "==> Creating bridge ${BRIDGE}"
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  ip link add name "$BRIDGE" type bridge
  ip addr add 172.30.255.254/16 dev "$BRIDGE"
  ip link set "$BRIDGE" up
fi

echo "==> Enabling forwarding"
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.all.proxy_arp=1
cat > /etc/sysctl.d/99-agent-vm.conf <<EOF
net.ipv4.ip_forward=1
EOF

echo "==> Installing nftables egress policy"
# This is the actual network security boundary for the VMs. Order matters:
# the drops come BEFORE the accept.
cat > /etc/nftables-agent-vm.conf <<EOF
table inet agentvm {
    chain forward {
        type filter hook forward priority 0; policy accept;

        # --- deny cloud instance metadata (SSRF -> credential theft) -------
        ip daddr 169.254.169.254 drop
        ip daddr 169.254.0.0/16 drop
        ip6 daddr fd00:ec2::254 drop

        # --- deny VM -> VM traffic (tenant isolation) ----------------------
        ip saddr ${VM_SUBNET} ip daddr ${VM_SUBNET} drop

        # --- deny the host's own services and every RFC1918 range ---------
        ip saddr ${VM_SUBNET} ip daddr 127.0.0.0/8 drop
        ip saddr ${VM_SUBNET} ip daddr 10.0.0.0/8 drop
        ip saddr ${VM_SUBNET} ip daddr 172.16.0.0/12 drop
        ip saddr ${VM_SUBNET} ip daddr 192.168.0.0/16 drop

        # Everything else (public internet) is allowed out.
        # To switch to a strict ALLOWLIST instead, replace the policy with
        # 'policy drop' and add explicit accepts per destination.
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip saddr ${VM_SUBNET} oifname != "${BRIDGE}" masquerade
    }

    chain input {
        type filter hook input priority 0; policy accept;
        # VMs may not reach services listening on the host itself, except the
        # /30 gateway addresses they need for routing.
        iifname "fctap*" tcp dport { 22, 8000, 11434, 5432, 6379 } drop
    }
}
EOF

nft -f /etc/nftables-agent-vm.conf
echo "    rules loaded (persist with: systemctl enable nftables)"

echo "==> Creating state directories"
mkdir -p /var/lib/agent-vm/instances /var/run/agent-vm
chown -R "$JAIL_UID:$JAIL_GID" /var/run/agent-vm

cat <<'EOF'

Host is ready. Remaining steps:

  1. sudo ./build-kernel.sh          # -> /var/lib/agent-vm/vmlinux
  2. sudo ./build-rootfs.sh          # -> /var/lib/agent-vm/rootfs.ext4
  3. Set SANDBOX_BACKEND=firecracker in .env (read by sandbox-manager)
  4. Run the manager as a host systemd unit (see docs/SECURITY.md), then:
     docker compose up -d --build

Verify isolation before trusting it:
  - from inside a VM: curl -m 3 http://169.254.169.254/  (must fail)
  - from inside a VM: curl -m 3 http://172.30.0.6:6080/  (another VM: must fail)
  - on the host:      ps aux | grep firecracker           (must run as uid 1234)
EOF
