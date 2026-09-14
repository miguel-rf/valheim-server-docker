# ARM64 Troubleshooting Guide (TROUBLESHOOTING-ARM64)

This guide provides solutions to common issues encountered in ARM64 / AArch64 environments running Valheim under Box64 and Box86.

---

## 1. Initial Diagnostic Check

If you encounter unexpected behavior, run the integrated architecture diagnostics tool first:

```bash
docker compose -f docker-compose.oracle-arm64.yml exec valheim valheim-arch-diagnostics
```

This command inspects kernel architecture, Box64/Box86 presence, ELF binary types of downloaded assets, available libraries, and active environment variables.

---

## 2. Architecture and ELF Binary Errors

### Error: `Exec format error`
- **Cause:** An x86 or x86_64 binary is being executed directly on the ARM64 CPU without the required emulator wrapper, or the wrapper script lacks execution permissions.
- **Diagnostics:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim file /opt/valheim/server/valheim_server.x86_64
  ```
- **Solution:** Verify that `valheim-server` invokes `/usr/local/bin/valheim-wrapper` and that Box64 is installed at `/usr/local/bin/box64`.

### Error: `Box64 not found` or `Box86 not found`
- **Cause:** The Box64 or Box86 compilation stage in the Dockerfile was skipped (e.g., if built with an incorrect `TARGETARCH`) or the binaries failed to copy into `/usr/local/bin`.
- **Diagnostics:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim which box64 box86
  ```
- **Solution:** Rebuild the container ensuring the build context targets `TARGETARCH=arm64`:
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml build --no-cache
  ```

### Error: `missing ELF interpreter` or `No such file or directory` when running an existing binary
- **Cause:** The binary exists, but the dynamic loader (`ld-linux.so.2` or `/lib/ld-linux-armhf.so.3`) or foundational shared libraries are not found in standard system search paths.
- **Diagnostics:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim ls -l /lib/ld* /lib/arm-linux-gnueabihf/ld*
  ```
- **Solution:** Check that the `armhf` foreign architecture is enabled (`dpkg --print-foreign-architectures`) and that `libc6:armhf` and `libstdc++6:armhf` are installed.

---

## 3. SteamCMD Issues

### Issue: `SteamCMD crash` or hang at `Loading Steam API...`
- **Cause:** Conflict with CPU frequency reporting on ARM virtual machines or incomplete SDL/cURL dynamic libraries.
- **Diagnostics:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim /usr/local/bin/steamcmd-wrapper +login anonymous +quit
  ```
- **Solution:** Ensure the environment variable `CPU_MHZ=1500.000` is exported (`steamcmd-wrapper` sets this automatically if `/proc/cpuinfo` lacks frequency data).

### Issue: `missing shared library` (`libstdc++.so.6` or `libcurl.so.4`)
- **Cause:** Box86 cannot locate the native `armhf` libraries or fallback x86 libraries.
- **Solution:** Verify that `BOX86_LD_LIBRARY_PATH` includes:
  ```text
  /usr/lib/arm-linux-gnueabihf:/lib/arm-linux-gnueabihf:/usr/lib/i386-linux-gnu:/lib/i386-linux-gnu
  ```

---

## 4. Unity Engine and Valheim Stability (Box64)

### Issue: `Segmentation fault` or intermittent Unity crashes
- **Cause:** Unity Engine executes multithreaded operations that violate ARM64's weakly-ordered memory model.
- **Solution:** Ensure `BOX64_DYNAREC_STRONGMEM=2` is active. You can verify or enforce this in your `valheim.env`:
  ```ini
  BOX64_DYNAREC_STRONGMEM=2
  BOX64_DYNAREC_BIGBLOCK=0
  BOX64_DYNAREC_BLEEDING_EDGE=0
  ```

### Issue: `Unity crash` / `Failed to load steamclient.so`
- **Cause:** Unity Steamworks looks for `steamclient.so` at `~/.steam/sdk64/steamclient.so`.
- **Diagnostics:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim ls -la /home/valheim/.steam/sdk64/
  ```
- **Solution:** `valheim-wrapper` automatically creates a symlink from `/opt/valheim/server/linux64/steamclient.so` to `/home/valheim/.steam/sdk64/steamclient.so`. If missing, recreate it or restart the container.

---

## 5. Crossplay & PlayFab Party Issues

### Issue: `DllNotFoundException: libParty.so` or `Symbol ogg_stream_packetin not found`
- **Cause:** `libparty.so` requires Ogg functions but lacks `DT_NEEDED [libogg.so.0]` in its ELF headers, or Box64's Ogg wrapper is incomplete.
- **Solution:** Ensure `scripts/patch-box64.sh` was executed during image build and that `valheim-wrapper` patches `libparty.so` with `patchelf --add-needed libogg.so.0`.

---

## 6. Networking and Connectivity (Server Not Visible)

### Issue: Server starts but does not appear in public server browser or fails direct connect
- **Common Cause:** UDP ports are blocked by one of the two independent firewall layers (Oracle Cloud Security List or Ubuntu host firewall).
- **Diagnostics on host machine:**
  ```bash
  # 1. Verify Docker is listening on UDP ports:
  sudo ss -u -l -n | grep -E ':(2456|2457|2458)'

  # 2. Check Ubuntu host firewall rules:
  sudo iptables -L -n -v | grep 2456
  # or if using UFW:
  sudo ufw status verbose
  ```
- **Solution:**
  1. Open the Oracle Cloud Console and add an Ingress UDP rule for ports `2456-2458` from `0.0.0.0/0` in your **Security List**.
  2. On the Ubuntu host, execute:
     ```bash
     sudo iptables -I INPUT 6 -m state --state NEW -p udp --dport 2456:2458 -j ACCEPT
     ```

---

## 7. Permissions and World Persistence

### Issue: `Permission denied` on `/config` or `/opt/valheim`
- **Cause:** Host volume directories are owned by a UID/GID different from the container's `PUID`/`PGID`.
- **Diagnostics:**
  ```bash
  ls -ld valheim-data/config valheim-data/server
  id -u
  id -g
  ```
- **Solution:** Set ownership on the host:
  ```bash
  sudo chown -R 1000:1000 valheim-data/
  ```
  And verify that `valheim.env` contains:
  ```ini
  PUID=1000
  PGID=1000
  ```

### Issue: `World not persisted` (world resets when recreating container)
- **Cause:** The `/config` volume is not mapped correctly in `docker-compose.oracle-arm64.yml`.
- **Solution:** Verify the volume mount `./valheim-data/config:/config` is present and that world files `.db` and `.fwl` exist under `./valheim-data/config/worlds_local/`.

### Issue: `Container restarting` in a crash loop
- **Cause:** Password too short (`SERVER_PASS` less than 5 characters or identical to server name) or supervisor configuration error.
- **Diagnostics:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml logs valheim | tail -n 50
  ```
- **Solution:** Update `SERVER_PASS` in `valheim.env` to a secure alphanumeric string of at least 8 characters and restart the container.
