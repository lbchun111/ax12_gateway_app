# AX12 对接宇树 Go2 SDK 开发文档
 
> 机器人：Unitree Go2 EDU  
> Android 设备：RadioMaster AX12（Android 9）  
> SDK：`unitree_sdk2_python` + CycloneDDS  
> 文档依据：2026-10-29 当前项目代码

## 1. 文档目的

本文说明 AX12 遥控器如何通过 Android App 和笔记本 Python 网关调用宇树 Go2 SDK，包括：

- 系统架构和数据流；
- SDK 安装、网络和运行配置；
- AX12 摇杆、按钮到 Go2 动作的映射；
- 当前使用的 `SportClient` 方法及参数；
- App 与网关之间的 WebSocket JSON 协议；
- 控制租约、持续速度发布、死区和失联保护；
- 常见错误和排查步骤；
- 后续扩展新按钮、新动作和其他宇树型号的方法。

本文以当前工程实际实现为准。宇树官方示例仅作为 SDK 能力和接口签名的参考。

## 2. 系统架构

```text
AX12 物理摇杆/按钮
        │ UMBUS 串口帧
        ▼
AX12 Android Flutter App
  ├─ 解析 AX12 通道
  ├─ 通道值归一化为 [-1, 1]
  ├─ 映射为 throttle / roll / yaw / pitch / 姿态动作
  └─ WebSocket JSON
        │ Wi-Fi，TCP 8765
        ▼
Windows 11 笔记本
  └─ WSL2 Ubuntu 22.04
      └─ Python 网关
          ├─ WebSocket 服务
          ├─ 解锁和安全状态机
          ├─ 50 Hz Move 发布器
          └─ unitree_sdk2_python
                 │ CycloneDDS
                 ▼
              Go2 Sport 服务
```

关键结论：

1. AX12 App **不直接调用** `unitree_sdk2_python`。
2. Python 网关是 App 协议与宇树 DDS/Sport API 之间的适配层。
3. App 显示“网关已连接”不等于机器人在线；必须同时检查 `robot.connected=true`。
4. 当前稳定路径是“AX12 → WebSocket 网关 → CycloneDDS → Go2”，Android DDS 直连不是当前生产控制路径。

## 3. 官方 SDK 与依赖

官方资料：

- Python SDK：<https://github.com/unitreerobotics/unitree_sdk2_python>
- C++ SDK：<https://github.com/unitreerobotics/unitree_sdk2>
- Go2 Python 高层运动示例：<https://github.com/unitreerobotics/unitree_sdk2_python/blob/master/example/go2/high_level/go2_sport_client.py>
- Go2 `SportClient` C++ 接口：<https://github.com/unitreerobotics/unitree_sdk2/blob/main/include/unitree/robot/go2/sport/sport_client.hpp>

官方 Python SDK 当前声明的主要依赖为：

- Python 3.8 或更高版本；
- CycloneDDS 0.10.2；
- NumPy；
- OpenCV Python。

当前工程的 WebSocket 层另外使用：

```text
websockets==12.0
```

安装 SDK 的参考命令：

```bash
sudo apt update
sudo apt install -y python3-pip python3-venv git cmake build-essential

git clone https://github.com/unitreerobotics/unitree_sdk2_python.git
cd unitree_sdk2_python
pip3 install -e .
```

如果安装时提示找不到 CycloneDDS，应先按官方 README 编译 `releases/0.10.x`，设置 `CYCLONEDDS_HOME` 后再安装 Python SDK。

## 4. 当前网络配置

当前项目使用的默认参数：

