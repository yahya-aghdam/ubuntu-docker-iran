#!/usr/bin/env bash
# Docker installation for Ubuntu VPS in Iran (DNS, apt mirror, Docker repo fallback, registry mirror)

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
handle_error() { log "${RED}Error: $1${NC}"; exit 1; }

[[ $EUID -eq 0 ]] || handle_error "This script must be run as root (use sudo)"
. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || handle_error "Only Ubuntu is supported"

log "${YELLOW}Starting Docker installation...${NC}"

# ------------------------------------------------
# 1. DNS (Shecan + Cloudflare/Google fallback)
# ------------------------------------------------
log "Configuring DNS..."
if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/iran-dns.conf <<'EOF'
[Resolve]
DNS=178.22.122.100 185.51.200.2 1.1.1.1 8.8.8.8
EOF
    systemctl restart systemd-resolved
else
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<'EOF'
nameserver 178.22.122.100
nameserver 185.51.200.2
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
fi

# ------------------------------------------------
# 2. Ubuntu apt mirror (with backup + rollback)
# ------------------------------------------------
APT_MIRROR="http://mirror.arvancloud.ir/ubuntu"
log "Configuring apt mirror: ${APT_MIRROR}"

BACKUP_DIR="/etc/apt/backup-$(date +%s)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null || true

for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
    [[ -f "$f" ]] && sed -i -E \
        "s#https?://([a-z]{2}\.)?(archive|security)\.ubuntu\.com/ubuntu/?#${APT_MIRROR}/#g" "$f"
done

if ! apt-get update -qq; then
    log "${YELLOW}Mirror failed, restoring original apt sources...${NC}"
    cp -a "$BACKUP_DIR/sources.list" /etc/apt/sources.list 2>/dev/null || true
    cp -a "$BACKUP_DIR/sources.list.d/." /etc/apt/sources.list.d/ 2>/dev/null || true
    apt-get update -qq || handle_error "apt update failed"
fi

# ------------------------------------------------
# 3. Prerequisites
# ------------------------------------------------
log "Installing prerequisites..."
apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    || handle_error "Failed to install prerequisites"

# ------------------------------------------------
# 4. Docker repo (official, fallback to Aliyun mirror)
# ------------------------------------------------
install -m 0755 -d /etc/apt/keyrings
ARCH="$(dpkg --print-architecture)"
DOCKER_BASES=(
    "https://download.docker.com/linux/ubuntu"
    "https://mirrors.aliyun.com/docker-ce/linux/ubuntu"
)

repo_ok=0
for base in "${DOCKER_BASES[@]}"; do
    log "Trying Docker repo: ${base}"
    if curl -fsSL --retry 2 --connect-timeout 10 "${base}/gpg" -o /tmp/docker.gpg \
       && gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg \
       && chmod a+r /etc/apt/keyrings/docker.gpg \
       && echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] ${base} ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list \
       && apt-get update -qq; then
        repo_ok=1
        break
    fi
    log "${YELLOW}Repo failed, trying next...${NC}"
done
rm -f /tmp/docker.gpg
[[ $repo_ok -eq 1 ]] || handle_error "No Docker repository reachable"

log "Installing Docker..."
apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    || handle_error "Docker installation failed"

# ------------------------------------------------
# 5. Registry mirror
# ------------------------------------------------
log "Configuring Docker registry mirror..."
mkdir -p /etc/docker
[[ -f /etc/docker/daemon.json ]] && cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://docker.arvancloud.ir"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

systemctl enable docker >/dev/null 2>&1
systemctl restart docker || handle_error "Docker failed to restart (check /etc/docker/daemon.json)"

# ------------------------------------------------
# 6. Non-root usage
# ------------------------------------------------
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    usermod -aG docker "$SUDO_USER"
    log "User ${SUDO_USER} added to docker group (re-login required)"
fi

# ------------------------------------------------
# 7. Verification
# ------------------------------------------------
if command -v docker >/dev/null && systemctl is-active --quiet docker; then
    log "${GREEN}✅ $(docker --version)${NC}"
    log "Testing hello-world pull..."
    docker run --rm hello-world >/dev/null 2>&1 \
        && log "${GREEN}hello-world OK${NC}" \
        || log "${YELLOW}Warning: hello-world test failed (registry mirror may be down)${NC}"
else
    handle_error "Docker verification failed"
fi

echo
echo -e "${GREEN}Helpful commands:${NC}"
echo "• Run without sudo (after re-login): docker run hello-world"
echo "• Logs: journalctl -u docker -f"