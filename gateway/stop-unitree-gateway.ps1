$ErrorActionPreference = 'Continue'
$wsl = "$env:SystemRoot\System32\wsl.exe"

# 停止服务并终止该发行版，使 keepalive 会话随之结束。
& $wsl -d Ubuntu-22.04 -u root -- systemctl stop ax12-unitree-gateway.service
& $wsl --terminate Ubuntu-22.04
Write-Host 'AX12 Unitree gateway stopped.'

