$ErrorActionPreference = 'Continue'
$wsl = "$env:SystemRoot\System32\wsl.exe"

# 输出服务状态及监听端口，便于现场排查。
& $wsl -d Ubuntu-22.04 -u root -- systemctl --no-pager status ax12-unitree-gateway.service
& $wsl -d Ubuntu-22.04 -u root -- ss -ltnp

