# AX12 UMBUS 控件监听与设备控制 Demo

这是一个面向 RadioMaster AX12（Android 9）的 Flutter/Android 示例项目。应用直接读取 `/dev/ttyS0` 上的 UMBUS `A6 63 10 02 04 01` 控制帧，并可把不同遥控操作通过 Mock、UDP 或 BLE GATT 协议转发给外部设备。

## 当前功能

- 读取 42 路有符号 16 位 SRC，包括摇杆、拨杆、旋钮和六段开关。
- 从帧偏移 90–93 单独读取 T1、T2、T3、T4 四路有符号 8 位 Trim 状态。
- 默认页面仅显示最新操作，并提供可折叠的历史操作记录。
- 详细页面显示四轴、已知映射以及全部原始输入。
- 设备控制 Demo 将 UI、控制映射、设备协议和连接传输分层，方便二次开发。
- 最低 Android 版本为 Android 9（API 28）。

T1–T4 不是 Android `KeyEvent`，也不属于 `SRC00–SRC41`。项目把它们追加为统一输入列表的虚拟索引 42–45，供 UI 和设备动作路由使用。

## 文档

- `AX12_串口协议与按钮读取指南.md`：串口、帧结构、T1–T4 位置和接入流程。
- `DEVICE_INTEGRATION_DEMO.md`：BLE、Wi-Fi 与后续厂商协议对接。
- `METHOD_REFERENCE.md`：项目方法级说明。

## 构建

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```
