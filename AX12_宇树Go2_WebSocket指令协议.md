# AX12 → 笔记本网关 → 宇树 Go2 指令协议

## 1. 文档范围

本文档描述当前项目中 AX12 Android App 与 Windows/WSL2 Python 网关之间实际使用的 WebSocket JSON 协议，以及网关如何把指令转换为宇树 Go2 `SportClient` 调用。

- 协议名称：`ax12-unitree-v1`
- 传输方式：WebSocket 文本帧
- 默认地址：`ws://<Windows笔记本局域网IP>:8765`
- 当前 App 示例：`ws://192.168.0.124:8765`
- 文本编码：UTF-8
- App 发送的命令末尾可以带换行符；网关按完整 WebSocket 消息解析 JSON。

> “网关已连接”只表示 AX12 能访问笔记本 WebSocket。只有响应中的 `robot.connected` 为 `true`，才表示 Go2 已经通过 CycloneDDS 连接。

## 2. 完整通信流程

1. App 建立 WebSocket。
2. App 必须在 5 秒内发送 `hello`。
3. 网关校验协议版本和可选令牌。
4. 网关返回 `ready`，其中包含机器人连接、锁定和摇杆状态。
5. App 发送 `command`、`status` 或 `ping`。
6. 网关分别返回 `ack`、`status`、`pong` 或 `error`。
7. App 当前每 5 秒发送一次 `ping` 和 `status`，用于更新机器人在线状态。

## 3. 握手消息

### 3.1 App → 网关：hello

这是 WebSocket 建立后的第一条消息。

```json
{
  "type": "hello",
  "protocol": "ax12-unitree-v1",
  "clientId": "ax12-android",
  "token": ""
}
```

| 字段 | 类型 | 必填 | 描述 |
| --- | --- | --- | --- |
| `type` | string | 是 | 固定为 `hello` |
| `protocol` | string | 是 | 固定为 `ax12-unitree-v1` |
| `clientId` | string | 否 | 客户端标识，当前为 `ax12-android` |
| `token` | string | 否 | 与网关环境变量 `GATEWAY_TOKEN` 一致；网关未配置时可为空 |

### 3.2 网关 → App：ready

```json
{
  "type": "ready",
  "protocol": "ax12-unitree-v1",
  "sequence": null,
  "armed": false,
  "axes": {
    "throttle": 0.0,
    "roll": 0.0,
    "yaw": 0.0
  },
  "driver": "unitree-go2",
  "robot": {
    "connected": false,
    "networkInterface": "eth1",
    "robotIp": "192.168.123.161",
    "serverApiVersion": null,
    "connectionError": "Go2 192.168.123.161 不可达，请检查机器人电源和有线网卡",
    "lastAction": "none",
    "lastResult": null
  }
}
```

关键判断：

- `armed=false`：网关处于锁定状态，运动和姿态命令会被拒绝。
- `robot.connected=false`：只连上了笔记本网关，尚未连上机器人。
- `robot.connectionError`：机器人离线的具体原因。
- `serverApiVersion` 非空：Go2 Sport 服务已经完成发现。

## 4. 通用 command 格式

```json
{
  "type": "command",
  "protocol": "ax12-unitree-v1",
  "version": 1,
  "sequence": 17,
  "action": "stand_up",
  "source": "UI / manual",
  "raw": 1024,
  "normalized": 1.0,
  "timestamp": 1792828800000
}
```

| 字段 | 类型 | 必填 | 描述 |
| --- | --- | --- | --- |
| `type` | string | 是 | 固定为 `command` |
| `protocol` | string | 建议 | 固定为 `ax12-unitree-v1`；当前网关只在握手阶段校验协议 |
| `version` | integer | 建议 | 当前为 `1` |
| `sequence` | integer | 是 | App 单调递增的指令序号，响应会原样返回 |
| `action` | string | 是 | 动作名称，见下表 |
| `source` | string | 否 | 来源控件，例如 `SA / SRC20`、`UI / manual` |
| `raw` | integer | 否 | AX12 原始值，默认 `0` |
| `normalized` | number | 否 | 归一化值，必须在 `[-1.0, 1.0]`，默认 `0.0` |
| `timestamp` | integer | 否 | Unix 毫秒时间戳，默认 `0` |

若 `normalized` 超出范围，网关返回协议错误。

## 5. 可执行动作指令
·8
### 5.1 解锁、锁定与停止

| `action` | `normalized` | 前置条件 | 网关行为 | Go2 调用 |
| --- | ---: | --- | --- | --- |
| `arm` | 任意 | `robot.connected=true` | 允许后续运动和姿态命令 | 不直接调用 SDK |
| `disarm` | 任意 | 无 | 速度归零并锁定 | 在线时调用 `Move(0,0,0)` |
| `stop` | 任意 | 无 | 速度归零并锁定 | 在线时调用 `Move(0,0,0)` |
| `emergency_stop` | 任意 | 无 | 速度归零并锁定 | 在线时调用 `Move(0,0,0)` |
| `switch_sf` | `> 0` | 机器人在线 | 解锁 | 不直接调用 SDK |
| `switch_sf` | `<= 0` | 无 | 停止并锁定 | 在线时调用 `Move(0,0,0)` |
| `switch_se` | 绝对值 `>= 0.5` | 无 | 停止移动但保持当前解锁状态 | `Move(0,0,0)` |

