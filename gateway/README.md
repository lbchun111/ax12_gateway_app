# AX12 → Unitree WebSocket 网关

该网关运行在 Windows 11 的 WSL2 Ubuntu 中。AX12 Android App 只处理遥控器输入和 WebSocket；本目录负责安全校验、动作映射及 `unitree_sdk2_python` 调用。

## 快速验证（无机器人）

```bash
cd /mnt/d/GitLab/Remote_control/remote/gateway
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
PYTHONPATH=. python -m unittest discover -s tests -v
PYTHONPATH=. python -m gateway.server --driver mock
```

App 中选择“宇树网关”，地址填写笔记本局域网 IP，端口填写 `8765`。连接后先点“解锁”，再操作摇杆；“急停”会清零速度并重新锁定。

## 当前 Windows/WSL2 部署

本机已安装 `Ubuntu-22.04`、CycloneDDS、`unitree_sdk2_python` 和 Python 虚拟环境
`/home/lbchun/.venvs/unitree-gateway`。网关作为 systemd 服务
`ax12-unitree-gateway.service` 运行，当前安全地使用 `mock` 驱动。

Windows 登录后可在 PowerShell 中执行：

```powershell
.\gateway\start-unitree-gateway.ps1
.\gateway\status-unitree-gateway.ps1
```

需要停止时执行：

```powershell
.\gateway\stop-unitree-gateway.ps1
```

App 当前使用 `ws://192.168.0.124:8765`。若笔记本 Wi-Fi 地址变化，应同步修改 App
中的“网关 IP”。Windows 网络被识别为公用网络时，必须保留 TCP 8765 的 Windows
防火墙与 Hyper-V 防火墙入站规则。如需在另一台笔记本重建规则，请用管理员
PowerShell 执行：

```powershell
.\gateway\tools\configure-windows-firewall.ps1
```

## Go2 实机

官方 SDK 要求 Python 3.8+、CycloneDDS 0.10.2，并在初始化时指定连接机器人的网络接口。安装官方仓库后运行：

本机 Go2 专用网络已经配置为：

| 项目 | 值 |
|---|---|
| Go2 SDK 地址 | `192.168.123.161` |
| Go2 EDU 机载计算机 | `192.168.123.18` |
| WSL2 有线接口 | `eth1` |
| WSL2 专用地址 | `192.168.123.99/24` |
| 默认网关 | 不设置，继续使用现有 Wi-Fi |

配置由 `go2-network.service` 在 WSL2 启动时恢复。如需重建，可在 Ubuntu root
环境执行：

```bash
./gateway/tools/configure-go2-network.sh eth1 192.168.123.99/24
```

插入连接 Go2 的网线后，先验证：

```bash
ip -br address show eth1
ping -c 3 192.168.123.161
```

该服务还会从 WSL 的 Go2 专用网卡移除 Windows 镜像进来的 `169.254/16` APIPA
地址，确保 CycloneDDS 使用 `192.168.123.99`。Windows 与 Hyper-V 防火墙需要
允许来自 `192.168.123.0/24` 的 UDP；项目提供的规则只对“以太网 3”和该子网生效。

```bash
export UNITREE_DRIVER=go2
export UNITREE_INTERFACE=eth1
export GATEWAY_TOKEN='请替换为随机长字符串'
source .venv/bin/activate
PYTHONPATH=. python -m gateway.server
```

实机首次测试必须架空机器人或留出安全空间。网关默认锁定，速度上限为 `0.8/0.5/1.5`，500 ms 无运动更新自动停止；断开 App 后也应按现场流程执行急停。

修改 `/etc/ax12-unitree-gateway.env` 后重启服务：

```bash
sudo systemctl restart ax12-unitree-gateway
sudo journalctl -u ax12-unitree-gateway -f
```

在未确认机器人型号、机器人网口名称和现场急停流程前，不要把 `UNITREE_DRIVER`
从 `mock` 改为 `go2`。

## AX12 默认控制映射

| AX12 控件 | Go2 动作 |
|---|---|
| SA/SB/SC/SD/SE/SF/6POS | 只监视，不直接控制机器人 |
| 左纵 / Throttle | 前后速度 `vx` |
| 右横 / Roll | 横移速度 `vy` |
| 左横 / Yaw | 旋转速度 `vyaw` |
| T1 / T2 | 站起 / 趴下 |
| T3 / T4 | 平衡站立 / 恢复站立 |

姿态动作必须先由 App 的“解锁”按钮解锁。网关会在姿态变化前清零内部速度；
趴下和阻尼模式完成后自动重新锁定。阻尼模式只接受 App 明确发送的 `damp` 命令。
拨杆通道不参与机器人控制，避免摇杆帧中的 SRC20–SRC25 快照抖动造成停止、锁定或
姿态误动作。右纵 / Pitch 当前保留，后续可映射
机身高度或其他厂商能力。

真实 Go2 驱动使用 `SportClient(enableLease=True)` 申请 `sport_lease`。网关只有在
获得非零租约 ID 后才报告机器人在线，避免 `Move()` 以 `leaseId=0` 发布后被固件
静默忽略。App 点击“解锁”后还会关闭内置摇杆；急停、趴下、阻尼或断开时恢复。
非零三轴速度由网关按20毫秒周期（50Hz）持续发布；若超过配置的deadman时间没有
收到新输入，网关立即发布零速度，防止连接中断后继续运动。

## 扩展其他宇树型号

在 `gateway/drivers/` 新建 `RobotDriver` 实现，并在 `create_driver()` 注册。WebSocket 协议、Android App、解锁与 deadman 逻辑无需修改。

