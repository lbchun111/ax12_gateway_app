# AX12 Android 直连 Go2 DDS/Sport 实施说明

## 1. 目标与边界

本实现让 AX12 Android App 在 Android 9 上直接运行 CycloneDDS，并通过 Go2 公开的 Sport RPC Topic 控制机器人。它与现有“Windows/WSL2 笔记本网关”并存，UI 只显示这两种宇树连接方式。

只实现当前遥操作所需的公开接口，不复制完整 `unitree_sdk2`，不接入低层电机控制，也不开放翻转、跳跃、舞蹈等高风险 API。

## 2. 分阶段实施状态

### 阶段 1：编译、网卡枚举、只读发现（已实现）

- Android 9，`minSdk = 28`。
- CycloneDDS 0.10.5 已构建为 Android `arm64-v8a`、`armeabi-v7a`、`x86_64` 动态库。
- App 可枚举 Android IPv4 网卡，并优先选择 `192.168.123.0/24` 网段。
- 连接时只建立 DDS Participant、Topic、Reader、Writer，等待 Sport 服务匹配，然后调用 API `1` 读取服务版本。
- 阶段 1 不发送姿态或移动命令。

当前 AX12 实测只有 `wlan0 = 192.168.0.143/24`，而 Go2 地址为 `192.168.123.161`。因此必须先让 AX12 的 Wi-Fi/以太网进入 Go2 所在二层网络，再进行直连发现。无需修改 Windows 网关网络，两个模式相互独立。

### 阶段 2：离散姿态命令（已实现，等待实体联调）

连接成功后必须先在 App 点击“解锁”或使用已映射的 SF 开关。只开放阻尼、平衡站立、停止、站起、趴下、恢复站立。

建议实体测试顺序：

1. 将机器人放在开阔、平坦区域，并确保急停手段可用。
2. Android DDS 直连成功，确认日志包含 Sport 服务版本。
3. 点击“解锁”。
4. 依次验证“站起”“停止”“趴下”。
5. 任一步返回非零状态码或超时，立即停止后续动作测试。

### 阶段 3：摇杆速度控制（已实现，等待实体联调）

- `Move` 最大前后速度：`0.8 m/s`。
- 最大横移速度：`0.5 m/s`。
- 最大偏航角速度：`1.5 rad/s`。
- `Euler` 最大俯仰：`0.3 rad`。
- 输入中心死区：`8%`。
- 运动看门狗：`500 ms` 未收到新的有效运动输入即发送零速度。
- 每 `2 s` 调用只读 API `1` 检查 Sport 服务；失败会标记断线并触发重连。

### 阶段 4：稳定性与异常测试（待实体环境执行）

- 拔网线、切换 Wi-Fi、关闭 Go2 后，确认 App 显示 DDS 断开并停止续发。
- 持续摇杆操作时模拟链路中断，确认 `500 ms` 看门狗和机器人自身保护生效。
- 记录各固件版本的 Sport 响应状态码、发现耗时和重连耗时。
- 完成验证前保留笔记本网关作为回退连接方式。

## 3. DDS Topic 与公开消息结构

| 方向 | Topic | 类型 |
| --- | --- | --- |
| App → Go2 | `rt/api/sport/request` | `unitree_api.msg.dds_.Request_` |
| Go2 → App | `rt/api/sport/response` | `unitree_api.msg.dds_.Response_` |

请求字段：

- `header.identity.id`：单调时钟纳秒请求 ID。
- `header.identity.api_id`：Sport API ID。
- `header.lease.id`：当前设为 `0`。
- `header.policy.priority`：当前设为 `0`。
- `header.policy.noreply`：连续 `Move` 使用 `true`，需要结果的姿态命令使用 `false`。
- `parameter`：UTF-8 JSON 参数。
- `binary`：本项目未使用。

响应通过 `identity.id` 和 `api_id` 与请求匹配；`header.status.code == 0` 才视为成功。

## 4. Sport API 白名单

| API ID | 名称 | 参数 | 本项目用途 |
| ---: | --- | --- | --- |
| 1 | GetServerApiVersion | `{}` | 连接探测、健康检查 |
| 1001 | Damp | `{}` | 阻尼并锁定 |
| 1002 | BalanceStand | `{}` | 平衡站立 |
| 1003 | StopMove | `{}` | 停止运动 |
| 1004 | StandUp | `{}` | 站起 |
| 1005 | StandDown | `{}` | 趴下 |
| 1006 | RecoveryStand | `{}` | 恢复站立 |
| 1007 | Euler | `{"x": roll, "y": pitch, "z": yaw}` | 当前只使用 pitch |
| 1008 | Move | `{"x": vx, "y": vy, "z": vyaw}` | 三轴速度遥操作 |

Kotlin 层和 Flutter 层都执行白名单检查。未解锁时，姿态和移动命令会在本地被拒绝。

## 5. 代码结构

- `android/app/src/main/cpp/unitree_dds_bridge.c`：DDS 实体生命周期、请求/响应匹配、JNI。
- `android/app/src/main/cpp/generated/unitree_api.c/.h`：由公开 IDL 生成的 C 类型支持。
- `android/app/src/main/kotlin/com/remotecontrol/remote/dds/UnitreeDdsNative.kt`：最小 JNI 声明。
- `android/app/src/main/kotlin/com/remotecontrol/remote/dds/UnitreeDdsPlugin.kt`：Flutter MethodChannel、网卡枚举、组播锁和 API 白名单。
- `lib/device_control/device_transport.dart`：`UnitreeDdsDeviceTransport`，负责动作映射、限速、死区、看门狗和健康检查。
- `lib/device_control/device_control_page.dart`：网关/DDS 双模式 UI 和网卡选择。

所有新增的手写方法都带有职责、参数或安全行为说明，方便后续二次开发。

## 6. 构建和使用

```powershell
cd D:\GitLab\Remote_control\remote
flutter analyze
flutter test
flutter build apk --debug
```

在 AX12 上：

1. 打开“宇树 Go2 控制”。
2. 选择“Android DDS直连”。
3. 点击刷新，选择与 Go2 同网段且支持组播的网卡。
4. 点击“连接设备”。
5. 只有日志显示机器人已连接和 Sport 版本后，才进行阶段 2 的动作验证。

## 7. 公开定义来源

- Unitree 官方 Python SDK Sport Client：<https://github.com/unitreerobotics/unitree_sdk2_python/blob/master/unitree_sdk2py/go2/sport/sport_client.py>
- Unitree 官方 ROS2 Sport 请求示例：<https://github.com/unitreerobotics/unitree_ros2/blob/master/example/src/include/common/ros2_sport_client.h>
- Eclipse CycloneDDS：<https://github.com/eclipse-cyclonedds/cyclonedds>

这些上游定义是消息字段、Topic 和 API ID 的依据；项目内只保留实际使用的最小子集。
