#!/bin/bash
set -euo pipefail
umask 077
trap 'systemctl --no-block poweroff' EXIT
endpoint=$1/v1/ec2/$2
auth="Authorization: Bearer $3"
mode=$4
[[ $(nproc) == 4 ]]
# Nitro assigns NVMe device numbers independently of the requested EBS mapping.
cache_device() {
    local device mapping
    for device in /dev/nvme*n1; do
        [[ -b $device ]] || continue
        mapping=$(nvme id-ctrl --raw-binary "$device" | dd bs=1 skip=3072 count=32 status=none iflag=fullblock | tr -d '\000 ')
        if [[ ${mapping#/dev/} == sdf ]]; then printf '%s\n' "$device"; return 0; fi
    done
    return 1
}
for ((i=0; i<45; i++)); do
    if dev=$(cache_device); then break; fi
    sleep 1
done
[[ -b ${dev:-} && -z $(lsblk -nro MOUNTPOINTS "$dev" | tr -d '[:space:]') ]]
case $mode in
    blank)
        signature=$(wipefs --no-act --noheadings --output TYPE "$dev")
        [[ -z $signature ]]
        mkfs.ext4 -q -L YIELDD_GO_V1 -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 "$dev"
        ;;
    seeded)
        [[ $(blkid -s LABEL -o value "$dev") == YIELDD_GO_V1 ]]
        state=$(LC_ALL=C tune2fs -l "$dev" | awk '/^Filesystem state:/ {print $3}')
        [[ $state == clean ]]
        ;;
    *) exit 1 ;;
esac
cache=/mnt/yieldd
install -d "$cache"
mount -o nodev,nosuid,noatime "$dev" "$cache"
for dir in go-build go-modules tools buildkit; do
    install -d -o ubuntu -g ubuntu -m 0755 "$cache/$dir"
done
mount --bind "$cache/tools" /opt/hostedtoolcache
systemctl start docker.service
[[ $(cat /sys/fs/cgroup/yieldd.slice/memory.max) == 12884901888 ]]
[[ $(docker info -f '{{.CgroupDriver}}') == systemd ]]

# The runner consumes the credential from its process environment. Keep the file on tmpfs.
jit=$(curl -fsS --retry 2 --max-time 45 -X POST -H "$auth" "$endpoint/register")
[[ -n $jit && $jit != *$'\n'* ]]
printf 'ACTIONS_RUNNER_INPUT_JITCONFIG=%s\n' "$jit" > /run/yieldd-jit
unset jit
install -d -o ubuntu -g ubuntu /run/yieldd-job
systemd-run --quiet --wait --collect --unit=yieldd-job --slice=yieldd.slice \
    --uid=ubuntu --gid=ubuntu --property=WorkingDirectory=/opt/yieldd-runner \
    --property=EnvironmentFile=/run/yieldd-jit --setenv=HOME=/home/ubuntu --setenv=ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/sbin/yieldd-job-start.sh \
    --setenv=RUNNER_TOOL_CACHE=/opt/hostedtoolcache --setenv=AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    --setenv=GOCACHE="$cache/go-build" --setenv=GOMODCACHE="$cache/go-modules" \
    /opt/yieldd-runner/run.sh
rm -f /run/yieldd-jit
systemctl stop docker.socket docker.service containerd.service
umount /opt/hostedtoolcache
umount "$cache"
# A clean unmount flushes the EBS disk. The coordinator authorizes promotion.
until_second=$((SECONDS + 60))
while (( SECONDS < until_second )); do
    code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST -H "$auth" "$endpoint/quiesced") || break
    [[ $code == 202 ]] || break
    sleep 2
done
