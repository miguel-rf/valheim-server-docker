# ARM64 / AArch64 Architecture and Support (Box64 & Box86)

This document details the technical foundation and architecture of the ARM64 compatibility layer in this fork of `community-valheim-tools/valheim-server-docker`.

---

## 1. Overview and Core Philosophy

The central design principle of this fork is to **avoid full container emulation via QEMU** (`platform: linux/amd64`). On production ARM64 servers (such as Oracle Cloud Ampere A1 instances), full QEMU system or user emulation introduces severe CPU overhead, erratic UDP network latency, and excessive memory footprint.

Instead, this project employs a **native hybrid architecture**:
- The Docker container is **100% native `linux/arm64`**.
- The base OS (Debian Trixie), Python runtime, Bash, BusyBox, supervisor, cron daemon, and tools like `valheim-logfilter` run **natively at full bare-metal CPU speed on ARM64**.
- Userspace dynamic binary translation (Dynarec) is applied **strictly and exclusively** to proprietary Valve and Iron Gate binaries that lack an official ARM64 build.

---

## 2. Architecture Overview

```text
               Oracle Cloud VM (Ampere A1 / AArch64)
                               │
                Docker Engine (Native ARM64)
                               │
        ┌───────────────────────┴───────────────────────┐
        │   Native Container: linux/arm64               │
        │                                               │
        ├─ [Native ARM64]                               │
        │   ├── Linux Kernel system calls               │
        │   ├── Bash scripts (valheim-server, backup)   │
        │   ├── Python / supervisor / cron              │
        │   ├── BusyBox & valheim-logfilter (Go ARM64)  │
        │   └── System shared libraries (glibc ARM64)   │
        │                                               │
        ├─ [Box86 Userspace Dynarec]                    │
        │   └── Valve SteamCMD (x86 32-bit ELF)         │
        │         └── Translates to Debian armhf libs   │
        │                                               │
        └─ [Box64 Userspace Dynarec]                    │
            └── valheim_server.x86_64 (x86_64 ELF)      │
                  ├── Unity Engine (Mono/IL2CPP)        │
                  ├── libdoorstop_x64.so (Mods)         │
                  ├── libparty.so (PlayFab Crossplay)   │
                  └── steamclient.so (Steamworks)       │
```

---

## 3. Emulated vs. Native Components

| Component | Execution Mode | Technical Rationale |
| :--- | :--- | :--- |
| **Project scripts (`valheim-*`)** | Native ARM64 | Shell scripts executed directly by the native `/bin/bash` interpreter. |
| **`valheim-logfilter`** | Native ARM64 | Compiled from Go source code in the multi-stage build environment using Go for ARM64. |
| **BusyBox** | Native ARM64 | Compiled natively from source during the build process. |
| **Python / Supervisor / Cron** | Native ARM64 | Native Debian Trixie `arm64` packages. |
| **SteamCMD** | Box86 (x86 32-bit) | Valve only distributes 32-bit x86 binaries (`linux32/steamcmd`). Box86 executes it by translating calls to the Debian `armhf` multiarch layer. |
| **Valheim Dedicated Server** | Box64 (x86_64) | Iron Gate exclusively compiles the dedicated server for Linux `x86_64`. Box64 executes it using high-performance dynamic recompilation (Dynarec). |
| **Plugin / Doorstop Libraries** | Box64 (x86_64) | `libdoorstop_x64.so` is an x86_64 shared object loaded into Valheim's memory space via Box64. |

---

## 4. Why Valheim Requires Box64 Memory Tuning

The Unity Engine (`valheim_server.x86_64`) is heavily multithreaded and was designed around the x86_64 architecture's **Total Store Order (TSO)** memory consistency model.

ARM64 CPUs (including the Neoverse N1 in Ampere A1) implement a **weakly-ordered memory model**. Without explicit synchronization, Unity's worker threads can encounter race conditions, deadlocks, and corrupted zRPC networking initialization.

To eliminate this, Box64 is configured with:
- `BOX64_DYNAREC_STRONGMEM=2`: Forces Box64 to insert strict memory barriers, reliably emulating the x86 TSO model.
- `BOX64_DYNAREC_BIGBLOCK=0`: Reduces basic block size in Dynarec to prevent invalidations during Unity JIT execution.
- `BOX64_DYNAREC_BLEEDING_EDGE=0`: Maintains conservative, thoroughly-tested Dynarec optimization rules.

These settings are preconfigured in `/etc/box64.box64rc` and `valheim-wrapper`, and can be adjusted via environment variables if needed.

---

## 5. Why SteamCMD Requires Box86

Valve's official `steamcmd.sh` launcher executes `linux32/steamcmd`, a 32-bit x86 ELF binary. Box64 is designed specifically for 64-bit ELF binaries and cannot run 32-bit code directly.

