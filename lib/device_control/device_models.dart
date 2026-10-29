import 'dart:typed_data';

enum DeviceLinkKind { mock, unitreeGateway, unitreeDds, wifiUdp, bleGatt }

enum DeviceLinkState { disconnected, connecting, connected, error }

class DeviceCommand {
  /// 创建一条与通信方式无关的业务命令。
  ///
  /// [action] 是设备动作名，[source] 是输入来源，[rawValue] 是原始值，
  /// [normalizedValue] 是归一化值，[timestamp] 是动作产生时间。
  const DeviceCommand({
    required this.action,
    required this.source,
    required this.rawValue,
    required this.normalizedValue,
    required this.timestamp,
  });

  final String action;
  final String source;
  final int rawValue;
  final double normalizedValue;
  final DateTime timestamp;
}

class ControlBinding {
  /// 创建一条 AX12 SRC 通道到业务动作的映射规则。
  ///
  /// [changeThreshold] 用于过滤 ADC 抖动，[minimumInterval] 用于限制
  /// 连续模拟量的最大发送频率。
  const ControlBinding({
    required this.sourceIndex,
    required this.sourceName,
    required this.action,
    this.changeThreshold = 2,
    this.minimumInterval = const Duration(milliseconds: 50),
    this.repeatInterval,
  });

  final int sourceIndex;
  final String sourceName;
  final String action;
  final int changeThreshold;
  final Duration minimumInterval;

  /// 摇杆保持在非中心位置时的续发间隔；为空表示只在数值变化时发送。
  final Duration? repeatInterval;
}

class OutboundPacket {
  /// 将原始业务命令和协议编码后的字节组合成一条发送记录。
  const OutboundPacket({required this.command, required this.bytes});

  final DeviceCommand command;
  final Uint8List bytes;
}

class BridgeLogEntry {
  /// 创建一条连接、接收或发送日志；[isError] 标识是否按错误样式显示。
  const BridgeLogEntry(this.time, this.message, {this.isError = false});

  final DateTime time;
  final String message;
  final bool isError;
}

class BleDeviceSummary {
  /// 创建 BLE 扫描结果的精简视图模型。
  const BleDeviceSummary({
    required this.id,
    required this.name,
    required this.rssi,
  });

  final String id;
  final String name;
  final int rssi;

  /// 返回设备下拉框文本；无广播名称时改用设备 ID。
  String get label => name.isEmpty ? '$id  ($rssi dBm)' : '$name  ($rssi dBm)';
}
