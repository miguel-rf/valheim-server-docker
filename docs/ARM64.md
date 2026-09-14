# Arquitectura y Soporte ARM64 / AArch64 (Box64 & Box86)

Este documento detalla los fundamentos técnicos de la compatibilidad ARM64 en este fork de `community-valheim-tools/valheim-server-docker`.

---

## 1. Visión General y Filosofía

La premisa principal de este fork es **evitar la emulación completa del contenedor mediante QEMU** (`platform: linux/amd64`). En servidores de producción (como instancias Oracle Cloud Ampere A1), la emulación completa por QEMU genera una sobrecarga excesiva de CPU, alta latencia en networking UDP y un consumo desproporcionado de memoria.

En su lugar, este proyecto implementa una arquitectura híbrida nativa:
- El contenedor Docker es **100% nativo `linux/arm64`**.
- El sistema operativo (Debian Trixie), Python, Bash, BusyBox, supervisor, cron y herramientas como `valheim-logfilter` se ejecutan **nativamente a velocidad directa en la CPU ARM64**.
- La emulación userspace se aplica **única y exclusivamente** a los binarios propietarios de Valve e Iron Gate que carecen de versión nativa ARM64.

---

## 2. Diagrama de la Arquitectura

```text
               Oracle Cloud VM (Ampere A1 / AArch64)
                               │
               Docker Engine (Nativo ARM64)
                               │
       ┌───────────────────────┴───────────────────────┐
       │   Contenedor Nativo: linux/arm64              │
       │                                               │
       ├─ [Nativo ARM64]                               │
       │   ├── Linux Kernel calls                      │
       │   ├── Bash scripts (valheim-server, backup)   │
       │   ├── Python / supervisor / cron              │
       │   ├── BusyBox & valheim-logfilter (Go ARM64)  │
       │   └── Librerías del sistema (glibc ARM64)     │
       │                                               │
       ├─ [Box86 Userspace Dynarec]                    │
       │   └── Valve SteamCMD (x86 32-bit ELF)         │
       │         └── Traduce a librerías Debian armhf  │
       │                                               │
       └─ [Box64 Userspace Dynarec]                    │
           └── valheim_server.x86_64 (x86_64 ELF)      │
                 ├── Motor Unity (Mono/IL2CPP)         │
                 ├── libdoorstop_x64.so (Mods)         │
                 └── steamclient.so (Steamworks)       │
```

---

## 3. Componentes Emulados vs Componentes Nativos

| Componente | Tipo de Ejecución | Justificación Técnica |
| :--- | :--- | :--- |
| **Scripts del proyecto (`valheim-*`)** | Nativo ARM64 | Scripts bash ejecutados directamente por `/bin/bash` nativo. |
| **`valheim-logfilter`** | Nativo ARM64 | Compilado desde código fuente Go en el build-env usando Go para ARM64. |
| **BusyBox** | Nativo ARM64 | Compilado nativamente desde código fuente durante el build. |
| **Python / Supervisor / Cron** | Nativo ARM64 | Paquetes nativos de Debian Trixie arm64. |
| **SteamCMD** | Box86 (x86 32-bit) | Valve solo publica binarios x86 de 32 bits (`linux32/steamcmd`). Se ejecuta mediante Box86 traduciendo llamadas a la capa multiarch `armhf`. |
| **Valheim Dedicated Server** | Box64 (x86_64) | Iron Gate únicamente compila el servidor dedicado para Linux `x86_64`. Box64 lo ejecuta con recompilación dinámica (Dynarec). |
| **Librerías de plugins / Doorstop** | Box64 (x86_64) | `libdoorstop_x64.so` es un objeto compartido x86_64 cargado en el espacio de memoria de Valheim por Box64. |

---

## 4. Por qué Valheim requiere Box64 y Ajustes de Memoria

El motor Unity (`valheim_server.x86_64`) es multihilo y está diseñado bajo la premisa de la arquitectura x86_64, que cuenta con un **modelo de memoria fuertemente ordenado (TSO - Total Store Order)**.

Las CPUs ARM64 (como Neoverse N1 en Ampere A1) implementan un **modelo de memoria débilmente ordenado**. Sin intervención, los hilos de Unity pueden experimentar carreras de datos (race conditions), bloqueos de hilos (deadlocks) o caídas en la inicialización de la red zRPC de Valheim.

Para solucionar esto, configuramos Box64 con:
- `BOX64_DYNAREC_STRONGMEM=2`: Fuerza a Box64 a insertar barreras de memoria estrictas para emular el modelo TSO de x86.
- `BOX64_DYNAREC_BIGBLOCK=0`: Reduce el tamaño de los bloques del Dynarec para prevenir invalidaciones de código en Unity JIT.
- `BOX64_DYNAREC_BLEEDING_EDGE=0`: Mantiene la generación de código más conservadora y probada.

Estos valores se encuentran preconfigurados en `/etc/box64.box64rc` y en `valheim-wrapper`, pudiendo ajustarse mediante variables de entorno si fuese necesario.

---

## 5. Por qué SteamCMD requiere Box86

El script oficial de Valve `steamcmd.sh` lanza el binario `linux32/steamcmd`, un ejecutable ELF de 32 bits para x86. Box64 está diseñado para binarios de 64 bits y no ejecuta binarios de 32 bits directamente.

