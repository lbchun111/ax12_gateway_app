import 'dart:convert';
import 'dart:typed_data';

import 'device_models.dart';

abstract interface class DeviceProtocol {
  /// 返回协议的可读名称，供页面和日志展示。
  String get name;

  /// 返回协议格式或用途说明，供二次开发人员识别当前实现。
  String get description;

  /// 将与链路无关的 [command] 编码成可直接发送的字节。
  ///
  /// 实现中只负责帧格式、命令字、字节序和校验，不建立网络或 BLE 连接。
  Uint8List encode(DeviceCommand command);
}

/// The default demo protocol. Replace this class when a device vendor provides
/// a binary frame, checksum, HTTP schema, or other command specification.
class JsonLineDeviceProtocol implements DeviceProtocol {
  int _sequence = 0;

  /// 返回当前 Demo 协议名称。
  @override
  String get name => 'JSON Line Demo v1';

  /// 返回当前 Demo 协议的简短说明。
  @override
  String get description => '每次操作编码为一行 UTF-8 JSON，便于联调和抓包。';

  /// 将命令编码成一行带序号和毫秒时间戳的 UTF-8 JSON。
  ///
  /// 每次调用都会递增内部序号，返回数据以换行符结尾。
  @override
  Uint8List encode(DeviceCommand command) {
    _sequence += 1;
    final json = jsonEncode(<String, Object>{
      'type': 'command',
      'protocol': 'ax12-unitree-v1',
      'version': 1,
      'sequence': _sequence,
      'action': command.action,
      'source': command.source,
      'raw': command.rawValue,
      'normalized': double.parse(command.normalizedValue.toStringAsFixed(4)),
      'timestamp': command.timestamp.millisecondsSinceEpoch,
    });
    return Uint8List.fromList(utf8.encode('$json\n'));
  }
}
