#!/usr/bin/env bash
set -euo pipefail

# WSL 不保证仅因 systemd 服务存在就持续运行；该前台进程让发行版保持活动。
exec 9>/run/lock/ax12-unitree-gateway-keepalive.lock
if ! flock -n 9; then
  exit 0
fi

systemctl start ax12-unitree-gateway.service
trap 'systemctl stop ax12-unitree-gateway.service' EXIT INT TERM

while systemctl is-active --quiet ax12-unitree-gateway.service; do
  sleep 30
done

