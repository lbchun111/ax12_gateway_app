# AX12 外部设备控制 Demo：方法说明

本文按源码文件解释项目自行编写的全部具名方法、构造函数和 getter。Flutter SDK、第三方依赖、Gradle 生成代码以及按钮中的匿名闭包不在此表内。

## 1. 总体调用关系

```text
main()
  → Ax12UmbusMonitorApp.build()
  → Android EventChannel
  → MainActivity.startSerialReader()
  → MainActivity.readFrames()
  → MainActivity.emitChannelFrame()
  → DeviceBridgeController._onAx12Event()
  → ControlRouter.process()
  → DeviceBridgeController._enqueue()
  → DeviceProtocol.encode()
  → DeviceTransport.send()
  → Mock / UDP / BLE 设备
```

核心原则是：输入解析、动作映射、协议编码、通信链路和页面展示互相分离。以后替换设备协议时，不需要重写 AX12 串口读取和 UI；更新 UI 时，也不需要改协议与传输实现。

---

## 2. `lib/device_control/device_models.dart`

该文件只定义跨层数据对象和状态枚举，不执行网络或串口操作。

### 枚举

| 类型 | 值 | 说明 |
|---|---|---|
| `DeviceLinkKind` | `mock` | 模拟设备，发送后在本地返回 ACK。 |
|  | `wifiUdp` | 使用 Wi-Fi UDP 单播发送。 |
|  | `bleGatt` | 使用 BLE GATT 特征写入。 |
| `DeviceLinkState` | `disconnected` | 尚未连接或已经断开。 |
|  | `connecting` | 正在建立连接。 |
|  | `connected` | 连接成功，可以发送。 |
|  | `error` | 最近一次连接过程失败。 |

### `DeviceCommand(...)`

- 用途：创建一条与具体通信协议无关的“业务控制命令”。
- 参数：`action` 是动作名；`source` 是 AX12 控件来源；`rawValue` 是原始整数；`normalizedValue` 是归一化值；`timestamp` 是动作时间。
- 返回：不可变的 `DeviceCommand` 对象。
- 说明：协议层只依赖该对象，因此将来更换二进制协议不需要改 AX12 输入层。

### `ControlBinding(...)`

- 用途：定义一个 AX12 SRC 通道到业务动作的映射规则。
- 参数：`sourceIndex` 为通道下标；`sourceName` 为可读名称；`action` 为业务动作名；`changeThreshold` 为去抖阈值；`minimumInterval` 为最小发送间隔。
- 默认值：变化阈值为 `2`，最小间隔为 `50 ms`。
- 扩展：对开关可使用 `Duration.zero`，对摇杆可提高间隔以限制发送频率。

### `OutboundPacket(...)`

- 用途：把原始业务命令和编码后的字节放在同一个对象中，供页面显示最近一次发送内容。
- 参数：`command` 为业务命令，`bytes` 为协议编码结果。
- 返回：不可变的 `OutboundPacket`。

### `BridgeLogEntry(...)`

- 用途：保存一条连接或发送日志。
- 参数：`time`、`message`，以及可选的 `isError`。
- 默认值：`isError = false`。

### `BleDeviceSummary(...)`

- 用途：保存 BLE 扫描列表所需的精简设备信息。
- 参数：设备 `id`、广播名称 `name`、信号强度 `rssi`。

### `BleDeviceSummary.label`

- 用途：生成下拉列表展示文字。
- 返回：有名称时返回“名称 + RSSI”，没有名称时返回“设备 ID + RSSI”。
- 副作用：无。

---

## 3. `lib/device_control/control_router.dart`

### `ControlRouter({List<ControlBinding>? bindings})`

- 用途：创建遥控器动作路由器。
- 参数：可传入自定义映射；未传时使用 `defaultBindings`。
- 状态：内部保存上一帧、每个通道上次实际发出的值以及上次发送时间。

### `process(List<int> channels, DateTime now)`