| 项目 | 当前值 | 说明 |
| --- | --- | --- |
| Go2 SDK 地址 | `192.168.123.161` | 用于状态展示和网络诊断 |
| Go2 EDU 机载计算机 | `192.168.123.18` | 不等同于 Sport SDK 服务地址 |
| WSL2 DDS 网卡 | `eth1` | 必须换成实际连 Go2 的 Linux 网卡名 |
| WSL2 有线地址 | `192.168.123.99/24` | 不配置默认网关，不影响笔记本 Wi-Fi 上网 |
| WebSocket 监听 | `0.0.0.0:8765` | AX12 通过笔记本 Wi-Fi IP 连接 |
| App 示例地址 | `ws://192.168.0.124:8765` | 笔记本 Wi-Fi IP 变化时需要更新 |

检查 Linux 网卡：

```bash
ip -br address
ip route
```

检查 Go2 网络：

```bash
ping -c 3 192.168.123.161
```

`ping` 失败不能单独证明 DDS 不可用，但如果同时出现 Sport 服务发现失败，应优先检查网线、IP、Windows/Hyper-V 防火墙和 `UNITREE_INTERFACE`。

## 5. 网关配置

网关从环境变量读取配置：

| 环境变量 | 默认值 | 用途 |
| --- | ---: | --- |
| `GATEWAY_HOST` | `0.0.0.0` | WebSocket 监听地址 |
| `GATEWAY_PORT` | `8765` | WebSocket 端口 |
| `GATEWAY_TOKEN` | 空 | 可选共享令牌 |
| `UNITREE_DRIVER` | `mock` | `mock` 或 `go2` |
| `UNITREE_INTERFACE` | 空 | CycloneDDS 使用的 Linux 网卡 |
| `DEADMAN_TIMEOUT` | `0.5` | 摇杆命令失联保护时间，单位秒 |
| `MAX_VX` | `0.8` | 最大前后速度，单位 m/s |
| `MAX_VY` | `0.5` | 最大横移速度，单位 m/s |
| `MAX_VYAW` | `1.5` | 最大偏航角速度，单位 rad/s |
| `MAX_PITCH` | `0.3` | 最大机身俯仰角，单位 rad |

实机配置示例：

```bash
export UNITREE_DRIVER=go2
export UNITREE_INTERFACE=eth1
export GATEWAY_HOST=0.0.0.0
export GATEWAY_PORT=8765
export DEADMAN_TIMEOUT=0.5
export MAX_VX=0.8
export MAX_VY=0.5
export MAX_VYAW=1.5
export MAX_PITCH=0.3
```

不要在文档或代码仓库中保存真实 `GATEWAY_TOKEN`。

## 6. SDK 初始化流程

当前 `Go2RobotDriver.connect()` 的实际流程如下：

```text
ChannelFactoryInitialize(0, UNITREE_INTERFACE)
→ SportClient(enableLease=True)
→ SetTimeout(2.0)
→ Init()
→ 最多等待 5 秒取得非零 leaseId
→ 循环调用 GetServerApiVersion() 验证 Sport 服务
→ 成功后 robot.connected=true
```

### 6.1 `ChannelFactoryInitialize(domain_id, interface)`

初始化 SDK2 的 DDS 通信工厂。

- `domain_id`：当前使用 `0`；
- `interface`：必须是连接 Go2 所在网络的 Linux 网卡，例如 `eth1`；
- 当前代码只初始化一次，断线重连时只重新创建 `SportClient`。

### 6.2 `SportClient(enableLease=True)`

创建 Go2 高层运动客户端，并启用 Sport 控制租约。

租约非常重要：当前 Go2 固件在 `leaseId=0` 时可能静默忽略无需响应的 `Move` 指令，因此网关只有取得非零租约后才把机器人标记为可控。

### 6.3 `SetTimeout(2.0)`

设置 RPC 调用超时为 2 秒。超时只影响需要响应的 Sport RPC，不替代应用层的 0.5 秒 deadman 安全保护。

### 6.4 `Init()`

注册 Sport 服务需要使用的 API，并启动客户端。`Init()` 返回不代表机器人一定在线，仍需通过租约和 `GetServerApiVersion()` 验证。

### 6.5 `GetLeaseId()`

读取当前 Sport 控制租约 ID。

