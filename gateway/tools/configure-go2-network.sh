#!/usr/bin/env bash
# 为连接 Go2 的 WSL2 有线接口配置专用静态地址。
# 该配置不创建默认网关、不修改 DNS，因此不会替换 Wi-Fi 上网路由。

set -euo pipefail

readonly interface_name="${1:-eth1}"
readonly linux_address="${2:-192.168.123.99/24}"
readonly service_path="/etc/systemd/system/go2-network.service"

# 防止接口名称拼接到 systemd 配置时引入非预期字符。
if [[ ! "${interface_name}" =~ ^[a-zA-Z0-9_.:-]+$ ]]; then
  echo "非法接口名称: ${interface_name}" >&2
  exit 2
fi

# 只有系统中确实存在目标网卡时才写入永久配置。
if ! /usr/sbin/ip link show dev "${interface_name}" >/dev/null 2>&1; then
  echo "接口不存在: ${interface_name}" >&2
  exit 3
fi

# oneshot 服务在每次 WSL2/systemd 启动后恢复地址；RemainAfterExit 记录配置状态。
/usr/bin/install -m 0644 /dev/stdin "${service_path}" <<EOF
[Unit]
Description=Go2 dedicated IPv4 address on ${interface_name}
After=network-pre.target
Before=ax12-unitree-gateway.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set dev ${interface_name} up
# WSL mirrored networking 会把 Windows 无 DHCP 时的 169.254/16 地址复制进来；
# CycloneDDS 可能优先选中它。专用 Go2 网卡无需 APIPA，因此启动时清除 IPv4 link scope。
ExecStart=/usr/sbin/ip -4 address flush dev ${interface_name} scope link
ExecStart=/usr/sbin/ip address replace ${linux_address} dev ${interface_name}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable go2-network.service
/usr/bin/systemctl restart go2-network.service

echo "Go2 network configured: ${interface_name} = ${linux_address}"
/usr/sbin/ip -4 address show dev "${interface_name}"
/usr/sbin/ip -4 route show