- 用途：比较本次和上次 42 路 SRC 与 4 路 Trim 输入，生成本次真正需要发送的命令。
- 参数：`channels` 是当前 SRC 数组；`now` 用于限流和命令时间戳。
- 返回：`List<DeviceCommand>`；一帧可能同时产生多条命令，也可能为空。
- 流程：
  1. 保存当前帧，并使用第一帧初始化“上次实际发出值”；
  2. 第一帧只建立基准，不发送；
  3. 跳过越界映射；
  4. 相对上次实际发出值累计变化，跳过尚未超过阈值的 ADC 抖动；
  5. 跳过尚未达到最小发送间隔的连续变化；
  6. 将有效变化转换为 `DeviceCommand`。
- 副作用：更新 `_previous`、`_lastEmittedValues` 和 `_lastSent`。
- 扩展点：设备动作映射、去抖阈值和发送频率主要在此处调整。

### `manual(String action, int value)`

- 用途：把 UI 手动测试按钮转换成标准 `DeviceCommand`。
- 参数：动作名和原始值。
- 返回：来源固定为 `UI / manual` 的命令。
- 说明：手动命令和 AX12 命令随后走同一协议、队列和传输链路。

### `_normalize(int value)`

- 用途：将演示用的 AX12 数值按 `1024` 缩放到 `[-1, 1]`。
- 返回：归一化后的 `double`，超出范围时会截断。
- 注意：正式设备若使用 `0–100`、`0–255` 或其他范围，应按厂商协议修改。

---

## 4. `lib/device_control/device_protocol.dart`

### `DeviceProtocol.name`

- 用途：协议实现的可读名称，供页面展示。
- 实现要求：新协议必须提供。

### `DeviceProtocol.description`

- 用途：协议用途或格式说明，供页面展示。
- 实现要求：新协议必须提供。

### `DeviceProtocol.encode(DeviceCommand command)`

- 用途：协议层唯一核心接口，把业务命令编码成待发送字节。
- 参数：标准 `DeviceCommand`。
- 返回：`Uint8List`。
- 约束：不负责建立 Socket 或 BLE 连接；连接属于 `DeviceTransport`。

### `JsonLineDeviceProtocol.name`

- 返回：`JSON Line Demo v1`。

### `JsonLineDeviceProtocol.description`

- 返回：当前演示协议的中文描述。

### `JsonLineDeviceProtocol.encode(DeviceCommand command)`

- 用途：把命令编码为一行 UTF-8 JSON。
- 字段：`version`、递增的 `sequence`、`action`、`source`、`raw`、四位小数的 `normalized`、毫秒时间戳 `timestamp`。
- 返回：末尾带换行符的 UTF-8 字节。
- 副作用：每次调用将内部 `_sequence` 加一。
- 替换方式：拿到厂商帧头、命令字、字节序和校验规则后，新建另一个 `DeviceProtocol` 实现即可。

---

## 5. `lib/device_control/device_transport.dart`

### `DeviceTransport.name`

- 用途：返回当前通信链路名称，用于状态与日志展示。

### `DeviceTransport.events`

- 用途：向 Controller 输出接收数据、ACK、连接状态等文本事件。
- 返回：可被多处监听的 `Stream<String>`。

### `DeviceTransport.connect()`

- 用途：建立通信资源。
- 返回：成功时完成；失败时抛出异常，由 Controller 统一处理。

### `DeviceTransport.send(Uint8List data)`

- 用途：发送已经由协议层编码好的字节。
- 原则：Transport 不理解 `yaw`、`stop` 等业务含义。

### `DeviceTransport.disconnect()`

- 用途：取消订阅并释放 Socket、BLE 连接等资源。
- 要求：允许重复调用，未连接时也不应崩溃。

### `MockDeviceTransport.name`

- 返回：`模拟设备`。

### `MockDeviceTransport.events`

- 返回：模拟链路的广播事件流。

