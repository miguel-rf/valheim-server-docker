# Oracle Cloud Deployment Guide (Ampere A1 ARM64)

This guide provides step-by-step instructions for deploying the Valheim Dedicated Server on an **Oracle Cloud Infrastructure (OCI) Ampere A1 (AArch64 / ARM64)** virtual machine running Ubuntu Server.

---

## 1. Initial Instance Architecture Verification

Connect via SSH to your Oracle Cloud instance and verify that the machine architecture is indeed ARM64:

```bash
uname -m
```

**Expected output:**
```text
aarch64
```

If the output is not `aarch64`, you are running on an x86/AMD instance and do not require ARM dynamic binary translation.

---

## 2. Installing Docker and Docker Compose

On Ubuntu Server, install official Docker Engine and the Docker Compose plugin:

```bash
# Update repositories and install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Set up the Docker apt repository for ARM64
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine, CLI, and Compose Plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Allow current user to run Docker without sudo (optional but recommended)
sudo usermod -aG docker $USER
newgrp docker
```

Verify the Docker installation:
```bash
docker info | grep "Architecture"
```
**Expected output:**
```text
Architecture: aarch64
```

---

## 3. Network and Firewall Configuration (OCI and Ubuntu)

Valheim utilizes **UDP** traffic in the port range **2456 to 2458**.
On Oracle Cloud, there are **two independent firewall layers** that must allow this traffic:

### Layer 1: Oracle Cloud Security List / NSG (Web Console)
1. Log in to the Oracle Cloud Console.
2. Navigate to: **Networking > Virtual Cloud Networks > [Your VCN] > Security Lists > Default Security List**.
3. Add an **Ingress Rule**:
   - **Source Type:** CIDR
   - **Source CIDR:** `0.0.0.0/0`
   - **IP Protocol:** `UDP`
   - **Source Port Range:** All
   - **Destination Port Range:** `2456-2458`
   - **Description:** `Valheim Dedicated Server UDP Ports`
4. Save the rule.

### Layer 2: Ubuntu OS Firewall (Host)
By default, Ubuntu images on Oracle Cloud ship with strict `iptables` rules.
Open the required UDP ports on the host:

```bash
# If using UFW:
sudo ufw allow 2456:2458/udp
sudo ufw reload

# If using direct iptables (standard on Ubuntu OCI images):
sudo iptables -I INPUT 6 -m state --state NEW -p udp --dport 2456:2458 -j ACCEPT
sudo netfilter-persistent save || sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

> [!IMPORTANT]
> Never use `network_mode: host` or `--privileged` containers to manipulate host firewalls. Network rules must be explicitly managed on the host OS.

---

## 4. Clone the Fork and Configure Environment

```bash
# Clone the fork into your home directory
git clone https://github.com/miguel-rf/valheim-server-docker-oracle-cloud.git valheim-server
cd valheim-server

# Create directories for persistent volumes
mkdir -p valheim-data/config valheim-data/server

# Create environment configuration file from template
cp .env.example valheim.env
```

Edit `valheim.env` with your preferred editor (`nano valheim.env`):
- Set your `SERVER_NAME`.
- Set a secure password in `SERVER_PASS` (minimum 5 characters; cannot be part of the server name).
- Set `CROSSPLAY=true` if enabling crossplay for consoles (Switch 2, PS4/PS5, Xbox).
- Verify `PUID` and `PGID` match your Ubuntu user (`id -u` and `id -g`, typically `1000` or `1001`).

---

## 5. Build and Deployment

Build the ARM64 container image optimized for the Ampere Altra (Neoverse N1) CPU:

```bash
docker compose -f docker-compose.oracle-arm64.yml build
```

Once build completes, start the server in the background:

```bash
docker compose -f docker-compose.oracle-arm64.yml up -d
```

---

## 6. Monitoring and Diagnostics

### View live logs
```bash
docker compose -f docker-compose.oracle-arm64.yml logs -f
```

You should observe:
1. `valheim-bootstrap`: Directory initialization and permission checks.
2. `valheim-updater`: Initial Valheim download via SteamCMD running under Box86.
3. `valheim-server`: Launch of `valheim_server.x86_64` under Box64 with `STRONGMEM=2`.
4. Message: `Server is now listening on UDP query port 2457` (and PlayFab Join Code registration if `CROSSPLAY=true`).

### Run Architecture Diagnostics
```bash
docker compose -f docker-compose.oracle-arm64.yml exec valheim valheim-arch-diagnostics
```

### Run Smoke Tests
```bash
bash tests/oracle-arm64-smoke-test.sh
```

---

## 7. Graceful Stop and Shutdown

To stop the server while ensuring the world state is safely flushed to disk:

```bash
docker compose -f docker-compose.oracle-arm64.yml stop
```

With `stop_grace_period: 2m`, Docker grants up to 120 seconds for Unity to complete its `.db` and `.fwl` world save routine before issuing a SIGKILL.

---

## 8. Server Updates

The container includes automated periodic update checks (`UPDATE_CRON`).
To trigger an immediate manual update check:

```bash
# Option A: Send SIGHUP to the updater daemon
docker compose -f docker-compose.oracle-arm64.yml exec valheim supervisorctl signal HUP valheim-updater

# Option B: Restart the container
docker compose -f docker-compose.oracle-arm64.yml restart
```
