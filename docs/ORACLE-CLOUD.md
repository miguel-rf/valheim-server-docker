# Guía de Despliegue en Oracle Cloud (Ampere A1 ARM64)

Esta guía explica paso a paso cómo desplegar el servidor dedicado de Valheim en una máquina virtual **Oracle Cloud Infrastructure (OCI) Ampere A1 (AArch64 / ARM64)** con Ubuntu Server.

---

## 1. Verificación Inicial de la Instancia

Conéctate por SSH a tu instancia de Oracle Cloud y verifica que la arquitectura de la máquina sea efectivamente ARM64:

```bash
uname -m
```

**Resultado esperado:**
```text
aarch64
```

Si el resultado no es `aarch64`, estás en una máquina x86/AMD y no necesitas emulación ARM.

---

## 2. Instalación de Docker y Docker Compose

En Ubuntu Server, instala Docker Engine oficial y el plugin de Docker Compose:

```bash
# Actualizar repositorios e instalar certificados
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

# Añadir la clave GPG oficial de Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Configurar el repositorio apt de Docker para ARM64
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Instalar Docker Engine, CLI y Compose Plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Permitir a tu usuario actual ejecutar Docker sin sudo (opcional pero recomendado)
sudo usermod -aG docker $USER
newgrp docker
```

Verifica la instalación de Docker:
```bash
docker info | grep "Architecture"
```
**Resultado esperado:**
```text
Architecture: aarch64
```

---

## 3. Configuración de Red y Firewall (OCI y Ubuntu)

Valheim utiliza tráfico **UDP** en el rango **2456 a 2458**.
En Oracle Cloud existen **dos capas independientes de cortafuegos** que deben permitir este tráfico:

### Capa 1: Oracle Cloud Security List / NSG (Consola Web)
1. Inicia sesión en la consola de Oracle Cloud.
2. Navega a: **Networking > Virtual Cloud Networks > [Tu VCN] > Security Lists > Default Security List**.
3. Añade una **Ingress Rule**:
   - **Source Type:** CIDR
   - **Source CIDR:** `0.0.0.0/0`
   - **IP Protocol:** `UDP`
   - **Source Port Range:** All
   - **Destination Port Range:** `2456-2458`
   - **Description:** `Valheim Dedicated Server UDP Ports`
4. Guarda la regla.

### Capa 2: Cortafuegos del Sistema Operativo Ubuntu (Host)
Por defecto, las imágenes de Ubuntu en Oracle Cloud vienen con reglas estrictas de `iptables` o `ufw`.
Abre los puertos en el cortafuegos del host:

```bash
# Si utilizas UFW:
sudo ufw allow 2456:2458/udp
sudo ufw reload

# Si tu imagen de Oracle utiliza iptables directamente (habitual en Ubuntu OCI):
sudo iptables -I INPUT 6 -m state --state NEW -p udp --dport 2456:2458 -j ACCEPT
sudo netfilter-persistent save || sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

> [!IMPORTANT]
> Nunca uses `network_mode: host` o contenedores `--privileged` para modificar el firewall del host. La configuración de red debe realizarse directamente en la máquina anfitriona.

---

## 4. Clonar el Fork y Preparar los Archivos

```bash
# Clonar tu fork en el directorio home
git clone https://github.com/<tu-usuario>/valheim-server-docker.git valheim-server
cd valheim-server

# Crear directorios para los volúmenes persistentes
mkdir -p valheim-data/config valheim-data/server

# Crear archivo de configuración de entorno desde la plantilla
cp .env.example valheim.env
```

Edita `valheim.env` con tu editor preferido (`nano valheim.env`):
- Establece un `SERVER_NAME`.
- Establece una contraseña segura en `SERVER_PASS` (mínimo 5 caracteres; no puede coincidir con el nombre).
- Verifica que `PUID` y `PGID` coincidan con tu usuario de Ubuntu (`id -u` e `id -g`, habitualmente `1000`).

---

## 5. Construcción y Despliegue

Construye la imagen ARM64 optimizada para la CPU Ampere Altra (Neoverse N1):

```bash
docker compose -f docker-compose.oracle-arm64.yml build
```

Una vez completada la construcción, inicia el servicio en segundo plano:

```bash
docker compose -f docker-compose.oracle-arm64.yml up -d
```

---

## 6. Monitorización y Diagnósticos

### Ver los logs en tiempo real
```bash
docker compose -f docker-compose.oracle-arm64.yml logs -f
```

Deberías observar:
1. `valheim-bootstrap`: Inicialización y verificación de permisos.
2. `valheim-updater`: Descarga inicial de Valheim desde SteamCMD usando Box86.
3. `valheim-server`: Inicio del binario x86_64 a través de Box64 con `STRONGMEM=2`.
4. Mensaje `Server is now listening on UDP query port 2457`.

### Ejecutar diagnóstico de arquitectura
```bash
docker compose -f docker-compose.oracle-arm64.yml exec valheim valheim-arch-diagnostics
```

### Ejecutar el Smoke Test
```bash
bash tests/oracle-arm64-smoke-test.sh
```

---

## 7. Detener y Apagar de Forma Segura

Para detener el servidor permitiendo que guarde el mundo limpiamente:

```bash
docker compose -f docker-compose.oracle-arm64.yml stop
```

Gracias al parámetro `stop_grace_period: 2m`, Docker otorga hasta 120 segundos para que Unity termine de escribir los archivos `.db` y `.fwl` antes de apagar el contenedor.

---

## 8. Actualización del Servidor

El contenedor cuenta con actualizaciones automáticas periódicas (`UPDATE_CRON`).
Si deseas forzar una actualización manual inmediatamente:

```bash
# Opción A: Enviar señal SIGHUP al actualizador
docker compose -f docker-compose.oracle-arm64.yml exec valheim supervisorctl signal HUP valheim-updater

# Opción B: Reiniciar el servicio completo
docker compose -f docker-compose.oracle-arm64.yml restart
```
