FROM ubuntu:24.04

ENV container=container

ARG ACTIONS_RUNNER_VERSION=2.337.0
ARG ACTIONS_RUNNER_SHA256=9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dbus \
        docker.io \
        git \
        jq \
        sudo \
        systemd \
        systemd-sysv \
        libatomic1 \
        build-essential \
        docker-compose-v2 \
    && mkdir -p /opt/actions-runner \
    && curl --fail --location --retry 3 \
        --output /tmp/actions-runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${ACTIONS_RUNNER_VERSION}/actions-runner-linux-arm64-${ACTIONS_RUNNER_VERSION}.tar.gz" \
    && echo "${ACTIONS_RUNNER_SHA256}  /tmp/actions-runner.tar.gz" | sha256sum --check --strict \
    && tar --extract --gzip --file /tmp/actions-runner.tar.gz --directory /opt/actions-runner \
    && /opt/actions-runner/bin/installdependencies.sh \
    && rm -f /tmp/actions-runner.tar.gz \
    && rm -rf /var/lib/apt/lists/*

COPY configure-runner /usr/local/bin/yieldd-configure-runner
COPY runner-control /usr/local/bin/yieldd-runner-control
COPY yieldd.slice /etc/systemd/system/yieldd.slice
COPY docker-daemon.json /etc/docker/daemon.json
COPY runner.sudoers /etc/sudoers.d/runner

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
    && chmod 0440 /etc/sudoers.d/runner \
    && visudo --check \
    && test "$(runuser --user runner -- sudo --non-interactive id -u)" = 0 \
    && chown -R runner:runner /opt/actions-runner \
    && chmod 0755 \
        /usr/local/bin/yieldd-configure-runner \
        /usr/local/bin/yieldd-runner-control \
    && bash -n \
        /usr/local/bin/yieldd-configure-runner \
        /usr/local/bin/yieldd-runner-control \
    && jq --exit-status . /etc/docker/daemon.json >/dev/null \
    && systemd-analyze verify /etc/systemd/system/yieldd.slice \
    && test "$(readlink -f /sbin/init)" = "$(readlink -f /lib/systemd/systemd)"

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