- 非零：租约已经取得；
- 持续为零：网关报告“Go2 Sport 控制租约申请超时”；
- 常见原因：已有其他控制端占用、Sport 服务未发现、DDS 网卡错误或组播被阻断。

### 6.6 `GetServerApiVersion()`

通过真实 Sport RPC 判断服务是否可调用，而不是只依赖 `ping`。

- 返回码 `0`：服务在线；
- 连接阶段持续失败：机器人保持离线；
- 连接后偶发诊断超时：当前实现保留客户端，实际动作返回值再决定是否断线。

## 7. 当前使用的 SportClient 方法

### 7.1 `Move(vx, vy, vyaw)`

发送三轴速度：

| 参数 | 含义 | 当前来源 | 当前限幅 |
| --- | --- | --- | ---: |
| `vx` | 前进/后退速度，正值前进 | 左纵 `Throttle / SRC02` | `±0.8 m/s` |
| `vy` | 左右横移速度 | 右横 `Roll / SRC03` | `±0.5 m/s` |
| `vyaw` | 左转/右转角速度 | 左横 `Yaw / SRC00` | `±1.5 rad/s` |

计算公式：

```text
vx   = throttle × MAX_VX
vy   = roll     × MAX_VY
vyaw = yaw      × MAX_VYAW
```

当前网关在解锁后以 20 ms 周期，即 50 Hz，持续调用 `Move()`。App 只更新目标值，不承担稳定的 DDS 发布时序。

### 7.2 `Move(0.0, 0.0, 0.0)`

当前项目使用零速度 `Move` 作为停止动作。这样做是为了规避部分固件中 `StopMove()` 偶发返回 3104 的问题。

### 7.3 `SwitchJoystick(flag)`

切换 Go2 内置摇杆控制权：

- 网关取得外部控制权：`SwitchJoystick(False)`；
- 网关释放外部控制权：`SwitchJoystick(True)`。

代码中的 `set_external_control(enabled)` 会使用 `SwitchJoystick(not enabled)`，不要把布尔含义写反。

### 7.4 `RecoveryStand()`

恢复到可运动的稳定站立状态。当前点击“解锁”时会：

```text
取得外部控制权
→ RecoveryStand()
→ 清零三个速度轴
→ armed=true
```

因此“解锁”不仅修改软件状态，还会调用机器人姿态接口。

### 7.5 `StandUp()`

普通站起。当前对应：

- App 手动“站起”按钮；
- T1 / TRIM0。

必须先解锁。

### 7.6 `StandDown()`

趴下。执行成功后网关会释放外部控制权并重新锁定。

当前对应：

- App 手动“趴下”按钮；
- T2 / TRIM1。

### 7.7 `BalanceStand()`

进入平衡站立状态。当前对应 T3 / TRIM2 和手动测试动作。

### 7.8 `Damp()`

进入阻尼模式。执行成功后自动释放外部控制权并锁定。该动作有明显安全影响，只允许通过白名单动作调用。

### 7.9 `Euler(roll, pitch, yaw)`

设置机身欧拉角。当前只开放右纵摇杆控制俯仰：

```text
Euler(0.0, normalizedPitch × MAX_PITCH, 0.0)
```

默认最大俯仰角为 `0.3 rad`。必须先解锁。

## 8. AX12 控件映射

当前 Flutter `ControlRouter.defaultBindings`：

| AX12 输入 | 通道 | action | Go2 行为 |
| --- | ---: | --- | --- |
| 左横 Yaw | SRC00 | `yaw` | `Move` 的 `vyaw` |
| 右纵 Pitch | SRC01 | `pitch` | `Euler` 的 pitch |
| 左纵 Throttle | SRC02 | `throttle` | `Move` 的 `vx` |
| 右横 Roll | SRC03 | `roll` | `Move` 的 `vy` |
| POT1 | SRC04 | `pot_1` | 当前不调用 SDK |
| POT2 | SRC05 | `pot_2` | 当前不调用 SDK |
| S1 | SRC12 | `knob_s1` | 当前不调用 SDK |
| S2 | SRC13 | `knob_s2` | 当前不调用 SDK |
| T1 | 通道 42 / TRIM0 | `trim_t1` | `StandUp()` |
| T2 | 通道 43 / TRIM1 | `trim_t2` | `StandDown()` |
| T3 | 通道 44 / TRIM2 | `trim_t3` | `BalanceStand()` |
| T4 | 通道 45 / TRIM3 | `trim_t4` | `RecoveryStand()` |