Therefore:
1. The container enables the `armhf` multiarch architecture (`dpkg --add-architecture armhf`).
2. Box86 is built with multiarch ARM64 support enabled (`-DARM64=1`).
3. The `steamcmd-wrapper` script sets `DEBUGGER=/usr/local/bin/box86` and configures `BOX86_LD_LIBRARY_PATH`.
4. Valve's `steamcmd.sh` natively respects `$DEBUGGER`, invoking Box86 seamlessly without modifying Valve's proprietary files.

---

## 6. Signal Handling and Graceful World Saving

When Docker issues a stop command (`docker compose stop`):
1. Docker sends `SIGTERM` to PID 1 (`tini`).
2. `tini` forwards the signal to `supervisord`.
3. `supervisord` reads `supervisord.conf` (`stopwaitsecs=90`, `killasgroup=true`) and sends `SIGTERM` to `valheim-server`.
4. The `valheim-server` script traps the signal and sends `kill -INT -$valheim_server_pid`.
5. Because Valheim is started via `exec /usr/local/bin/box64 "$@"`, Box64 receives the signal directly and delivers it to the Unity Engine.
6. Unity triggers its world-saving routine, ensuring `.db` and `.fwl` world files are flushed to disk before shutdown.

---

## 7. Mod Support Status

- **Vanilla Valheim**: `SUPPORTED` (Fully tested and production-ready).
- **BepInEx x64 (Doorstop)**: `EXPERIMENTAL`. Box64 successfully loads `libdoorstop_x64.so` and .NET Mono assemblies, but native x86 plugins with architecture-specific assembly instructions may experience instability.
- **ValheimPlus**: `EXPERIMENTAL`.

---

## 8. Multiplatform Crossplay Support (PlayFab Party) on ARM64

### The Crossplay Challenge on ARM64
In Valheim, the `-crossplay` flag allows players across **Nintendo Switch 2, PlayStation (PS4/PS5), Xbox (One / Series X|S), and PC (Steam / Xbox PC App)** to join the same dedicated server.

This functionality is managed by **Microsoft Azure PlayFab Party** through the native x86_64 plugin:  
`valheim_server_Data/Plugins/libparty.so`.

On ARM64 with standard Box64, loading `libparty.so` historically failed due to two critical issues:
1. **Undeclared Ogg Dynamic Library**: `libparty.so` references 14 Ogg audio functions (`ogg_stream_packetin`, `ogg_sync_init`, `ogg_stream_pageout_fill`, etc.), but does not include `DT_NEEDED [libogg.so.0]` in its ELF dynamic section. Consequently, Box64 did not automatically load the native Ogg library.
2. **Missing Function in Box64 v0.4.4 Wrappers**: Box64's `src/wrapped/wrappedlibogg_private.h` had `ogg_stream_pageout_fill` commented out. When resolving the PLT table, Box64 threw:
   ```text
   [BOX64] Error: Symbol ogg_stream_packetin not found, cannot apply R_X86_64_JUMP_SLOT ... in libparty.so
   [BOX64] Error initializing needed lib /opt/valheim/server/valheim_server_Data/Plugins/libparty.so
   DllNotFoundException: libParty.so
   ```

### Implementation in this Fork
1. **Box64 Source Patch (`scripts/patch-box64.sh`)**: Uncomments and enables all missing Ogg symbols in `wrappedlibogg_private.h` during image build, providing 100% coverage of the `libogg.so.0` API.
2. **Dynamic ELF Dependency Injection (`valheim-wrapper`)**: Executes `patchelf --add-needed libogg.so.0` on `libparty.so` and sets `BOX64_LD_PRELOAD="libogg.so.0"`, guaranteeing immediate PLT resolution.
3. **Native ARM64 Libraries**: Installs `libogg0`, `libatomic1`, `libpulse0`, and `libpulse-mainloop-glib0` in the container runtime.

### How Players Connect Across Platforms

| Platform | Connection Method | Instructions |
| :--- | :--- | :--- |
| **Nintendo Switch 2** | **Join Code** | In-game menu > **Join Game** > Check **Crossplay** > Enter the 6-digit **Join Code** displayed in server logs (e.g., `459186`). |
| **PlayStation (PS4 / PS5)** | **Join Code** | **Join Game** > Enable Crossplay > Enter the **Join Code**. Also supports direct IP if console network allows. |
| **Xbox One / Series X\|S** | **Join Code** | **Join Game** > Enable Crossplay > Enter the **Join Code**. |
| **PC (Steam / Xbox App / PC Game Pass)** | **Direct IP or Join Code** | - Direct IP: Add `<server-ip>:2456` to Steam Server Favorites or direct connect in-game.<br>- Crossplay: Enter the **Join Code**. |
