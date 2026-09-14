FROM debian:trixie-slim AS build-env
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG TESTS
ARG SOURCE_COMMIT
ARG BUSYBOX_VERSION=1.36.1
ARG BUSYBOX_SHA256=b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314
ARG SUPERVISOR_VERSION=4.2.5
ARG GO_VERSION=1.24.1
ARG PYTHON_A2S_VERSION=1.4.1

RUN apt-get update
RUN apt-get -y install apt-utils
RUN apt-get -y install build-essential curl git python3 python3-pip python3-venv shellcheck

# Install Go 1.24 manually according to TARGETARCH (amd64 or arm64)
RUN ARCH="${TARGETARCH:-amd64}" \
    && curl -L -o /tmp/go${GO_VERSION}.linux-${ARCH}.tar.gz https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz \
    && tar -C /usr/local -xzf /tmp/go${GO_VERSION}.linux-${ARCH}.tar.gz \
    && rm /tmp/go${GO_VERSION}.linux-${ARCH}.tar.gz
ENV PATH=$PATH:/usr/local/go/bin
ENV GOPATH=/go
ENV PATH=$PATH:$GOPATH/bin

WORKDIR /build/busybox
COPY ./busybox.config /build/busybox/.config
RUN set -eu; \
    if [ "${TARGETARCH:-amd64}" != "amd64" ] && [ "${TARGETARCH:-amd64}" != "386" ]; then \
        sed -i 's/CONFIG_STACK_OPTIMIZATION_386=y/# CONFIG_STACK_OPTIMIZATION_386 is not set/' /build/busybox/.config; \
    fi; \
    for base in \
        https://sources.buildroot.net/busybox \
        https://downloads.yoctoproject.org/mirror/sources \
        https://busybox.net/downloads; do \
        echo "Fetching busybox-${BUSYBOX_VERSION}.tar.bz2 from ${base}"; \
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
            -o /tmp/busybox.tar.bz2 "${base}/busybox-${BUSYBOX_VERSION}.tar.bz2" && break || true; \
    done; \
    echo "${BUSYBOX_SHA256}  /tmp/busybox.tar.bz2" | sha256sum -c -; \
    tar xjf /tmp/busybox.tar.bz2 --strip-components=1 -C /build/busybox; \
    make olddefconfig; \
    make -j"$(nproc)"; \
    cp busybox /usr/local/bin/

WORKDIR /build/env2cfg
COPY ./env2cfg/ /build/env2cfg/
RUN if [ "${TESTS:-true}" = true ]; then \
    python3 -m venv ../env2cfg.tests.venv \
    && ../env2cfg.tests.venv/bin/pip3 install tox~=4.28.4 \
    && ../env2cfg.tests.venv/bin/tox \
    ; \
    fi

WORKDIR /build/valheim-logfilter
COPY ./valheim-logfilter/ /build/valheim-logfilter/
RUN if [ "${TESTS:-true}" = true ]; then \
    go test ./... \
    ; \
    fi
RUN go build -ldflags="-s -w" \
    && mv valheim-logfilter /usr/local/bin/