当前安全策略下，所有 `switch_*` 动作只用于输入监视，网关不会让拨杆批量跳变直接改变 Go2 姿态、停止状态或解锁状态。

摇杆处理规则：

- 原始值按 `value / 1024` 归一化，并限制在 `[-1, 1]`；
- App 端中心死区为 `0.08`；
- 网关端再次应用 `0.08` 死区；
- 摇杆离开中心后，App 最多每 100 ms 补发目标值；
- 网关内部以 50 Hz 向 Go2 续发当前速度。

## 9. WebSocket 协议

- 协议名：`ax12-unitree-v1`
- 传输：WebSocket 文本帧；
- 编码：UTF-8 JSON；
- 默认端口：`8765`。

### 9.1 握手

App 建立 WebSocket 后，5 秒内必须发送：

```json
{
  "type": "hello",
  "protocol": "ax12-unitree-v1",
  "clientId": "ax12-android",
  "token": ""
}
```

网关返回 `ready`。判断机器人是否可控时应检查：

```json
{
  "type": "ready",
  "armed": false,
  "robot": {
    "connected": true,
    "serverApiVersion": "1.0.0.1",
    "externalControl": false,
    "leaseId": 123456,
    "connectionError": null
  }
}
```

### 9.2 命令

```json
{
  "type": "command",
  "protocol": "ax12-unitree-v1",
  "version": 1,
  "sequence": 17,
  "action": "throttle",
  "source": "Throttle / SRC02",
  "raw": 512,
  "normalized": 0.5,
  "timestamp": 1793222400000
}
```