机器人离线时，`arm` 和 SF 解锁会返回 `error`，并保持 `armed=false`。

### 5.2 姿态动作

下列动作必须先解锁。网关会清除内部速度状态后直接调用姿态接口，
不再让部分固件会超时的 `StopMove()` 阻断姿态动作。

| `action` | 含义 | Go2 SDK 方法 | 执行后状态 |
| --- | --- | --- | --- |
| `stand_up` | 站起 | `SportClient.StandUp()` | 保持解锁 |
| `stand_down` | 趴下 | `SportClient.StandDown()` | 自动锁定 |
| `balance_stand` | 平衡站立 | `SportClient.BalanceStand()` | 保持解锁 |
| `recovery_stand` | 恢复站立 | `SportClient.RecoveryStand()` | 保持解锁 |
| `damp` | 阻尼模式 | `SportClient.Damp()` | 自动锁定 |

手动站起示例：

```json
{"type":"command","protocol":"ax12-unitree-v1","version":1,"sequence":1,"action":"arm","source":"UI / manual","raw":1024,"normalized":1.0,"timestamp":1792828800000}
```

收到成功 ACK 后再发送：

```json
{"type":"command","protocol":"ax12-unitree-v1","version":1,"sequence":2,"action":"stand_up","source":"UI / manual","raw":1024,"normalized":1.0,"timestamp":1792828800100}
```

### 5.3 连续运动轴

| `action` | 物理来源 | 归一化值 | SDK 参数 | 默认最大值 |
| --- | --- | ---: | --- | ---: |
| `throttle` | Throttle / SRC02 | `[-1,1]` | `vx` 前后速度 | `0.8 m/s` |
| `roll` | Roll / SRC03 | `[-1,1]` | `vy` 横移速度 | `0.5 m/s` |
| `yaw` | Yaw / SRC00 | `[-1,1]` | `vyaw` 旋转角速度 | `1.5 rad/s` |
| `pitch` | Pitch / SRC01 | `[-1,1]` | `Euler(0,pitch,0)` 机身俯仰 | `0.3 rad` |

最终调用：

```text
SportClient.Move(
  vx   = throttle × MAX_VX,
  vy   = roll     × MAX_VY,
  vyaw = yaw      × MAX_VYAW
)
```

安全规则：

- 必须先解锁。
- `abs(normalized) < 0.08` 时按 `0` 处理，避免 AX12 中心偏移造成缓慢爬行。
- 结果会再次限制在 `[-1,1]`。
- 默认失联保护时间为 `0.5 秒`；超过该时间没有新的运动更新时，网关自动发送停止。
- 当前 App 对离开中心死区的四个摇杆轴每 `100 ms` 续发一次；回中只发送一次零值，不继续刷包。
- 网关明确报告锁定时，App 不发送摇杆包，但解锁和姿态开关仍可正常发送。

辅助动作：

| `action` | 行为 |
| --- | --- |
| `move_forward` | 将 `max(0, normalized)` 写入 `throttle` 后发送 Move |
| `turn_left` | 将 `min(0, normalized)` 写入 `yaw` 后发送 Move |

## 6. AX12 控件到 action 的映射

| 控件 | 数据源 | 发送 action | 网关当前行为 |
| --- | --- | --- | --- |
| 左横 Yaw | SRC00 | `yaw` | 旋转 `vyaw` |
| 右纵 Pitch | SRC01 | `pitch` | 机身前后俯仰，最大约 ±17° |
| 左纵 Throttle | SRC02 | `throttle` | 前后 `vx` |
| 右横 Roll | SRC03 | `roll` | 横移 `vy` |
| POT1 | SRC04 | `pot_1` | **当前仅透传，无机器人动作** |
| POT2 | SRC05 | `pot_2` | **当前仅透传，无机器人动作** |
| S1 | SRC12 | `knob_s1` | **当前仅透传，无机器人动作** |
| S2 | SRC13 | `knob_s2` | **当前仅透传，无机器人动作** |
| SA | SRC20 | `switch_sa` | 正端站起；负端趴下；中位不动作 |
| SB | SRC21 | `switch_sb` | 正端平衡站立；负端恢复站立；中位不动作 |
| SC | SRC22 | `switch_sc` | **当前仅透传，无机器人动作** |
| SD | SRC23 | `switch_sd` | 正端进入阻尼并锁定；其他值不动作 |
| SE | SRC24 | `switch_se` | 绝对值达到 `0.5` 时停止移动 |
| SF | SRC25 | `switch_sf` | 正端解锁；其他位置停止并锁定 |
| 6POS | SRC35 | `switch_6pos` | **当前仅透传，无机器人动作** |
| T1 | TRIM0 / 通道42 | `trim_t1` | 站起 |
| T2 | TRIM1 / 通道43 | `trim_t2` | 趴下并锁定 |
| T3 | TRIM2 / 通道44 | `trim_t3` | 平衡站立 |
| T4 | TRIM3 / 通道45 | `trim_t4` | 恢复站立 |

