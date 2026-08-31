FROM ubuntu:24.04

ENV container=container

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dbus \
        docker.io \
        git \
        jq \
        systemd \
        systemd-sysv \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/dbus \
    && : > /etc/machine-id \
    && : > /var/lib/dbus/machine-id \
    && systemctl set-default multi-user.target \
    && systemctl mask \
        console-getty.service \
        dev-hugepages.mount \
        sys-fs-fuse-connections.mount \
        systemd-tmpfiles-setup.service \
        systemd-update-utmp.service \
    && systemctl enable containerd.service docker.service \
    && useradd --create-home --shell /bin/bash runner \
    && usermod --append --groups docker runner \
    && test "$(readlink -f /sbin/init)" = "$(readlink -f /lib/systemd/systemd)"

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