WORKDIR /build
COPY bootstrap /usr/local/sbin/
COPY valheim-tests /usr/local/bin/
COPY valheim-status /usr/local/bin/
COPY valheim-is-idle /usr/local/bin/
COPY valheim-bootstrap /usr/local/bin/
COPY valheim-backup /usr/local/bin/
COPY valheim-updater /usr/local/bin/
COPY valheim-plus-updater /usr/local/bin/
COPY bepinex-updater /usr/local/bin/
COPY valheim-server /usr/local/bin/
COPY valheim-arch-diagnostics /usr/local/bin/
COPY steamcmd-wrapper /usr/local/bin/
COPY valheim-wrapper /usr/local/bin/
COPY defaults /usr/local/etc/valheim/
COPY common /usr/local/etc/valheim/
COPY contrib/* /usr/local/share/valheim/contrib/
RUN chmod 755 /usr/local/sbin/bootstrap /usr/local/bin/valheim-* /usr/local/bin/steamcmd-wrapper
RUN if [ "${TESTS:-true}" = true ]; then \
    shellcheck -a -x -s bash -e SC2034 \
    /usr/local/sbin/bootstrap \
    /usr/local/bin/valheim-tests \
    /usr/local/bin/valheim-backup \
    /usr/local/bin/valheim-is-idle \
    /usr/local/bin/valheim-bootstrap \
    /usr/local/bin/valheim-server \
    /usr/local/bin/valheim-updater \
    /usr/local/bin/valheim-plus-updater \
    /usr/local/bin/bepinex-updater \
    /usr/local/bin/valheim-arch-diagnostics \
    /usr/local/bin/steamcmd-wrapper \
    /usr/local/bin/valheim-wrapper \
    /usr/local/share/valheim/contrib/*.sh \
    ; \
    fi
WORKDIR /
RUN rm -rf /usr/local/lib/
# Debian's pip is modded to install to /usr/local by default.
# Freezes an old version of Setuptools to prevent a flood of deprecation
# notices while supervisor still uses it. Setuptools dependency can be removed
# when supervisor>=4.3.0 is released
RUN pip3 install --break-system-packages \
    python-a2s==${PYTHON_A2S_VERSION} \
    supervisor==${SUPERVISOR_VERSION} \
    "Setuptools<67.5.0" \
    /build/env2cfg
COPY supervisord.conf /usr/local/etc/supervisord.conf
RUN mkdir -p /usr/local/etc/supervisor/conf.d/ \
    && chmod 640 /usr/local/etc/supervisord.conf
RUN echo "${SOURCE_COMMIT:-unknown}" > /usr/local/etc/git-commit.HEAD


FROM debian:trixie-slim AS box64-builder
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG BOX64_VERSION=v0.4.4
ARG BOX64_TARGET=ARM64
RUN mkdir -p /install/usr/local/bin /install/etc; \
    if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
        apt-get update && apt-get -y --no-install-recommends install \
            build-essential cmake git ca-certificates \
        && git clone --depth 1 --branch "${BOX64_VERSION}" https://github.com/ptitSeb/box64.git /build/box64 \
        && cd /build/box64 \
        && mkdir build && cd build \
        && cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -D${BOX64_TARGET}=ON -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        && make -j"$(nproc)" \
        && make install DESTDIR=/install \
        && if [ ! -f /install/usr/local/bin/box64 ] && [ -f /install/usr/bin/box64 ]; then \
               cp /install/usr/bin/box64 /install/usr/local/bin/; \
           fi; \
    fi


FROM debian:trixie-slim AS box86-builder
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
ARG BOX86_VERSION=v0.3.8
ARG BOX86_TARGET=ARM64
RUN mkdir -p /install/usr/local/bin; \
    if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
        dpkg --add-architecture armhf \
        && apt-get update && apt-get -y --no-install-recommends install \
            build-essential cmake git ca-certificates gcc-arm-linux-gnueabihf libc6-dev:armhf \
        && git clone --depth 1 --branch "${BOX86_VERSION}" https://github.com/ptitSeb/box86.git /build/box86 \
        && cd /build/box86 \
        && mkdir build && cd build \
        && cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -D${BOX86_TARGET}=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        && make -j"$(nproc)" \
        && make install DESTDIR=/install \
        && if [ ! -f /install/usr/local/bin/box86 ] && [ -f /install/usr/bin/box86 ]; then \
               cp /install/usr/bin/box86 /install/usr/local/bin/; \
           fi; \
    fi


FROM debian:trixie-slim AS i386-libs
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
RUN mkdir -p /install/lib /install/lib/i386-linux-gnu /install/usr/lib/i386-linux-gnu; \
    if [ "${TARGETARCH:-amd64}" = "amd64" ]; then \
        dpkg --add-architecture i386 \
        && apt-get update \
        && apt-get -y --no-install-recommends install \
            libc6:i386 \
            libstdc++6:i386 \
            libsdl2-2.0-0:i386 \
            libcurl4:i386 \
        && cp -a /lib/ld-linux.so.2 /install/lib/ 2>/dev/null || true \
        && cp -a /lib/i386-linux-gnu/* /install/lib/i386-linux-gnu/ 2>/dev/null || true \
        && cp -a /usr/lib/i386-linux-gnu/* /install/usr/lib/i386-linux-gnu/ 2>/dev/null || true; \
    fi


FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
COPY --from=build-env /usr/local/ /usr/local/
COPY --from=box64-builder /install/ /
COPY --from=box86-builder /install/ /
COPY --from=i386-libs /install/ /
COPY fake-supervisord /usr/bin/supervisord
COPY box64.box64rc /etc/box64.box64rc

RUN groupadd -g "${PGID:-0}" -o valheim \
    && useradd -g "${PGID:-0}" -u "${PUID:-0}" -o --create-home valheim \
    && if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
        dpkg --add-architecture armhf; \
    fi \
    && apt-get update \
    && apt-get -y --no-install-recommends install apt-utils \
    && apt-get -y dist-upgrade \
    && apt-get -y --no-install-recommends install \
    libc6-dev \
    libsdl2-2.0-0 \
    curl \
    iproute2 \
    libcurl4 \
    ca-certificates \
    procps \
    locales \
    unzip \
    zip \
    rsync \
    openssh-client \
    jq \
    python3-minimal \
    python3-pkg-resources \
    python3-setuptools \
    libpulse-dev \
    libatomic1 \
    libc6 \
    tini \
    file \
    && if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
        apt-get -y --no-install-recommends install \
            libc6:armhf \
            libstdc++6:armhf \
            libcurl4:armhf \
            libsdl2-2.0-0:armhf; \
    fi \
    && echo 'LANG="en_US.UTF-8"' > /etc/default/locale \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && rm -f /bin/sh \
    && ln -s /bin/bash /bin/sh \
    && locale-gen \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3 1 \
    && apt-get clean \
    && mkdir -p /var/spool/cron/crontabs /var/log/supervisor /opt/valheim /opt/steamcmd /home/valheim/.config/unity3d/IronGate /config /var/run/valheim \
    && ln -s /config /home/valheim/.config/unity3d/IronGate/Valheim \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bc \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bunzip2 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bzcat \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bzip2 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/crontab \
    && ln -s /usr/local/bin/busybox /usr/local/bin/httpd \
    && ln -s /usr/local/bin/busybox /usr/local/bin/iostat \
    && ln -s /usr/local/bin/busybox /usr/local/bin/killall \
    && ln -s /usr/local/bin/busybox /usr/local/bin/less \
    && ln -s /usr/local/bin/busybox /usr/local/bin/lsof \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ping \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ping6 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/setuidgid \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ssl_client \
    && ln -s /usr/local/bin/busybox /usr/local/bin/traceroute \
    && ln -s /usr/local/bin/busybox /usr/local/bin/traceroute6 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/unxz \
    && ln -s /usr/local/bin/busybox /usr/local/bin/vi \
    && ln -s /usr/local/bin/busybox /usr/local/bin/wget \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xz \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xzcat \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xxd \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/crond \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/mkpasswd \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/syslogd \
    && curl -L -o /tmp/steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    && tar xzvf /tmp/steamcmd_linux.tar.gz -C /opt/steamcmd/ \
    && chown -R valheim:valheim /var/run/valheim \
    && chown -R root:root /opt/steamcmd \
    && chmod u=rwx,go=rx /opt/steamcmd/steamcmd.sh \
    /opt/steamcmd/linux32/steamcmd \
    /opt/steamcmd/linux32/steamerrorreporter \
    /usr/bin/supervisord \
    /usr/local/bin/steamcmd-wrapper \
    /usr/local/bin/valheim-wrapper \
    /usr/local/bin/valheim-arch-diagnostics \
    && cd "/opt/steamcmd" \
    && su - valheim -c "/usr/local/bin/steamcmd-wrapper +login anonymous +quit || true" \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && date --utc --iso-8601=seconds > /usr/local/etc/build.date

EXPOSE 2456-2458/udp
EXPOSE 9001/tcp
EXPOSE 80/tcp
WORKDIR /
CMD ["/usr/local/sbin/bootstrap"]