### `MockDeviceTransport.connect()`

- 用途：等待约 180 ms 模拟连接过程，然后标记为已连接并发出日志。
- 真实硬件：不参与。

### `MockDeviceTransport.send(Uint8List data)`

- 用途：模拟设备接收。
- 流程：检查连接状态，将字节尝试解析成 UTF-8，等待约 30 ms，然后发出 `ACK` 日志。
- 异常：未连接时抛出 `StateError`。

### `MockDeviceTransport.disconnect()`

- 用途：发出断开日志并清除连接标记。

### `UdpDeviceTransport(...)`

- 用途：保存目标主机和端口，创建 UDP Transport。
- 参数：`host` 可为 IPv4 地址或域名，`port` 为目标 UDP 端口。

### `UdpDeviceTransport.name`

- 返回：包含目标地址和端口的链路名称。

### `UdpDeviceTransport.events`

- 返回：UDP 接收和状态事件流。

### `UdpDeviceTransport.connect()`

- 用途：解析目标地址、绑定一个随机本地 IPv4 端口并开始监听回包。
- 接收：循环读取当前可用 Datagram，将内容按 UTF-8 显示为 `RX` 日志。
- 异常：域名无法解析或 Socket 无法绑定时抛出异常。
- 说明：UDP 无握手，因此“连接成功”表示本地 Socket 已就绪，不保证远端设备在线。

### `UdpDeviceTransport.send(Uint8List data)`

- 用途：向已解析的目标 IP 和端口发送一份 UDP 数据报。
- 校验：检查系统报告的发送字节数是否等于数据长度。
- 异常：未连接或发送不完整时抛出异常。

### `UdpDeviceTransport.disconnect()`

- 用途：取消 Socket 事件订阅、关闭 Socket，并清空目标地址。

### `BleGattDeviceTransport(...)`

- 用途：创建一个 BLE GATT 连接实例。
- 参数：设备 ID、Service UUID、写特征 UUID，以及可选 Notify 特征 UUID。
- 注意：这是 BLE GATT，不是经典蓝牙 SPP 串口。

### `BleGattDeviceTransport.name`

- 返回：包含设备 ID 的 BLE 链路名称。

### `BleGattDeviceTransport.events`

- 返回：BLE 连接状态、Notify 数据和错误事件流。

### `BleGattDeviceTransport.connect()`

- 用途：解析 UUID，连接指定 BLE 设备，发现需要的特征，并可选订阅 Notify。
- 流程：
  1. 解析 Service 和 Characteristic UUID；
  2. 调用 `connectToDevice`，连接超时为 12 秒；
  3. 等待状态变为 `connected`，总等待上限为 15 秒；
  4. 创建可写 `QualifiedCharacteristic`；
  5. 如果配置 Notify UUID，则订阅并把回包格式化为十六进制日志。
- 异常：UUID 格式错误、权限不足、设备不可达或超时均向上抛出。

### `BleGattDeviceTransport.send(Uint8List data)`

- 用途：通过写特征发送协议字节。
- 写入方式：当前使用 `writeCharacteristicWithResponse`，优先获得 GATT 写确认。
- 异常：未连接或写特征未就绪时抛出 `StateError`。
- 扩展：厂商要求无响应写入时，可改为 `writeCharacteristicWithoutResponse` 并配合限流。

### `BleGattDeviceTransport.disconnect()`

- 用途：取消 Notify 和连接订阅，清空写特征及连接标记。

### `BleGattDeviceTransport._hex(List<int> data)`

- 用途：把 BLE Notify 字节转为大写、空格分隔的十六进制文本。
- 示例：`[0x01, 0xAF]` 转为 `01 AF`。

### `BleDiscoveryService.scan({Duration duration})`

