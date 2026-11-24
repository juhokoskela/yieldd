#!/bin/bash
# Run as root on a fresh Ubuntu Noble ARM64 EC2 image builder.
set -euo pipefail
grep -qx VERSION_CODENAME=noble /etc/os-release
[[ $(uname -m) == aarch64 ]]
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-buildx nvme-cli curl git zstd unzip build-essential libicu74
install -d -o ubuntu -g ubuntu /opt/yieldd-runner /opt/hostedtoolcache
usermod -aG docker ubuntu
cd /opt/yieldd-runner
[[ ! -e .runner && ! -e bin ]]
version=2.338.2
curl -fsSL --retry 3 "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-arm64-$version.tar.gz" -o /tmp/yieldd-runner.tgz
echo '670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945  /tmp/yieldd-runner.tgz' | sha256sum -c -
tar -xzf /tmp/yieldd-runner.tgz
rm /tmp/yieldd-runner.tgz
chown -R ubuntu:ubuntu .
cat > /etc/systemd/system/yieldd.slice <<'UNIT'
[Slice]
MemoryMax=12G
MemorySwapMax=0
UNIT
for service in docker containerd; do
    install -d "/etc/systemd/system/$service.service.d"
    printf '[Service]\nSlice=yieldd.slice\n' > "/etc/systemd/system/$service.service.d/yieldd.conf"
done
install -d /etc/docker
echo '{"exec-opts":["native.cgroupdriver=systemd"],"cgroup-parent":"yieldd.slice"}' >/etc/docker/daemon.json
cat >/etc/systemd/system/yieldd-expire.timer <<'UNIT'
[Timer]
OnBootSec=6h
Unit=poweroff.target
[Install]
WantedBy=timers.target
UNIT
cat >/etc/systemd/system/yieldd-idle.timer <<'UNIT'
[Timer]
OnBootSec=10min
[Install]
WantedBy=timers.target
UNIT
cat >/etc/systemd/system/yieldd-idle.service <<'UNIT'
[Unit]
ConditionPathExists=!/run/yieldd-job/start
[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --no-block poweroff
UNIT
printf '#!/bin/sh\nexec touch /run/yieldd-job/start\n' >/usr/local/sbin/yieldd-job-start
chmod 0755 /usr/local/sbin/yieldd-job-start
systemctl daemon-reload
systemctl enable yieldd-idle.timer yieldd-expire.timer docker.service
test -x /usr/local/sbin/yieldd-ec2-job
systemctl stop docker.socket docker.service containerd.service
apt-get clean
rm -f /etc/ssh/ssh_host_* /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys
cloud-init clean --logs --machine-id --seed
sync
