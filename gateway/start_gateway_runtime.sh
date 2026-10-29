#!/usr/bin/env bash
set -euo pipefail

# AX12 App 通过 Windows 192.168.0.124:8765 端口转发访问此地址。
cd /mnt/d/GitLab/Remote_control/remote/gateway

export PYTHONPATH=.
export GATEWAY_HOST=198.18.0.1
export GATEWAY_PORT=18765
export GATEWAY_TOKEN=
export UNITREE_DRIVER=go2
export UNITREE_INTERFACE=eth0
export DEADMAN_TIMEOUT=0.5
export MAX_VX=0.8
export MAX_VY=0.5
export MAX_VYAW=1.5
export MAX_PITCH=0.3

exec /home/lbchun/.venvs/unitree-gateway/bin/python -m gateway.server
