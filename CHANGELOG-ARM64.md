# Registro de Cambios del Fork ARM64 (CHANGELOG-ARM64)

Este documento registra todas las adiciones y modificaciones realizadas respecto al repositorio upstream `community-valheim-tools/valheim-server-docker`.

---

## Principio de Diseño del Fork
El objetivo es **modificar lo mínimo indispensable** del código upstream, encapsulando la compatibilidad de arquitectura en wrappers externos e instrucciones Dockerfile multi-stage, garantizando compatibilidad total y facilidad de sincronización futura (`git rebase upstream/main`).

---

## Resumen de Archivos Modificados vs Nuevos

### Archivos Modificados de Upstream

| Archivo | Motivo de la Modificación |
| :--- | :--- |
| `Dockerfile` | 1. Parametrización de Go 1.24 mediante `ARG TARGETARCH` (`linux-amd64` / `linux-arm64`).<br>2. Ajuste de BusyBox Kconfig para no forzar `CONFIG_STACK_OPTIMIZATION_386` en ARM64.<br>3. Nuevas etapas multi-stage `box64-builder` y `box86-builder` compilando desde fuente.<br>4. Inclusión de multiarch `armhf` y librerías de runtime en Debian Trixie.<br>5. Copia de wrappers (`steamcmd-wrapper`, `valheim-wrapper`, `valheim-arch-diagnostics`) y configuración `box64.box64rc`.<br>6. Invocación de SteamCMD durante el build a través de `steamcmd-wrapper`. |
| `common` | Definición de comandos de wrappers: `cmd_valheim_wrapper` y `cmd_steamcmd_wrapper`. |
| `defaults` | Incorporación de variables por defecto para Box64 en ARM64: `BOX64_DYNAREC_STRONGMEM=2`, `BOX64_DYNAREC_BIGBLOCK=0`, `BOX64_DYNAREC_BLEEDING_EDGE=0`, `BOX64_LOG=1`. |
| `valheim-server` | Invocación de `$valheim_server` a través de `"$cmd_valheim_wrapper"`, manteniendo intactos `setsid`, la captura de señales (SIGINT/SIGTERM), los hooks y la canalización a `valheim-logfilter`. |
| `valheim-updater` | Sustitución de la llamada directa `/opt/steamcmd/steamcmd.sh` por `"$cmd_steamcmd_wrapper"`, garantizando la ejecución transparente mediante Box86 en ARM64. |
| `.github/workflows/docker-build.yml` | Incorporación de job de linting/shellcheck, validación de docker-compose, verificación de compilación ARM64 mediante Docker Buildx y parametrización de nombres de imagen GHCR con `${{ github.repository }}`. |

---

### Archivos Nuevos Creados en el Fork

| Archivo | Propósito |
| :--- | :--- |
| `steamcmd-wrapper` | Wrapper ejecutable que detecta la arquitectura (`x86_64` vs `aarch64`). En ARM64 inyecta `DEBUGGER=/usr/local/bin/box86` y rutas de librerías `armhf`, delegando transparentemente en el script oficial de Valve. |
| `valheim-wrapper` | Wrapper ejecutable que detecta la arquitectura. En ARM64 configura barreras de memoria estricta para Unity (`BOX64_DYNAREC_STRONGMEM=2`), enlaza `steamclient.so` y reemplaza el proceso mediante `exec box64 "$@"`. |
| `valheim-arch-diagnostics` | Herramienta de diagnóstico para inspeccionar la arquitectura del sistema, estado de Box64/Box86, tipos ELF con `file`, librerías y memoria. |
| `box64.box64rc` | Archivo de configuración estático con perfiles de compatibilidad y optimización para `valheim_server.x86_64`. |
| `docker-compose.oracle-arm64.yml` | Plantilla de Docker Compose lista para producción en Oracle Cloud Ampere A1 (ARM64 nativo, puertos UDP 2456-2458, `stop_grace_period: 2m`, límites de recursos). |
| `.env.example` | Plantilla de variables de entorno documentada para despliegues ARM64. |
| `tests/oracle-arm64-smoke-test.sh` | Suite de 12 pruebas automatizadas no destructivas para validar la instalación en la VM Oracle Cloud Ampere A1. |
| `scripts/test-local.ps1` | Script de validación estática local ejecutable desde Windows 10 (pruebas de sintaxis Bash, Dockerfile y YAML). |
| `docs/ARM64.md` | Documentación técnica profunda sobre la arquitectura híbrida nativa/Box64/Box86. |
| `docs/ORACLE-CLOUD.md` | Manual paso a paso de aprovisionamiento, firewall y despliegue en Oracle Cloud. |
| `docs/TROUBLESHOOTING-ARM64.md` | Guía de resolución de problemas específicos de ARM64, ELF, emulación y red. |

---

## Archivos Upstream Preservados Intactos al 100%
- `bootstrap`: Toda la lógica de bootstrapping de permisos, syslog y crontab se conserva sin cambios.
- `valheim-bootstrap`: Lógica de arranque y verificación de directorios/adminlists intacta.
- `valheim-backup`: Sistema nativo de copias de seguridad con `zip` y rotación cron intacto.
- `valheim-status` y `valheim-is-idle`: Monitoreo UDP de actividad de jugadores intacto.
- `bepinex-updater` y `valheim-plus-updater`: Actualizadores de mods conservados con soporte clasificado como experimental.
- `supervisord.conf`: Configuración del gestor de procesos supervisord intacta.
- `env2cfg/*`: Conversión de variables de entorno a configuración en Python intacta.
- `valheim-logfilter/*`: Filtro de logs en Go intacto (se compila nativo en ARM64).