字段说明：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sequence` | integer | App 单调递增序号 |
| `action` | string | 动作名 |
| `source` | string | AX12 通道或 `UI / manual` |
| `raw` | integer | AX12 原始值 |
| `normalized` | number | 必须位于 `[-1, 1]` |
| `timestamp` | integer | Unix 毫秒时间戳 |

### 9.3 响应

- `ack`：指令执行成功；
- `error`：协议、状态或 SDK 调用失败；
- `status`：当前网关和机器人状态；
- `pong`：心跳响应。

不能只看到 `ack` 就认为机器人动作成功，还应确认：

- `robot.connected == true`；
- `robot.lastResult == 0`；
- `robot.lastAction` 与目标动作一致；
- 连续运动时 `armed == true`。

## 10. 解锁、速度发布和安全保护

### 10.1 解锁流程

```text
检查 robot.connected
→ SwitchJoystick(False)
→ RecoveryStand()
→ 三轴速度清零
→ armed=true
```

任一步失败都会保持 `armed=false`，并尽力恢复内置摇杆控制。

### 10.2 50 Hz 速度发布

`RobotController.watchdog()` 每 20 ms 运行一次：

1. 未解锁时不发布；
2. 三轴非零时持续调用 `Move`；
3. 收到新的摇杆值只更新目标速度和时间戳；
4. 单次 DDS 调用失败不会让 watchdog 任务永久退出；
5. 驱动被标记离线时自动清零并锁定。

### 10.3 deadman 失联保护

默认 `DEADMAN_TIMEOUT=0.5` 秒。若机器人正在移动，但超过该时间没有收到新的运动目标，网关立即发送零速度停止，默认不解除 armed，方便恢复输入后继续控制。

### 10.4 断线保护

SDK 返回 3102 或 3104 时，Go2 驱动会：

- 清除 `SportClient`；
- 清除租约；
- 释放外部控制状态记录；
- 在 App 状态中显示具体错误；
- 由后台连接任务每 5 秒尝试重建客户端。

WebSocket 网关可以保持在线，因此 UI 必须分别显示“网关在线”和“机器人在线”。

## 11. 当前工程关键方法

### 11.1 Flutter App

| 方法 | 文件 | 作用 |
| --- | --- | --- |
| `ControlRouter.process()` | `lib/device_control/control_router.dart` | 比较前后两帧通道值，执行死区、变化检测和限流，生成业务命令 |
| `ControlRouter.manual()` | 同上 | 把 UI 手动按钮转换成与 AX12 相同的命令对象 |
| `ControlRouter._normalize()` | 同上 | 将 AX12 原始值缩放并限制到 `[-1,1]` |
| `JsonLineDeviceProtocol.encode()` | `lib/device_control/device_protocol.dart` | 生成带序号的 `ax12-unitree-v1` JSON 命令 |

### 11.2 Python WebSocket 网关

| 方法 | 文件 | 作用 |
| --- | --- | --- |
| `maintain_robot_connection()` | `gateway/gateway/server.py` | 后台连接、探测并重连 Go2，不阻塞 App 连接 |
| `GatewayServer.handle_client()` | 同上 | 校验首条 `hello`，循环收发 WebSocket 消息 |
| `GatewayServer._dispatch()` | 同上 | 分派 `command`、`ping`、`status` |
| `RobotController.handle()` | `gateway/gateway/controller.py` | 动作路由和统一安全检查 |
| `RobotController._prepare_motion_control()` | 同上 | 取得外部控制、恢复站立并解锁 |
| `RobotController.watchdog()` | 同上 | 50 Hz 速度续发和 deadman 保护 |
| `RobotController._publish_velocity()` | 同上 | 把三个归一化轴换算成真实速度并调用驱动 |
| `RobotController._stop()` | 同上 | 清零速度，按需释放外部控制并锁定 |

### 11.3 Go2 SDK 适配器

| 方法 | 文件 | 作用 |
| --- | --- | --- |
| `Go2RobotDriver.connect()` | `gateway/gateway/drivers/go2.py` | 初始化 DDS、申请租约并验证 Sport 服务 |
| `probe()` | 同上 | 低频探测服务版本，不因偶发诊断超时立即拆除客户端 |
| `move()` | 同上 | 调用 `SportClient.Move()` |
| `set_external_control()` | 同上 | 调用 `SwitchJoystick()` 切换控制权 |
| `stop()` | 同上 | 通过零速度 `Move` 停止 |
| `set_pitch()` | 同上 | 调用 `Euler()` 设置俯仰 |
| `invoke()` | 同上 | 白名单调用站起、趴下、平衡站立、恢复站立和阻尼 |
| `snapshot()` | 同上 | 提供 UI 所需的连接、租约、返回码和错误状态 |
| `_check_result()` | 同上 | 检查 SDK 返回码，防止失败被包装成成功 ACK |
| `_mark_disconnected()` | 同上 | 清除失效客户端和控制状态 |

## 12. 启动和验证

### 12.1 无机器人测试

```bash
cd /mnt/d/GitLab/Remote_control/remote/gateway
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
PYTHONPATH=. python -m unittest discover -s tests -v
PYTHONPATH=. python -m gateway.server --driver mock
```

### 12.2 Go2 实机测试

机器人应架空或放在无人员、无障碍的安全区域，并准备实体急停手段。

```bash
cd /mnt/d/GitLab/Remote_control/remote/gateway
source /home/lbchun/.venvs/unitree-gateway/bin/activate
export UNITREE_DRIVER=go2
export UNITREE_INTERFACE=eth1
PYTHONPATH=. python -m gateway.server
```

另一个终端查看网卡和日志：

```bash
ip -br address show eth1
sudo journalctl -u ax12-unitree-gateway -f
```

Windows PowerShell 启动保持任务：

```powershell
cd D:\GitLab\Remote_control\remote
.\gateway\start-unitree-gateway.ps1
```

## 13. 常见错误

### 13.1 `Go2 Sport 控制租约申请超时`

含义：5 秒内没有取得非零 `leaseId`。

检查：

1. Go2 是否完全启动；
2. 是否还有宇树 App、遥控器或其他程序占用控制权；
3. `UNITREE_INTERFACE` 是否指向 Go2 网卡；
4. DDS 组播是否被路由器、Windows 防火墙或 Hyper-V 防火墙阻断；
5. 是否错误地在 Wi-Fi 网卡上初始化 DDS。

### 13.2 SDK 返回码 3102

通常表示客户端无法向 Sport 服务发送 RPC。优先检查 DDS 网卡、路由、组播和防火墙，而不是 App 的 WebSocket。

### 13.3 SDK 返回码 3104

通常表现为 RPC 超时。当前项目已避免用 `StopMove()` 作为姿态动作的前置条件，并使用零速度 `Move` 停止；若实际动作仍返回 3104，驱动会标记离线并重连。

### 13.4 网关在线、机器人离线

这是两条独立链路：

```text
AX12 → 笔记本 TCP 8765：正常
笔记本 → Go2 DDS/Sport：失败
```

查看 `robot.connectionError`，不要反复修改 App 地址。

### 13.5 站起/趴下有效，摇杆无效

依次确认：

1. `leaseId` 是否非零；
2. `externalControl` 是否为 `true`；
3. 是否先执行了解锁；
4. `axes` 是否随摇杆变化；
5. Flutter 是否持续补发非中心摇杆值；
6. watchdog 是否仍在 50 Hz 运行；
7. `Move` 的返回码是否为 0。

## 14. 扩展新动作

推荐按以下顺序扩展：

1. 在 `ControlRouter.defaultBindings` 中定义稳定的 `action` 名称；
2. 在 `RobotController.handle()` 中显式处理；
3. 在 `Go2RobotDriver` 中增加一个最小、白名单化的方法；
4. 对动作增加在线、解锁、限幅和执行后状态规则；
5. 在 mock 驱动和单元测试中覆盖成功、失败和断线场景；
6. 最后才在实机低速、架空条件下验证。

示例：增加“坐下”动作时，不应从 Flutter 直接拼 SDK 方法名，而应采用：

```text
Flutter action: sit
→ RobotController.handle("sit")
→ Go2RobotDriver.invoke("sit") 白名单
→ SportClient.Sit()
```

不建议开放前空翻、后空翻等高风险 SDK 接口给普通 AX12 按钮。

## 15. 二次开发原则

- Android 层不依赖具体机器人 SDK，只依赖稳定的业务动作协议；
- Python 网关集中处理 SDK、控制权、限速和安全状态；
- 所有运动动作必须显式检查在线和解锁状态；
- 所有 SDK 返回码都必须检查，非零不得返回成功 ACK；
- 任何断线都应清零目标速度并撤销软件解锁；
- 输入监视与机器人动作必须分开，避免 AX12 批量通道变化误触发；
- 新机器人型号通过实现新的 `RobotDriver` 接入，不修改 App 协议；
- 实机调试从低速度开始，并保留物理急停、空旷区域和现场监护。

## 16. 项目文件索引

```text
D:\GitLab\Remote_control\remote\
├─ lib\device_control\control_router.dart
├─ lib\device_control\device_protocol.dart
├─ lib\device_control\device_transport.dart
├─ lib\device_control\device_bridge_controller.dart
├─ lib\ax12_sources.dart
└─ gateway\
   ├─ README.md
   ├─ requirements.txt
   ├─ start-unitree-gateway.ps1
   ├─ status-unitree-gateway.ps1
   ├─ stop-unitree-gateway.ps1
   └─ gateway\
      ├─ config.py
      ├─ protocol.py
      ├─ server.py
      ├─ controller.py
      └─ drivers\go2.py
```

