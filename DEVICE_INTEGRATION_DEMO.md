# AX12 外部设备控制 Demo

## 目标

该 Demo 在没有指定设备协议和最终 UI 设计的情况下，先建立一条可运行的控制链路：

```text
AX12 实体控件
  → UMBUS 串口输入
  → ControlRouter 动作映射
  → DeviceProtocol 协议编码
  → DeviceTransport 连接通道
  → Mock Wi-Fi UDP 或 BLE GATT 设备
```

默认使用 `JSON Line Demo v1` 协议。每次遥控器操作会转换为一行 UTF-8 JSON：

> 所有项目自定义方法的参数、返回值、流程和扩展说明见
> [`METHOD_REFERENCE.md`](METHOD_REFERENCE.md)。源码中的每个具名方法上方也已添加
> DartDoc/KDoc 注释，可在 Android Studio 中悬停查看。

```json
{
  "version": 1,
  "sequence": 12,
  "action": "switch_sa",
  "source": "SA / SRC14",
  "raw": 500,
  "normalized": 0.4883,
  "timestamp": 1791510000000
}
```

## Demo 功能

- 模拟设备连接，无需外部硬件即可演示完整发送与 ACK；
- Wi-Fi UDP 连接，可配置 IP 或域名及目标端口；
- BLE GATT 扫描、连接、特征写入和可选 Notify 接收；
- AX12 42 路 SRC 与 T1–T4 四路 Trim 输入中的已知控件自动映射为动作；
- 摇杆和旋钮以 50 ms 最小间隔限流，避免高频发送压垮设备；
- 手动发送前进、左转、停止和灯光命令；
- 显示最新输入、协议数据和通信日志；
- 保留原 AX12 简约监听页和详细原始数据页。

## 目录职责

```text
lib/
  main.dart
  device_control/
    device_models.dart
    control_router.dart
    device_protocol.dart
    device_transport.dart
    device_bridge_controller.dart
    device_control_page.dart
```

| 文件 | 只负责 |
|---|---|
| `device_models.dart` | 跨层数据模型 |
| `control_router.dart` | SRC 输入到业务动作的映射、阈值和限流 |
| `device_protocol.dart` | 业务动作编码为设备字节流 |
| `device_transport.dart` | Mock、UDP 和 BLE 的连接与字节收发 |
| `device_bridge_controller.dart` | 组织输入、协议和连接，不包含页面布局 |
| `device_control_page.dart` | 页面状态展示和用户配置 |

## 对接厂商协议

拿到厂商协议后，新建一个 `DeviceProtocol` 实现：

```dart
class VendorBinaryProtocol implements DeviceProtocol {
  @override
  String get name => 'Vendor Binary v2';

  @override
  String get description => '厂商二进制控制协议';

  @override
  Uint8List encode(DeviceCommand command) {
    // 1. 将 action 映射为厂商命令字
    // 2. 将 rawValue 或 normalizedValue 转为协议字段
    // 3. 填入帧头、长度和序列号
    // 4. 计算厂商要求的 CRC 或校验和
    return Uint8List.fromList(<int>[/* ... */]);
  }
}
```

然后将 `DeviceBridgeController.protocol` 改为该实现。遥控器输入、连接通道和 UI 不需要随协议一起重写。

如果设备同时存在多条命令协议，可以将协议选择加入配置页，或者按照设备型号创建 `DeviceProfile`，由 Profile 同时提供默认协议、Transport 参数和动作映射。

## 对接新的连接方式

实现 `DeviceTransport` 即可增加 TCP、WebSocket、HTTP、MQTT、USB 或其他通道：

```dart
class VendorTransport implements DeviceTransport {
  @override
  String get name => 'Vendor Transport';

  @override
  Stream<String> get events => /* 连接状态和接收日志 */;

  @override
  Future<void> connect() async {}

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> disconnect() async {}
}
```

Transport 只处理字节，不理解 `yaw`、`switch_sa` 等业务动作，也不拼接协议帧。

## 更新 UI

页面通过 `DeviceBridgeController` 读取和修改状态。更新视觉稿时，可以直接替换 `device_control_page.dart`，以下逻辑不需要移动到 Widget 中：

- AX12 EventChannel 监听；
- 控件变化检测；
- 动作映射和限流；
- 协议编码；
- UDP 或 BLE 连接；
- 发送队列和错误日志。

复杂项目可进一步将页面拆成连接配置、映射编辑、控制台和日志四个独立 Route，Controller 接口保持不变。

## BLE 配置

Demo 使用 `flutter_reactive_ble`。BLE 只支持 GATT 低功耗蓝牙，不等于传统蓝牙串口 SPP。

BLE 对接至少需要厂商提供：

- 设备广播名称或筛选 Service UUID；
- Service UUID；
- Write Characteristic UUID；
- 写入方式是 Write With Response 还是 Without Response；
- 如设备会返回数据，还需要 Notify Characteristic UUID；
- 单包长度、分包和重组规则。

当前 Demo 默认使用 Write With Response，以优先保证命令确认。若设备要求高频无响应写入，需要在 BLE Transport 中改用 `writeCharacteristicWithoutResponse`，同时增加发送节流和丢包策略。

## Wi-Fi 配置

Demo 使用 UDP 单播，应用绑定随机本地端口并向配置的设备 IP 和端口发送协议字节。收到设备 UDP 回包后会显示在日志中。

若厂商提供 TCP、HTTP、WebSocket 或 MQTT 接口，应新增相应 Transport，不要在 `JsonLineDeviceProtocol` 中处理 Socket 连接。

## 需要厂商确认的信息

正式对接前至少需要确认：

1. 设备发现方式和连接方式；
2. BLE UUID 或 Wi-Fi 地址、端口和会话过程；
3. 命令帧格式、字节序、校验算法和响应格式；
4. 每个遥控动作对应的命令和取值范围；
5. 摇杆数据允许的发送频率；
6. 超时、重试、心跳、断线重连和急停策略；
7. 是否需要认证、加密或配对；
8. 控制失败时设备应进入的安全状态。

## 运行

```powershell
cd D:\GitLab\Remote_control\remote
flutter pub get
flutter analyze
flutter test
flutter run -d 0123456789ABCDEF
```

首次 BLE 扫描需要在 AX12 上允许附近设备或位置权限。Android 9 还要求系统位置服务开启，才能返回 BLE 扫描结果。