- 用途：扫描附近 BLE 广播并返回去重后的设备列表。
- 默认扫描时长：5 秒。
- Android 权限：请求定位、蓝牙扫描和蓝牙连接权限；在 Android 9 上还需要系统位置服务开启。
- 去重：按设备 ID 保存最后一次扫描结果。
- 排序：RSSI 从强到弱。
- 返回：`List<BleDeviceSummary>`。
- 异常：扫描流报错时抛出 `StateError`。

---

## 6. `lib/device_control/device_bridge_controller.dart`

### `DeviceBridgeController({required Stream<dynamic> ax12Events, DeviceProtocol? protocol, ControlRouter? router})`

- 用途：创建页面与业务逻辑之间的总控制器。
- 参数：必须提供 Android EventChannel 的 AX12 广播流；协议和路由器可按设备需要注入，未提供时使用 Demo 默认实现。
- 动作：立即订阅输入流，并把事件交给 `_onAx12Event`，错误交给 `_onAx12Error`。

### `isConnected`

- 用途：把 `linkState == connected` 封装成布尔值。
- 返回：当前是否可以发送。

### `connect(DeviceTransport transport)`

- 用途：切换并连接一个新的 Transport。
- 流程：先断开旧连接；设置 `connecting`；监听 Transport 事件；执行连接；成功后保存名称并设为 `connected`。
- 失败处理：保存错误、写错误日志、调用 Transport 断开，并将状态设为 `error`。
- UI：过程中多次 `notifyListeners()`，让页面实时刷新。

### `disconnect()`

- 用途：完整关闭当前设备连接。
- 流程：取消事件订阅、调用 Transport 的 `disconnect`、清空引用与名称、将状态设为 `disconnected`。
- 安全性：可在尚未连接时调用。

### `setAutomaticSending(bool value)`

- 用途：打开或暂停“AX12 操作自动发送”。
- 说明：关闭后 AX12 数据仍继续解析和显示，只是不入发送队列。

### `sendManual(String action, int value)`

- 用途：发送页面手动测试命令。
- 流程：用 `router.manual` 创建命令，更新最近输入，再加入统一发送队列。
- 异常：未连接时不会直接抛到 UI，而是在 `_send` 中记录错误。

### `clearLogs()`

- 用途：清空页面通信日志并通知 UI。

### `_onAx12Event(dynamic raw)`

- 用途：处理 EventChannel 的状态、错误和帧事件。
- 过滤：忽略非 Map、非 `frame`、缺少 `channels` 的数据；`error` 事件交给 `_onAx12Error`。
- 帧处理：将通道值转成整数，累计帧数，调用 `router.process` 生成命令。
- 自动发送：仅当自动发送开启且设备已连接时，将命令逐条加入队列。

### `_onAx12Error(Object error)`

- 用途：把串口/EventChannel 错误写入统一日志并刷新 UI。

### `_enqueue(DeviceCommand command)`

- 用途：将发送任务串行化。
- 原理：把新任务链接到 `_sendQueue.then(...)`，保证摇杆高频输入不会让多个异步写操作并发冲突。
- 返回：当前命令实际发送完成后结束。

### `_send(DeviceCommand command)`

- 用途：执行单条命令的协议编码和传输。
- 流程：检查连接；在同一个异常保护块内调用 `protocol.encode`、更新 `latestPacket` 并调用 Transport 发送；最后记录 TX 或失败日志。
- 容错：厂商协议编码失败会记录当前命令错误，但不会让串行发送队列永久进入失败状态。
- 分层：这是协议和 Transport 唯一汇合的位置。

### `_addLog(String message, {bool isError})`

- 用途：在日志头部插入新记录。
- 限制：最多保留 80 条，超出部分从尾部删除。
- 副作用：调用 `notifyListeners()`。

### `_preview(Uint8List bytes)`

- 用途：为页面日志生成协议字节预览。
- 当前行为：按 UTF-8 容错解码、去除首尾空白，超过 120 个字符时截断。
- 注意：正式二进制协议应改成十六进制预览，否则不可打印字节可能显示异常。

### `dispose()`

