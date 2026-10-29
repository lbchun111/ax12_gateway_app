<#
.SYNOPSIS
允许 WSL2 通过 Go2 专用有线网段接收 CycloneDDS UDP 流量。

.DESCRIPTION
规则只接受来源为 192.168.123.0/24 的 UDP，并且 Windows 层进一步限定到
“以太网 3”。不改变默认防火墙策略，也不开放 Wi-Fi 来源的 UDP。
#>

$ErrorActionPreference = 'Stop'
$ruleName = 'AX12UnitreeDDSPublic'
$vmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$robotSubnet = '192.168.123.0/24'

# WSL2 mirrored networking 有独立的 Hyper-V 防火墙，必须单独允许 DDS 入站。
if (-not (Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallHyperVRule `
        -Name $ruleName `
        -DisplayName 'Unitree Go2 CycloneDDS UDP (Robot LAN)' `
        -Direction Inbound `
        -VMCreatorId $vmCreatorId `
        -Protocol UDP `
        -RemoteAddresses $robotSubnet `
        -Profiles Public `
        -Action Allow | Out-Null
}

# Windows 主机防火墙仅在连接 Go2 的物理网卡上接受同一机器人子网的 UDP。
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name $ruleName `
        -DisplayName 'Unitree Go2 CycloneDDS UDP (Robot LAN)' `
        -Direction Inbound `
        -Action Allow `
        -Protocol UDP `
        -RemoteAddress $robotSubnet `
        -InterfaceAlias '以太网 3' `
        -Profile Public | Out-Null
}

Write-Host 'Unitree Go2 CycloneDDS firewall rules are ready.'
