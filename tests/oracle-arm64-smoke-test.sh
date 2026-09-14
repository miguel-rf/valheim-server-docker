#!/usr/bin/env bash
# ==============================================================================
# Oracle Cloud Ampere A1 (ARM64) Smoke Test for Valheim Server Docker
#
# Verifies end-to-end functionality:
# Host -> Docker -> Image -> Box64 -> Box86 -> SteamCMD -> Valheim Server
# NOTE: This script does NOT modify or delete existing world data.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    pass_count=$((pass_count + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    fail_count=$((fail_count + 1))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

IMAGE_TAG="${1:-valheim-server:arm64}"
CONTAINER_NAME="${2:-valheim-server-arm64}"

echo "============================================================"
echo "    Valheim Server ARM64 Smoke Test - Oracle Ampere A1     "
echo "============================================================"
echo "Testing Image:     $IMAGE_TAG"
echo "Container Name:    $CONTAINER_NAME"
echo

# 1. Host Architecture Check
info "Step 1/12: Checking Host Architecture..."
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "aarch64" || "$HOST_ARCH" == "arm64" ]]; then
    pass "Host architecture is $HOST_ARCH"
else
    fail "Host architecture is $HOST_ARCH (expected aarch64/arm64)"
fi

# 2. Docker Daemon Architecture Check
info "Step 2/12: Checking Docker Daemon Architecture..."
if command -v docker >/dev/null 2>&1; then
    DOCKER_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || echo 'unknown')"
    if [[ "$DOCKER_ARCH" == "aarch64" || "$DOCKER_ARCH" == "arm64" ]]; then
        pass "Docker Daemon architecture is $DOCKER_ARCH"
    else
        fail "Docker Daemon architecture is $DOCKER_ARCH (expected aarch64/arm64)"
    fi
else
    fail "Docker is not installed or not in PATH"
fi

# 3. Image Architecture Check
info "Step 3/12: Checking Container Image Architecture..."
if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    IMG_ARCH="$(docker image inspect --format '{{.Architecture}}' "$IMAGE_TAG")"
    if [[ "$IMG_ARCH" == "arm64" ]]; then
        pass "Container image $IMAGE_TAG is native linux/arm64"
    else
        fail "Container image $IMAGE_TAG is $IMG_ARCH (expected arm64, ensure no QEMU emulation is active)"
    fi
else
    warn "Image $IMAGE_TAG not found locally. Skipping local inspection (build it with docker compose build)."
fi

# 4. Box64 Operational Check
info "Step 4/12: Checking Box64 (x86_64 Dynarec) inside container..."
if docker run --rm --entrypoint /usr/local/bin/box64 "$IMAGE_TAG" -v 2>&1 | grep -iq "box64"; then
    BOX64_VER="$(docker run --rm --entrypoint /usr/local/bin/box64 "$IMAGE_TAG" -v 2>&1 | head -n 1)"
    pass "Box64 is operational: $BOX64_VER"
else
    fail "Box64 binary check failed inside container"
fi

# 5. Box86 Operational Check
info "Step 5/12: Checking Box86 (x86 32-bit Dynarec) inside container..."
if docker run --rm --entrypoint /usr/local/bin/box86 "$IMAGE_TAG" -v 2>&1 | grep -iq "box86"; then
    BOX86_VER="$(docker run --rm --entrypoint /usr/local/bin/box86 "$IMAGE_TAG" -v 2>&1 | head -n 1)"
    pass "Box86 is operational: $BOX86_VER"
else
    fail "Box86 binary check failed inside container"
fi

# 6. SteamCMD Operational Check via Box86
info "Step 6/12: Testing SteamCMD execution through Box86 wrapper..."
if docker run --rm --entrypoint /usr/local/bin/steamcmd-wrapper "$IMAGE_TAG" +login anonymous +quit 2>&1 | grep -iq "waiting for user info"; then
    pass "SteamCMD executed successfully under Box86"
elif docker run --rm --entrypoint /usr/local/bin/steamcmd-wrapper "$IMAGE_TAG" +quit 2>&1 | grep -iq "Steam"; then
    pass "SteamCMD executed and returned Steam prompt"