- 用途：Controller 销毁时取消 AX12 和 Transport 订阅、断开设备并调用父类清理。
- 调用时机：`DeviceControlPage.dispose()`。

---

## 7. `lib/device_control/device_control_page.dart`

### `DeviceControlPage(...)`

- 用途：创建设备连接与数据监控页面。
- 参数：共享的 AX12 事件流。

### `createState()`

- 用途：创建 `_DeviceControlPageState`，由 Flutter 管理页面生命周期。

### `initState()`

- 用途：初始化 `DeviceBridgeController` 并监听其变化。
- 结果：Controller 状态变化会触发 `_refresh` 重建页面。

### `_refresh()`

- 用途：Controller 通知时调用 `setState`。
- 安全：只有 Widget 仍为 `mounted` 时才刷新。

### `dispose()`

- 用途：移除监听、销毁 Controller 和所有 `TextEditingController`，避免流订阅或输入框资源泄漏。

### `build(BuildContext context)`

- 用途：构建设备控制页整体布局。
- 响应式：宽度至少 900 时左右双栏，否则单栏滚动。
- 组成：连接配置面板、协议/测试面板、输入与发送监视面板、顶部连接状态。

### `_buildConnectionPanel()`

- 用途：构建连接方式、连接参数、连接按钮、协议信息、自动发送开关和手动命令按钮。
- 状态：根据 `DeviceLinkKind` 动态显示 Mock、UDP 或 BLE 配置。
- 说明：该方法只组织 UI；真正连接交给 `_connect` 和 Controller。

### `_buildUdpFields()`

- 用途：构建 UDP 主机和端口输入框。
- 默认值：`192.168.1.100:9000`，仅为演示占位。

### `_buildBleFields()`

- 用途：构建 BLE 扫描按钮、设备选择框和 Service/Write/Notify UUID 输入框。
- 默认 UUID：使用常见 Nordic UART Service 风格示例，正式对接必须替换为设备厂商提供的 UUID。

### `_buildMonitorPanel()`

- 用途：构建运行监控区域。
- 展示：已接收 AX12 帧数、最新动作、原始值、归一化值、最近发送 JSON、当前映射表及通信日志。
- 日志：支持清空；错误日志使用不同颜色。

### `_connect()`

- 用途：根据用户选择创建正确的 Transport 并交给 Controller 连接。
- Mock：直接创建 `MockDeviceTransport`。
- UDP：校验端口必须在 `1–65535`，然后创建 `UdpDeviceTransport`。
- BLE：要求先选择扫描到的设备，再用页面 UUID 创建 `BleGattDeviceTransport`。
- 失败前置提示：参数不合法时调用 `_showMessage`，不会进入 Controller。

### `_scanBle()`

- 用途：执行 BLE 扫描并更新设备下拉列表。
- 状态：扫描开始时禁用按钮；完成后默认选择信号最强的第一个设备。
- 错误：通过 SnackBar 显示。
- 清理：`finally` 中恢复扫描按钮状态。

### `_showMessage(String message)`

- 用途：通过 `ScaffoldMessenger` 显示短暂 SnackBar。
- 安全：页面已卸载时直接返回。

### `_formatTime(DateTime value)`

- 用途：把时间格式化为 `HH:mm:ss`。

### `_StatusChip(...)`

- 用途：创建连接状态标签组件。

### `_StatusChip.build(BuildContext context)`

- 用途：将四种 `DeviceLinkState` 映射为中文文本和颜色并构建 Chip。

### `_InfoText(...)`

- 用途：创建统一样式的辅助说明文本组件。

### `_InfoText.build(BuildContext context)`

- 用途：按统一颜色和行高显示说明文本。

### `_MetricRow(...)`

- 用途：创建“标签 + 等宽值”的指标行。

### `_MetricRow.build(BuildContext context)`

- 用途：让固定宽度标签与可扩展值在一行对齐。

---

