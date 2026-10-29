<#
.SYNOPSIS
允许 AX12 从公用 Wi-Fi 访问 WSL2 中的 WebSocket 网关。

.DESCRIPTION
以管理员身份运行本脚本。脚本分别创建 Windows Defender 防火墙规则和
WSL2/Hyper-V 防火墙规则，仅允许入站 TCP 8765，不开放其他端口。
#>

$ErrorActionPreference = 'Stop'
$ruleName = 'AX12UnitreeGatewayPublic'
$vmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

# Hyper-V 规则负责 mirrored networking 模式下进入 WSL2 虚拟机的流量。
if (-not (Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallHyperVRule `
        -Name $ruleName `
        -DisplayName 'AX12 Unitree WebSocket Gateway (Public)' `
        -Direction Inbound `
        -VMCreatorId $vmCreatorId `
        -Protocol TCP `
        -LocalPorts 8765 `
        -Profiles Public | Out-Null
}

# Windows 规则负责允许同一局域网中的 AX12 访问笔记本 TCP 8765。
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name $ruleName `
        -DisplayName 'AX12 Unitree WebSocket Gateway (Public)' `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 8765 `
        -Profile Public | Out-Null
}

Write-Host 'AX12 Unitree gateway firewall rules are ready.'
