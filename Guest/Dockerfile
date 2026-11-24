FROM mcr.microsoft.com/dotnet/sdk:8.0.427-bookworm-slim@sha256:341aa6e8bbaceb1194732328ca27c15bfa9c531687db83a66af3c0c1833f5534 AS worker
COPY actions-runner/ /src/
RUN bash /src/build.sh linux-arm64 /opt/actions-runner

FROM ubuntu:24.04

ENV container=container

ARG GH_VERSION=2.102.1
ARG GH_SHA256=5019b3cc6e8a03bb4d88600f8dbda2add8e6407705c159b0c63151036e77a1af

COPY --from=worker /opt/actions-runner /opt/actions-runner

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
        zstd \
    && /opt/actions-runner/bin/installdependencies.sh \
    && curl --fail --location --retry 3 \
        --output /tmp/gh.tar.gz \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_arm64.tar.gz" \
    && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum --check --strict \
    && tar --extract --gzip --file /tmp/gh.tar.gz --directory /usr/local --strip-components=1 \
        "gh_${GH_VERSION}_linux_arm64/bin/gh" \
    && rm -f /tmp/gh.tar.gz \
    && rm -rf /var/lib/apt/lists/*

COPY configure-runner /usr/local/bin/yieldd-configure-runner
COPY runner-control /usr/local/bin/yieldd-runner-control
COPY yieldd.slice /etc/systemd/system/yieldd.slice
COPY docker-daemon.json /etc/docker/daemon.json
COPY runner.sudoers /etc/sudoers.d/runner
COPY fstab /etc/fstab

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
    && findmnt --verify --tab-file /etc/fstab \
    && test "$(gh --version | head -n 1 | cut -d ' ' -f 3)" = "$GH_VERSION" \
    && systemd-analyze verify /etc/systemd/system/yieldd.slice \
    && test "$(readlink -f /sbin/init)" = "$(readlink -f /lib/systemd/systemd)"

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