## 8. `lib/main.dart`

### `main()`

- 用途：Flutter 应用入口。
- 行为：调用 `runApp` 启动 `Ax12UmbusMonitorApp`。

### `Ax12UmbusMonitorApp(...)`

- 用途：创建根应用。
- 参数：测试时可注入 `eventStream`；实机运行时为空。

### `Ax12UmbusMonitorApp.build(BuildContext context)`

- 用途：创建共享 AX12 广播流、全局 Material 主题和首页。
- 实机：通过 `EventChannel('com.remotecontrol.remote/umbus')` 接收 Android 串口数据。
- 测试：优先使用注入的 Stream，避免依赖真实 Android 通道。

### `RemoteBridgeShell(...)`

- 用途：创建底部双页导航壳。

### `RemoteBridgeShell.createState()`

- 用途：创建保存当前导航索引的 State。

### `_RemoteBridgeShellState.build(BuildContext context)`

- 用途：构建“设备控制”和“AX12 输入”两个页面。
- 说明：使用 `IndexedStack` 保留切换前页面的状态和连接。

### `UmbusSnapshot(...)`

- 用途：创建一帧 Flutter 侧 AX12 快照。

### `UmbusSnapshot.fromMap(Map<dynamic, dynamic> data)`

- 用途：把 EventChannel 动态 Map 安全转换为强类型对象。
- 容错：无法转换的数值使用 `0`，缺失列表或 Map 使用空集合。
- 返回：包含序号、时间戳、四轴、42 路 SRC、4 路 Trim 和已知控件映射的快照。

### `ControlChange(...)`

- 用途：创建一条控件变化记录。
- 字段：控件名、变化前值、变化后值、发生时间。

### `UmbusMonitorPage(...)`

- 用途：创建 AX12 原始输入监听页面。
- 参数：可注入共享事件流；没有注入时自行打开 EventChannel。

### `UmbusMonitorPage.createState()`

- 用途：创建维护串口状态、最新快照和历史记录的 State。

### `_UmbusMonitorPageState.initState()`

- 用途：选择注入流或原生通道，并注册事件和错误回调。

### `_onEvent(dynamic raw)`

- 用途：处理 Android 发来的 `status`、`error` 和 `frame`。
- 帧处理：创建 `UmbusSnapshot`，与上一帧逐通道比较；SRC 使用阈值 2，T1–T4 使用阈值 0，将有效变化插入历史头部。
- 限制：最多保留 60 条控件变化。
- 页面状态：更新连接说明、错误和最新快照。

### `_onStreamError(Object error)`

- 用途：处理 EventChannel 自身的 Stream 错误并显示到页面。

### `dispose()`

- 用途：页面销毁时取消事件订阅。

### `build(BuildContext context)`

- 用途：根据 `_showDetails` 在简约页和详细页之间切换。

### `_buildSimplePage(BuildContext context)`

- 用途：构建默认简约监听页。
- 展示：最新一次有效操作，以及默认折叠的历史操作。
- 操作：支持清空记录和进入详细页。

### `_latestOutput()`

- 用途：生成简约页顶部的最新状态文本。
- 分支：错误、等待第一帧、尚无操作、已有最新操作四种状态。

### `_buildHistoryCard()`

- 用途：构建可展开/收起的历史操作卡片。
- 说明：最新一条已在顶部单独显示，因此历史从第二条开始。

### `_formatTime(DateTime time)`

- 用途：把时间格式化为 `HH:mm:ss`。

### `_buildDetailedPage(BuildContext context)`

- 用途：构建 AX12 详细诊断页。
- 组成：串口状态、四轴、已知控件、SRC00–SRC41、T1–T4、最近 60 条变化。

### `_StatusCard(...)` / `_StatusCard.build(...)`

- 用途：构建串口连接状态和错误信息卡片；根据是否有错误切换颜色与图标。

### `_GimbalCard(...)` / `_GimbalCard.build(...)`