T1～T4 在数值发生有效变化时触发一次，并不是按住连续发送。

## 7. 查询状态与心跳

### 7.1 状态查询

App → 网关：

```json
{"type":"status"}
```

网关 → App：

```json
{
  "type": "status",
  "protocol": "ax12-unitree-v1",
  "sequence": null,
  "armed": false,
  "axes": {"throttle": 0.0, "roll": 0.0, "yaw": 0.0},
  "driver": "unitree-go2",
  "robot": {
    "connected": true,
    "networkInterface": "eth1",
    "robotIp": "192.168.123.161",
    "serverApiVersion": "1.0.0.1",
    "connectionError": null,
    "lastAction": "stand_up",
    "lastResult": 0
  }
}
```

### 7.2 心跳

App → 网关：

```json
{"type":"ping","timestamp":1792828800000}
```

网关 → App：

```json
{"type":"pong","protocol":"ax12-unitree-v1","timestamp":1792828800000}
```

## 8. 响应格式

### 8.1 成功 ACK

```json
{
  "type": "ack",
  "protocol": "ax12-unitree-v1",
  "sequence": 2,
  "armed": true,
  "axes": {"throttle": 0.0, "roll": 0.0, "yaw": 0.0},
  "driver": "unitree-go2",
  "robot": {
    "connected": true,
    "lastAction": "stand_up",
    "lastResult": 0
  }
}
```

### 8.2 指令执行错误

```json
{
  "type": "error",
  "protocol": "ax12-unitree-v1",
  "sequence": 2,
  "armed": false,
  "action": "stand_up",
  "message": "控制器未解锁，已拒绝 stand_up",
  "robot": {
    "connected": true
  }
}
```

常见错误：

| `message` 示例 | 含义 | 处理方法 |
| --- | --- | --- |
| `机器人未连接，已拒绝 arm` | 网关在线，Go2 离线 | 检查机器人电源、网线、IP 和 CycloneDDS |
| `控制器未解锁，已拒绝 stand_up` | 未先发送解锁 | 先发送 `arm`，确认 ACK 后再发送姿态动作 |
| `Go2 驱动尚未连接` | DDS 客户端尚未就绪 | 等待 `robot.connected=true` |
| `SDK 返回码=3102` | SDK 无法向 Sport 服务发送请求 | 检查 DDS 网卡、路由和防火墙 |
| `normalized 必须位于 [-1, 1]` | 数值越界 | 修正归一化值 |
| `网关令牌错误` | token 不匹配 | 检查 App 和网关的令牌配置 |

## 9. ACK 的正确判定方式

当前控制器对尚未实现的 `action` 没有抛出错误，而是直接返回状态 ACK。因此必须同时检查：

1. 响应 `type` 是否为 `ack`；
2. `robot.connected` 是否为 `true`；
3. `robot.lastAction` 是否更新为期望动作；
4. `robot.lastResult` 是否为 `0`。

不要仅凭 ACK 判断机器人已经执行。旋钮、SC 和 6POS 当前不会调用 Go2 SDK。

## 10. 安全发送顺序

姿态控制推荐顺序：

```text
连接 WebSocket
→ hello
→ 检查 ready.robot.connected == true
→ arm
→ 检查 ACK.armed == true
→ stand_up / balance_stand / 其他姿态动作
→ 完成后 stop 或 disarm
```

连续运动推荐顺序：

```text
确认机器人周围无人和障碍物
→ arm
→ App 每100ms周期发送离开中心的 throttle / roll / yaw / pitch
→ 摇杆回中时发送对应轴的 0 值
→ stop 或 emergency_stop
```

## 11. 二次开发约束

- 新动作应先在 Flutter `ControlRouter` 中定义稳定的 `action` 名称。
- 在 Python `RobotController.handle()` 中显式处理该动作。
- 在 Go2 驱动中只开放经过审核的 SDK 方法。
- 未实现的动作建议未来改为返回 `error`，避免“空 ACK”。
- 每条有运动风险的动作必须经过机器人在线检查和解锁检查。
- 不要绕过 `deadman`、速度上限和停止逻辑直接调用 SDK。

## 12. 当前实现文件

- App 协议编码：`lib/device_control/device_protocol.dart`
- AX12 动作路由：`lib/device_control/control_router.dart`
- WebSocket 传输：`lib/device_control/device_transport.dart`
- 网关消息解析：`gateway/gateway/protocol.py`
- 指令执行与安全策略：`gateway/gateway/controller.py`
- WebSocket 服务：`gateway/gateway/server.py`
- Go2 SDK 适配：`gateway/gateway/drivers/go2.py`

