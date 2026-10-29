# AX12 Android App + WSL2 Unitree SDK 网关实现说明

## 数据链路

```text
AX12 UMBUS 控件
  → Flutter ControlRouter
  → JSON Line v1
  → WebSocket ws://<笔记本IP>:8765
  → WSL2 Python Gateway
  → RobotController（限速/解锁/deadman）
  → RobotDriver
  → unitree_sdk2_python / CycloneDDS
  → 宇树机器人
```

## WebSocket 消息

连接后 App 首先发送：

```json
{"type":"hello","protocol":"ax12-unitree-v1","clientId":"ax12-android","token":""}
```

遥控命令沿用 App 已有 JSON，并增加 `type=command`：

```json
{"type":"command","protocol":"ax12-unitree-v1","sequence":12,"action":"throttle","source":"Throttle / SRC02","raw":400,"normalized":0.3906,"timestamp":1791510000000}
```

网关返回 `ready`、`ack`、`pong`、`status` 或 `error`。协议版本固定为 `ax12-unitree-v1`，以后可并行增加 v2 而不破坏现有 App。

## 默认控制映射

| App action | 网关含义 |
|---|---|
| `throttle` | `vx` 前后速度 |
| `roll` | `vy` 横向速度 |
| `yaw` | `vyaw` 旋转速度 |
| `arm` | 解锁运动命令 |
| `disarm` / `stop` / `emergency_stop` | 停止并锁定 |
| `switch_sf` | 正值解锁，其他值停止并锁定 |
| `stand_up` 等白名单 | 调用 Go2 SportClient 离散动作 |

物理按钮进一步映射如下：SA 正/负端执行站起/趴下；SB 正/负端执行平衡站立/
恢复站立；SD 正端进入阻尼并锁定；SE 端点停止移动；T1~T4 分别作为站起、
趴下、平衡站立、恢复站立快捷键。所有姿态动作要求先解锁，且执行前会先清零速度。

`pitch` 和其他未定义按钮仍会收到 ACK，但默认不驱动机器人，待确定具体型号和操作需求后再映射。

## 安全约束

- 网关启动时始终锁定；
- 摇杆中心 `±0.04` 死区；
- 三轴速度分别限幅；
- 500 ms deadman 自动停止；
- 只有白名单动作能进入 SDK；
- SDK 在 Python 网关中延迟导入，因此 `mock` 联调不依赖机器人或 CycloneDDS；
- 局域网正式使用应设置 `GATEWAY_TOKEN`。

## 二次开发入口

- 换机器人型号：实现 `gateway/drivers/base.py::RobotDriver`；
- 换 AX12 控件映射：修改 Flutter `control_router.dart`；
- 换网络协议：新增 Flutter `DeviceTransport` 或升级 WebSocket 协议版本；
- 换 UI：只修改 `device_control_page.dart`，Controller/Protocol/Transport 可保持不变。

## 当前联调状态（2026-10-23）

- Windows 11 + WSL2 mirrored networking 已配置；
- Ubuntu 22.04 网关服务监听 `0.0.0.0:8765`；
- Windows 与 Hyper-V 防火墙均仅放行 TCP 8765；
- AX12（Android 9 / API 28）已通过 Wi-Fi 完成 WebSocket `hello → ready` 握手；
- App 真机页面显示“已连接”；
- 实机探测确认 Go2 SDK 地址为 `192.168.123.161`、机载计算机为
  `192.168.123.18`；WSL2 `eth1` 已配置专用地址 `192.168.123.99/24`，
  且没有修改默认网关或 DNS；
- 当前驱动是 `mock`，没有向真实机器人发送运动命令；
- 切换实机前还需确认宇树型号、机器人网络接口和现场安全流程。

