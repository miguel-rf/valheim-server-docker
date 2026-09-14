# ARM64 Fork Changelog (CHANGELOG-ARM64)

This document tracks all additions and modifications made relative to the upstream repository `community-valheim-tools/valheim-server-docker`.

---

## Fork Design Principles
The core goal is to **minimize changes to upstream code**, encapsulating architecture compatibility inside external wrappers and Dockerfile multi-stage instructions. This ensures full compatibility and makes future rebasing against upstream (`git rebase upstream/main`) seamless and low-maintenance.

---

## Summary of Modified vs. New Files

### Modified Upstream Files

| File | Reason for Modification |
| :--- | :--- |
| `Dockerfile` | 1. Go 1.24 parameterization via `ARG TARGETARCH` (`linux-amd64` / `linux-arm64`).<br>2. BusyBox Kconfig adjustment to avoid forcing `CONFIG_STACK_OPTIMIZATION_386` on ARM64.<br>3. Multi-stage builder targets `box64-builder` and `box86-builder` compiling from source with Dynarec.<br>4. Multiarch `armhf` inclusion and Debian Trixie runtime libraries.<br>5. Copying of wrappers (`steamcmd-wrapper`, `valheim-wrapper`, `valheim-arch-diagnostics`) and `box64.box64rc` configuration.<br>6. SteamCMD execution during container build mediated through `steamcmd-wrapper`.<br>7. Patched Box64 build via `scripts/patch-box64.sh` for complete `libogg` API wrapper support. |
| `common` | Definition of wrapper command variables: `cmd_valheim_wrapper` and `cmd_steamcmd_wrapper`. |
| `defaults` | Added default variables for Box64 on ARM64: `BOX64_DYNAREC_STRONGMEM=2`, `BOX64_DYNAREC_BIGBLOCK=0`, `BOX64_DYNAREC_BLEEDING_EDGE=0`, `BOX64_LOG=1`. |
| `valheim-server` | Invocation of `$valheim_server` through `"$cmd_valheim_wrapper"`, preserving `setsid`, signal trapping (SIGINT/SIGTERM), lifecycle hooks, and piping to `valheim-logfilter`. |
| `valheim-updater` | Replaced direct call to `/opt/steamcmd/steamcmd.sh` with `"$cmd_steamcmd_wrapper"`, ensuring transparent execution under Box86 on ARM64. |
| `.github/workflows/docker-build.yml` | Added linting/shellcheck job, docker-compose validation, multi-arch ARM64 build verification via Docker Buildx, and parameterized GHCR image naming with `${{ github.repository }}`. |

---

### New Files Created in Fork

| File | Purpose |
| :--- | :--- |
| `steamcmd-wrapper` | Executable wrapper detecting host architecture (`x86_64` vs `aarch64`). On ARM64 it injects `DEBUGGER=/usr/local/bin/box86` and `armhf` library paths, delegating cleanly to Valve's official script. |
| `valheim-wrapper` | Executable wrapper detecting host architecture. On ARM64 it enforces strict memory ordering for Unity (`BOX64_DYNAREC_STRONGMEM=2`), links `steamclient.so`, patches `libparty.so` for Ogg dependencies, and replaces process via `exec box64 "$@"`. |
| `valheim-arch-diagnostics` | Diagnostic utility inspecting system architecture, Box64/Box86 versions, ELF binary types via `file`, library paths, and memory. |
| `box64.box64rc` | Static configuration file with compatibility and optimization profiles for `valheim_server.x86_64` and `libparty.so`. |
| `docker-compose.oracle-arm64.yml` | Production-ready Docker Compose file for Oracle Cloud Ampere A1 (native ARM64, UDP ports 2456-2458, `stop_grace_period: 2m`, resource limits). |
| `.env.example` | Documented environment variable template for ARM64 deployments. |
| `tests/oracle-arm64-smoke-test.sh` | 13 automated, non-destructive smoke tests validating the entire stack on Oracle Cloud Ampere A1. |
| `scripts/patch-box64.sh` | Build script patching Box64's `wrappedlibogg_private.h` to enable missing Ogg symbols needed by PlayFab Party. |
| `scripts/test-local.ps1` | Static local validation script runnable from Windows (syntax tests for Bash, Dockerfile, and YAML). |
| `docs/ARM64.md` | In-depth technical documentation covering native/Box64/Box86 hybrid architecture and Crossplay support. |
| `docs/ORACLE-CLOUD.md` | Step-by-step provisioning, firewall, and deployment guide for Oracle Cloud Infrastructure. |
| `docs/TROUBLESHOOTING-ARM64.md` | Troubleshooting guide for ARM64, ELF, emulation, and networking issues. |

---

## Upstream Files Preserved 100% Intact
- `bootstrap`: All permission bootstrapping, syslog, and crontab logic preserved without changes.
- `valheim-bootstrap`: Startup logic and directory/adminlist verification untouched.
- `valheim-backup`: Native backup system using `zip` and cron rotation untouched.
- `valheim-status` and `valheim-is-idle`: UDP player activity monitoring untouched.
- `bepinex-updater` and `valheim-plus-updater`: Mod updaters preserved with experimental ARM64 status.
- `supervisord.conf`: Process manager configuration untouched.
- `env2cfg/*`: Python environment variable to configuration conversion untouched.
- `valheim-logfilter/*`: Go log filter untouched (compiled natively on ARM64).