Por tanto:
1. El contenedor habilita la arquitectura multiarch `armhf` (`dpkg --add-architecture armhf`).
2. Se instala Box86 compilado específicamente para sistemas ARM64 con multiarch (`-DARM64=1`).
3. El script `steamcmd-wrapper` inyecta `DEBUGGER=/usr/local/bin/box86` y las rutas de librerías `BOX86_LD_LIBRARY_PATH`.
4. El propio script de Valve contiene un hook nativo que reconoce la variable `$DEBUGGER`, ejecutando Box86 sin necesidad de parches invasivos en el código de Valve.

---

## 6. Manejo de Señales y Apagado Limpio

Cuando el contenedor recibe una orden de parada (`docker compose stop`):
1. Docker envía `SIGTERM` al PID 1 (`tini`).
2. `tini` lo remite a `supervisord`.
3. `supervisord` consulta `supervisord.conf` (`stopwaitsecs=90`, `killasgroup=true`) y envía `SIGTERM` al proceso `valheim-server`.
4. El script `valheim-server` captura la señal mediante su trap y envía `kill -INT -$valheim_server_pid`.
5. Al haberse invocado Valheim mediante `exec /usr/local/bin/box64 "$@"`, el proceso que recibe la señal es directamente Box64, que la traslada inmediatamente al motor Unity.
6. Unity ejecuta la rutina de guardado en disco (`world save`), garantizando que los archivos `.db` y `.fwl` queden sincronizados antes de que finalice el proceso.

---

## 7. Estado de Soporte de Mods

- **Vanilla Valheim**: `SUPPORTED` (Probado y optimizado).
- **BepInEx x64 (Doorstop)**: `EXPERIMENTAL`. Box64 puede cargar `libdoorstop_x64.so` y ensamblados .NET Mono, pero plugins nativos que dependan de instrucciones específicas pueden presentar inestabilidad.
- **ValheimPlus**: `EXPERIMENTAL`.

---

## 8. Soporte de Crossplay Multiplataforma (PlayFab Party) en ARM64

### El Desafío Técnico de Crossplay en ARM64
En Valheim, el modo `-crossplay` permite que jugadores de **Nintendo Switch 2, PlayStation (PS4/PS5), Xbox (One / Series X|S) y PC (Steam / Xbox PC App)** jueguen en el mismo servidor dedicado.

Este sistema está gestionado por **Microsoft Azure PlayFab Party** a través del plugin nativo x86_64 `valheim_server_Data/Plugins/libparty.so`.

En entornos ARM64 con emulación Box64 estándar, la carga de `libparty.so` fallaba históricamente por dos motivos críticos:
1. **Librería dinámica Ogg no declarada**: `libparty.so` utiliza 14 funciones de `libogg` (`ogg_stream_packetin`, `ogg_sync_init`, `ogg_stream_pageout_fill`, etc.), pero los desarrolladores no incluyeron la entrada `DT_NEEDED [libogg.so.0]` en la sección dinámica del ELF. En consecuencia, el cargador de Box64 no enlazaba la librería nativa de audio.
2. **Funciones no expuestas en el wrapper de Box64**: En Box64 v0.4.4, la función `ogg_stream_pageout_fill` se encontraba comentada en `src/wrapped/wrappedlibogg_private.h`. Al intentar resolver la tabla PLT, Box64 arrojaba:
   ```text
   [BOX64] Error: Symbol ogg_stream_packetin not found, cannot apply R_X86_64_JUMP_SLOT ... in libparty.so
   [BOX64] Error initializing needed lib /opt/valheim/server/valheim_server_Data/Plugins/libparty.so
   DllNotFoundException: libParty.so
   ```

### Solución Implementada en Este Fork
1. **Parche a Box64 (`scripts/patch-box64.sh`)**: Durante el build de Docker, se descomentan y habilitan todas las funciones de Ogg en `wrappedlibogg_private.h`, asegurando una cobertura del 100% de la API de `libogg.so.0`.
2. **Inyección de dependencia dinámica (`valheim-wrapper`)**: Se utiliza `patchelf --add-needed libogg.so.0` sobre `libparty.so` y se define `BOX64_LD_PRELOAD="libogg.so.0"`, garantizando que `libparty.so` resuelva todos los símbolos de inmediato.
3. **Capa nativa de red y audio**: Se incluyen las librerías nativas `libogg0`, `libatomic1`, `libpulse0` y `libpulse-mainloop-glib0` en el contenedor.

### Cómo Conectarse al Servidor desde Cada Plataforma

| Plataforma | Método de Conexión | Instrucciones |
| :--- | :--- | :--- |
| **Nintendo Switch 2** | **Join Code (Código de Unión)** | En el menú del juego, ir a **Unirse a partida** > Marcar **Crossplay** > Introducir el **Join Code** de 6 dígitos mostrado en los registros del servidor (ej. `459186`). |
| **PlayStation (PS4 / PS5)** | **Join Code** | Ir a **Unirse a partida** > Activar Crossplay > Introducir el **Join Code**. También se puede añadir a Favoritos mediante IP:Port si la red de la consola lo permite. |
| **Xbox One / Series X\|S** | **Join Code** | Ir a **Unirse a partida** > Activar Crossplay > Introducir el **Join Code**. |
| **PC (Steam / Xbox App / PC Game Pass)** | **IP Directa o Join Code** | - Por IP directa: Añadir `51.170.55.235:2456` a los favoritos de Steam o conexión directa en el juego.<br>- Por Crossplay: Introducir el **Join Code**. |