else
    fail "SteamCMD wrapper execution failed"
fi

# 7. Check SteamCMD App Update Capability (dry/info check)
info "Step 7/12: Testing SteamCMD App 896660 query capability..."
if docker run --rm --entrypoint /usr/local/bin/steamcmd-wrapper "$IMAGE_TAG" +login anonymous +app_info_print 896660 +quit 2>&1 | grep -iq "896660"; then
    pass "SteamCMD can query Valheim Dedicated Server app 896660"
else
    warn "SteamCMD query returned warning (network or rate limit may apply); non-blocking"
fi

# 8. Diagnostics Tool Check
info "Step 8/12: Checking valheim-arch-diagnostics tool..."
if docker run --rm --entrypoint /usr/local/bin/valheim-arch-diagnostics "$IMAGE_TAG" >/dev/null 2>&1; then
    pass "valheim-arch-diagnostics ran successfully"
else
    fail "valheim-arch-diagnostics failed"
fi

# 9. Live Container Status & Service Verification (if container is currently running)
info "Step 9/12: Checking running container instance '$CONTAINER_NAME'..."
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    pass "Container $CONTAINER_NAME is currently running"

    # Check process supervisor
    if docker exec "$CONTAINER_NAME" supervisorctl status >/dev/null 2>&1; then
        pass "supervisord is managing processes"
    else
        warn "supervisord not yet responding to supervisorctl"
    fi

    # 10. UDP Ports check
    info "Step 10/12: Checking UDP query and gameplay ports..."
    if command -v ss >/dev/null 2>&1; then
        if ss -u -l -n | grep -E ':(2456|2457|2458)' >/dev/null 2>&1; then
            pass "Valheim UDP ports (2456-2458) are listening on host"
        else
            warn "UDP ports not yet detected by ss (server may still be starting or downloading)"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -u -l -n | grep -E ':(2456|2457|2458)' >/dev/null 2>&1; then
            pass "Valheim UDP ports (2456-2458) are listening on host"
        else
            warn "UDP ports not yet detected by netstat"
        fi
    fi

    # 11. World Persistence Check (non-destructive)
    info "Step 11/12: Verifying world files structure..."
    if docker exec "$CONTAINER_NAME" test -d /config/worlds_local 2>/dev/null; then
        WORLD_FILES="$(docker exec "$CONTAINER_NAME" ls -1 /config/worlds_local 2>/dev/null | wc -l)"
        pass "World directory /config/worlds_local exists ($WORLD_FILES files present)"
    else
        info "World directory not created yet (initial launch in progress)"
    fi

    # 12. Valheim Executable Architecture Check
    info "Step 12/12: Checking valheim_server.x86_64 binary inside container..."
    if docker exec "$CONTAINER_NAME" test -f /opt/valheim/server/valheim_server.x86_64 2>/dev/null; then
        ELF_TYPE="$(docker exec "$CONTAINER_NAME" file /opt/valheim/server/valheim_server.x86_64 2>/dev/null || echo 'ELF')"
        pass "valheim_server.x86_64 verified: $ELF_TYPE"
    else
        info "Server binary not yet downloaded into /opt/valheim/server (valheim-updater may still be downloading)"
    fi
else
    warn "Container '$CONTAINER_NAME' is not currently running."
    info "To test live execution: docker compose -f docker-compose.oracle-arm64.yml up -d"
fi

echo
echo "============================================================"
echo "                   Smoke Test Summary                       "
echo "============================================================"
echo -e "Passed Checks: ${GREEN}$pass_count${NC}"
echo -e "Failed Checks: ${RED}$fail_count${NC}"

if [ "$fail_count" -eq 0 ]; then
    echo -e "${GREEN}ALL SMOKE TESTS PASSED SUCCESSFULLY ON ORACLE AMPERE ARM64.${NC}"
    exit 0
else
    echo -e "${RED}SOME CHECKS FAILED. Inspect the logs above.${NC}"
    exit 1
fi