- 用途：展示 Yaw、Pitch、Throttle、Roll 四轴原始值与归一化进度条。

### `_MappedControlsCard(...)` / `_MappedControlsCard.build(...)`

- 用途：展示当前已确认映射的 S1、S2、SA、SB、SC、SD、SF、6POS、SE、T1–T4 数值。

### `_ChannelGrid(...)` / `_ChannelGrid.build(...)`

- 用途：以网格展示 SRC00–SRC41 以及 T1–T4 的全部原始值，便于诊断控件映射。

### `_ChangesCard(...)` / `_ChangesCard.build(...)`

- 用途：在详细页展示控件变化列表、前后值和时间。

---

## 9. `android/app/src/main/kotlin/.../MainActivity.kt`

### `configureFlutterEngine(FlutterEngine flutterEngine)`

- 用途：注册名为 `com.remotecontrol.remote/umbus` 的 EventChannel。
- 结果：Dart 侧可以通过相同通道名订阅串口事件。

### `onListen(Any? arguments, EventSink? events)`

- 用途：Dart 开始监听时保存 `EventSink` 并启动串口读取线程。

### `onCancel(Any? arguments)`

- 用途：Dart 取消监听时停止串口读取并清空 `EventSink`。

### `onDestroy()`

- 用途：Activity 销毁时停止串口、关闭工作线程池，再执行父类销毁。

### `startSerialReader()`

- 用途：在单线程执行器中启动 AX12 串口会话。
- 防重入：`running` 已为 true 时直接返回。
- 流程：
  1. 检查 RadioMasterOS 是否可能占用串口；
  2. 配置接收触发阈值；
  3. 配置 `/dev/ttyS0` 为 `921600 8N1`；
  4. 打开输入和输出流；
  5. 启动轮询/心跳；
  6. 发送 listening 状态；
  7. 进入 `readFrames`。
- 清理：无论成功或异常，`finally` 都停止心跳、关闭流并恢复状态。

### `stopSerialReader()`

- 用途：主动停止串口会话。
- 流程：清除运行标记、停止心跳、关闭输入输出流、清空引用。
- 关闭流会使正在阻塞的读取退出。

### `startKeepAlive(FileOutputStream output)`

- 用途：按实机 RadioMasterOS 行为定时发送配置、心跳、保活和轮询帧，使 MCU 持续返回控制数据。
- 周期：每 500 ms 执行一次。
- 频率：配置与心跳交替；每 4 个 tick 发送额外 keep-alive；每个 tick 都发送 poll。
- 异常：写失败时通过 EventChannel 发送 `SERIAL_WRITE_FAILED`。
- 注意：这些帧来自当前 AX12 固件抓取，升级固件后应重新验证。

### `stopKeepAlive()`

- 用途：立即关闭心跳调度线程并清空引用。

### `configureSerialPort()`

- 用途：通过 `stty` 设置 `/dev/ttyS0`。
- 配置：921600 波特率、8 数据位、1 停止位、无奇偶校验、无硬件/软件流控、raw、关闭回显。
- 异常：命令退出码非 0 时抛出 `IOException`。

### `configureReceiveTrigger()`

- 用途：尝试把 MTK tty 驱动的 `rx_trig_bytes` 写为 32，匹配原厂应用初始化。
- 权限：通过 `su 0` 写 sysfs。
- 容错：失败会被忽略，仍继续尝试打开串口，因为某些固件已经预配置。

### `isRadioMasterOsRunning()`

- 用途：用 `pidof com.Flyshark.RadioMasterAX` 判断原厂应用是否运行。
- 返回：找到 PID 为 true；命令失败时保守返回 false。
- 原因：避免两个进程同时读取同一串口导致帧丢失或无法打开。

### `readFrames(FileInputStream input)`

