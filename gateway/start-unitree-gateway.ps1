$ErrorActionPreference = 'Stop'
$wsl = "$env:SystemRoot\System32\wsl.exe"
$keepalive = '/mnt/d/GitLab/Remote_control/remote/gateway/tools/keepalive.sh'

# 后台保持一个 WSL 会话，避免仅有 systemd 服务时发行版自动休眠。
Start-Process `
    -FilePath $wsl `
    -ArgumentList @('-d', 'Ubuntu-22.04', '-u', 'root', '--', 'bash', $keepalive) `
    -WindowStyle Hidden

Start-Sleep -Seconds 3
Write-Host 'AX12 Unitree gateway requested at ws://0.0.0.0:8765'

