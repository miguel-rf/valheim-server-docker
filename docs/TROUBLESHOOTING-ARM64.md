# Guía de Resolución de Problemas (Troubleshooting ARM64)

Esta guía recopila soluciones a fallos comunes en entornos ARM64 / AArch64 con Box64 y Box86.

---

## 1. Comprobación Inicial de Diagnóstico

Ante cualquier comportamiento anómalo, ejecuta primero la herramienta integrada de diagnóstico:

```bash
docker compose -f docker-compose.oracle-arm64.yml exec valheim valheim-arch-diagnostics
```

Este comando verifica la arquitectura del kernel, la presencia de Box64/Box86, el tipo ELF de los binarios descargados, librerías disponibles y variables de entorno activas.

---

## 2. Errores de Arquitectura y ELF

### Error: `Exec format error`
- **Causa:** Se está intentando ejecutar un binario x86 o x86_64 directamente en la CPU ARM64 sin pasar por el emulador adecuado, o el script wrapper no tiene permisos de ejecución.
- **Diagnóstico:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim file /opt/valheim/server/valheim_server.x86_64
  ```
- **Solución:** Comprueba que `valheim-server` invoca `/usr/local/bin/valheim-wrapper` y que Box64 está instalado en `/usr/local/bin/box64`.

### Error: `Box64 not found` o `Box86 not found`
- **Causa:** La etapa de compilación de Box64 o Box86 en el Dockerfile fue omitida (por ejemplo, si se construyó con un `TARGETARCH` incorrecto) o los binarios no se copiaron en `/usr/local/bin`.
- **Diagnóstico:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim which box64 box86
  ```
- **Solución:** Reconstruye la imagen asegurando que el contexto de build tiene `TARGETARCH=arm64`:
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml build --no-cache
  ```

### Error: `missing ELF interpreter` o `No such file or directory` al ejecutar un binario existente
- **Causa:** El binario existe, pero el cargador dinámico (`ld-linux.so.2` o `/lib/ld-linux-armhf.so.3`) o las librerías compartidas fundamentales no se encuentran en las rutas estándar.
- **Diagnóstico:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim ls -l /lib/ld* /lib/arm-linux-gnueabihf/ld*
  ```
- **Solución:** Comprueba que la arquitectura `armhf` está añadida (`dpkg --print-foreign-architectures`) y que los paquetes `libc6:armhf` y `libstdc++6:armhf` están instalados.

---

## 3. Fallos en SteamCMD

### Fallo: `SteamCMD crash` o congelación en `Loading Steam API...`
- **Causa:** Conflicto con la emulación de frecuencias de CPU en máquinas virtuales ARM o librerías SDL/Curl incompletas.
- **Diagnóstico:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim /usr/local/bin/steamcmd-wrapper +login anonymous +quit
  ```
- **Solución:** Comprueba que la variable `CPU_MHZ=1500.000` está exportada (el wrapper `steamcmd-wrapper` lo hace automáticamente si no está definida en `/proc/cpuinfo`).

### Fallo: `missing shared library` (`libstdc++.so.6` o `libcurl.so.4`)
- **Causa:** Box86 no encuentra las librerías nativas `armhf` o las librerías x86 de respaldo.
- **Solución:** Verifica que `BOX86_LD_LIBRARY_PATH` contiene:
  ```text
  /usr/lib/arm-linux-gnueabihf:/lib/arm-linux-gnueabihf:/usr/lib/i386-linux-gnu:/lib/i386-linux-gnu
  ```

---

## 4. Estabilidad de Unity y Valheim (Box64)

### Fallo: `Segmentation fault` o caídas intermitentes de Unity
- **Causa:** El motor Unity realiza operaciones multihilo que violan el orden de memoria débil de ARM64.
- **Solución:** Asegúrate de que `BOX64_DYNAREC_STRONGMEM=2` está activo. Puedes verificarlo o forzarlo en tu archivo `valheim.env`:
  ```ini
  BOX64_DYNAREC_STRONGMEM=2
  BOX64_DYNAREC_BIGBLOCK=0
  BOX64_DYNAREC_BLEEDING_EDGE=0
  ```

### Fallo: `Unity crash` / `Failed to load steamclient.so`
- **Causa:** Unity Steamworks busca `steamclient.so` en `~/.steam/sdk64/steamclient.so`.
- **Diagnóstico:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml exec valheim ls -la /home/valheim/.steam/sdk64/
  ```
- **Solución:** `valheim-wrapper` crea automáticamente un enlace simbólico desde `/opt/valheim/server/linux64/steamclient.so` hacia `/home/valheim/.steam/sdk64/steamclient.so`. Si no existe, créalo manualmente o reinicia el contenedor.

---

## 5. Red y Conectividad (Servidor no visible)

### Fallo: El servidor arranca pero no aparece en la lista pública o no responde a conexiones directas
- **Causa habitual:** Los puertos UDP no están abiertos en alguna de las dos capas de firewall (Oracle Cloud o Ubuntu).
- **Diagnóstico en la máquina anfitriona:**
  ```bash
  # 1. Verificar si Docker tiene los puertos UDP escuchando en el host:
  sudo ss -u -l -n | grep -E ':(2456|2457|2458)'

  # 2. Comprobar reglas de firewall en Ubuntu:
  sudo iptables -L -n -v | grep 2456
  # o si usas UFW:
  sudo ufw status verbose
  ```
- **Solución:**
  1. Abre la consola de Oracle Cloud y añade en tu **Security List** una regla de entrada (Ingress) UDP en el rango `2456-2458` desde `0.0.0.0/0`.
  2. En Ubuntu ejecuta:
     ```bash
     sudo iptables -I INPUT 6 -m state --state NEW -p udp --dport 2456:2458 -j ACCEPT
     ```

---

## 6. Permisos y Persistencia del Mundo

### Fallo: `Permission denied` en `/config` o `/opt/valheim`
- **Causa:** Los volúmenes montados en el host pertenecen a un usuario con UID/GID distinto al configurado en el contenedor (`PUID`/`PGID`).
- **Diagnóstico:**
  ```bash
  ls -ld valheim-data/config valheim-data/server
  id -u
  id -g
  ```
- **Solución:** Ajusta la propiedad de las carpetas en el host:
  ```bash
  sudo chown -R 1000:1000 valheim-data/
  ```
  Y asegúrate de que en `valheim.env` tienes:
  ```ini
  PUID=1000
  PGID=1000
  ```

### Fallo: `World not persisted` (el mundo se reinicia al recrear el contenedor)
- **Causa:** El volumen de `/config` no está montado correctamente en el archivo `docker-compose.oracle-arm64.yml`.
- **Solución:** Verifica que la sección de volúmenes monta `./valheim-data/config:/config` y que los archivos `.db` y `.fwl` se encuentran en `./valheim-data/config/worlds_local/`.

### Fallo: `Container restarting` en bucle
- **Causa:** Contraseña demasiado corta (`SERVER_PASS` menor a 5 caracteres o contenida en el nombre del servidor) o supervisorctl fallando.
- **Diagnóstico:**
  ```bash
  docker compose -f docker-compose.oracle-arm64.yml logs valheim | tail -n 50
  ```
- **Solución:** Cambia `SERVER_PASS` en `valheim.env` a una clave alfanumérica de al menos 8 caracteres y reinicia el contenedor.