- 用途：持续同步并读取 AX12 MCU 帧。
- 同步：寻找帧头 `0xA6`，随后要求帧长度为 `0x63`。
- 完整性：调用 `readFully` 补齐剩余字节。
- 类型过滤：仅接收前缀 `A6 63 10 02 04 01` 的当前固件控制数据帧。
- 输出：有效帧交给 `emitChannelFrame`。

### `readFully(FileInputStream input, ByteArray target, Int offset, Int length)`

- 用途：处理串口一次读取可能只返回部分字节的问题。
- 行为：循环读取，直到指定区域填满、流结束或 `running` 变为 false。
- 返回：完整读满为 true，否则 false。

### `emitChannelFrame(ByteArray frame)`

- 用途：解析有效控制帧并发送到 Flutter。
- 解析：从帧偏移 6 读取 42 个小端有符号 16 位 SRC；从偏移 90–93 读取 T1–T4 四个有符号 8 位 Trim 状态。
- 派生：前 4 个 SRC 为四轴；将 4 路 Trim 追加为统一列表的虚拟索引 42–45，并建立已知控件映射。
- 输出 Map：`type`、`sequence`、`timestamp`、`gimbals`、`channels`、`trims`、`mapped`、`status`。
- 副作用：帧序号 `sequence` 加一。

### `emitStatus(String state, String message)`

- 用途：构造 `type=status` 事件并交给统一 `emit`。

### `emitError(String code, String message)`

- 用途：构造 `type=error` 事件并交给统一 `emit`。

### `emit(Map<String, Any> value)`

- 用途：在 Android 主线程调用 `eventSink.success`。
- 原因：串口在后台线程读取，而 Flutter 平台通道回调应切回主线程。

### `unsigned(Byte value)`

- 用途：把 Kotlin 有符号 `Byte` 转为 `0–255` 的整数。

### `signed8(Byte value)`

- 用途：保留协议单字节的二进制补码符号，将 T1–T4 状态转换为 `-128–127`。

### `bytesOf(vararg Int values)`

- 用途：把多个十六进制整数方便地转换为 `ByteArray`，用于定义心跳与轮询帧。

### `signed16(ByteArray bytes, Int offset)`

- 用途：从指定偏移读取小端 16 位有符号整数。
- 流程：组合低字节和高字节；若值至少为 `0x8000`，减去 `0x10000` 得到负数。

---

## 10. 后续对接时优先修改的位置

| 需求 | 修改位置 | 通常不需要修改 |
|---|---|---|
| 厂商提供二进制协议 | 新建 `DeviceProtocol`，实现 `encode` | 串口读取、页面布局、UDP/BLE 基础连接 |
| 改遥控器动作对应关系 | `ControlRouter.defaultBindings` | 协议编码和连接实现 |
| 改数值范围 | `ControlRouter._normalize` 或新协议的 `encode` | Android 串口帧解析 |
| 改 BLE UUID | 页面默认值或设备配置文件 | ControlRouter |
| BLE 改无响应写 | `BleGattDeviceTransport.send` | UI 和协议 |
| 新增 TCP/HTTP/WebSocket/MQTT | 新建 `DeviceTransport` | AX12 输入和协议模型 |
| 更新视觉稿 | `device_control_page.dart` | Controller、Protocol、Transport |
| AX12 固件帧格式变化 | `MainActivity.readFrames`、`emitChannelFrame`、心跳帧 | 外部设备协议 |

## 11. Android 9 兼容说明

- App 的 `minSdk` 固定为 API 28，即 Android 9。
- BLE 扫描在 Android 9 上需要定位权限，并且系统“位置信息”开关需要开启。
- `compileSdk` 只决定编译时可用的 Android API，不等于最低运行版本；BLE 子模块用较新的 compileSdk 不会阻止 Android 9 安装。
- Manifest 同时保留 Android 9 使用的 `BLUETOOTH`、`BLUETOOTH_ADMIN`、`ACCESS_FINE_LOCATION` 和 `ACCESS_COARSE_LOCATION` 权限声明。
