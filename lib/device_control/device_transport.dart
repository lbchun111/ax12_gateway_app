import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'device_models.dart';

abstract class DeviceTransport {
  /// 返回链路的可读名称，供状态栏和日志展示。
  String get name;

  /// 返回接收数据、ACK、状态和错误信息组成的文本事件流。
  Stream<String> get events;

  /// 建立链路资源；连接失败时应抛出异常交由 Controller 处理。
  Future<void> connect();

  /// 发送已经由协议层编码好的 [data]，不解释业务动作含义。
  Future<void> send(Uint8List data);

  /// 取消订阅并释放链路资源；实现应允许重复调用。
  Future<void> disconnect();
}

class UnitreeDdsInterface {
  /// 创建Android网络接口视图模型。
  const UnitreeDdsInterface({
    required this.name,
    required this.displayName,
    required this.addresses,
    required this.supportsMulticast,
  });

  final String name;
  final String displayName;
  final List<String> addresses;
  final bool supportsMulticast;

  /// 返回包含接口名和IPv4地址的下拉框文本。
  String get label => '$name · ${addresses.join(', ')}';

  /// 从Android MethodChannel返回的Map构造接口信息。
  factory UnitreeDdsInterface.fromMap(Map<Object?, Object?> value) {
    return UnitreeDdsInterface(
      name: value['name']?.toString() ?? '',
      displayName: value['displayName']?.toString() ?? '',
      addresses: (value['addresses'] as List<Object?>? ?? const [])
          .map((address) => address.toString())
          .toList(growable: false),
      supportsMulticast: value['multicast'] == true,
    );
  }
}

class UnitreeDdsDeviceTransport implements DeviceTransport {
  /// 创建直接运行在Android上的Go2 CycloneDDS Transport。
  ///
  /// [interfaceName] 必须是连接Go2所在网段的Android网卡，例如 `eth0`。
  UnitreeDdsDeviceTransport({required this.interfaceName});

  static const _channel = MethodChannel('com.remotecontrol.remote/unitree_dds');
  static const _maximumForwardSpeed = 0.8;
  static const _maximumLateralSpeed = 0.5;
  static const _maximumYawSpeed = 1.5;
  static const _maximumPitchRadians = 0.3;
  static const _deadmanTimeout = Duration(milliseconds: 500);

  final String interfaceName;
  final _events = StreamController<String>.broadcast();
  final _axes = <String, double>{'throttle': 0, 'roll': 0, 'yaw': 0};
  Timer? _watchdog;
  Timer? _healthTimer;
  DateTime _lastMotion = DateTime.fromMillisecondsSinceEpoch(0);
  bool _connected = false;
  bool _armed = false;
  bool _healthCheckRunning = false;
  String? _serverApiVersion;

  /// 枚举Android当前可供CycloneDDS绑定的IPv4网络接口。
  static Future<List<UnitreeDdsInterface>> listInterfaces() async {
    final values = await _channel.invokeListMethod<Object?>('interfaces');
    return (values ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(UnitreeDdsInterface.fromMap)
        .where((item) => item.name.isNotEmpty)
        .toList(growable: false);
  }

  /// 返回DDS直连链路名称。
  @override
  String get name => 'Go2 DDS直连 · $interfaceName';

  /// 返回连接状态、ACK、错误和看门狗事件。
  @override
  Stream<String> get events => _events.stream;

  /// 绑定网卡、发现Sport服务并执行只读API版本检查。
  @override
  Future<void> connect() async {
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'connect',
      <String, Object>{'interface': interfaceName},
    );
    _serverApiVersion = response?['serverApiVersion']?.toString();
    _connected = response?['connected'] == true;
    if (!_connected) throw StateError('Android DDS未连接Go2');
    _armed = false;
    _axes.updateAll((_, _) => 0);
    _lastMotion = DateTime.now();
    _startSafetyTimers();
    _emitStatus('ready');
  }

  /// 解析统一JSON命令并映射到最小Go2 Sport API白名单。
  @override
  Future<void> send(Uint8List data) async {
    if (!_connected) throw StateError('Android DDS尚未连接Go2');
    final decoded = jsonDecode(utf8.decode(data, allowMalformed: false));
    if (decoded is! Map) throw const FormatException('DDS命令必须是JSON对象');
    final action = decoded['action']?.toString() ?? '';
    final normalized = (decoded['normalized'] as num?)?.toDouble() ?? 0;
    final sequence = (decoded['sequence'] as num?)?.toInt();

    switch (action) {
      case 'arm':
        await _call(1027, const <String, Object>{'data': false});
        _armed = true;
      case 'switch_sa':
      case 'switch_sb':
      case 'switch_sc':
      case 'switch_sd':
      case 'switch_se':
      case 'switch_sf':
      case 'switch_6pos':
        // 摇杆帧可能让这些 SRC 拨杆值成批误跳变；只监视，不控制机器人。
        return;
      case 'disarm':
      case 'stop':
      case 'emergency_stop':
        await _stop(disarm: true);
      case 'motion_stop':
        await _stop(disarm: false);
      case 'trim_t1':
      case 'stand_up':
        await _posture(1004, disarmAfter: false);
      case 'trim_t2':
      case 'stand_down':
        await _posture(1005, disarmAfter: true);
      case 'trim_t3':
      case 'balance_stand':
        await _posture(1002, disarmAfter: false);
      case 'trim_t4':
      case 'recovery_stand':
        await _posture(1006, disarmAfter: false);
      case 'damp':
        await _posture(1001, disarmAfter: true);
      case 'throttle':
      case 'roll':
      case 'yaw':
        _axes[action] = _deadband(normalized);
        await _sendVelocity();
      case 'pitch':
        _requireArmed('pitch');
        await _call(1007, <String, double>{
          'x': 0,
          'y': _deadband(normalized) * _maximumPitchRadians,
          'z': 0,
        });
        _lastMotion = DateTime.now();
      case 'move_forward':
        _axes['throttle'] = normalized.clamp(0, 1);
        await _sendVelocity();
      case 'move_backward':
        _axes['throttle'] = normalized.clamp(-1, 0);
        await _sendVelocity();
      case 'turn_left':
        _axes['yaw'] = normalized.clamp(-1, 0);
        await _sendVelocity();
      case 'turn_right':
        _axes['yaw'] = normalized.clamp(0, 1);
        await _sendVelocity();
      default:
      // 未映射的旋钮/开关继续显示在UI，但不得进入机器人Sport接口。
    }
    _emitStatus('ack', sequence: sequence, action: action);
  }

  /// 先发送零速度，再关闭DDS实体并取消安全定时器。
  @override
  Future<void> disconnect() async {
    _watchdog?.cancel();
    _healthTimer?.cancel();
    _watchdog = null;
    _healthTimer = null;
    if (_connected) {
      try {
        await _call(1008, const <String, double>{
          'x': 0,
          'y': 0,
          'z': 0,
        }, noReply: true);
        await _call(1027, const <String, Object>{'data': true});
      } catch (_) {
        // 物理链路可能已经断开，仍必须继续释放本地DDS实体。
      }
    }
    await _channel.invokeMethod<void>('close');
    _connected = false;
    _armed = false;
    _axes.updateAll((_, _) => 0);
  }

  /// 调用姿态API；未解锁时拒绝，执行后按需重新锁定。
  Future<void> _posture(int apiId, {required bool disarmAfter}) async {
    _requireArmed('posture/$apiId');
    _axes.updateAll((_, _) => 0);
    await _call(apiId, const <String, Object>{});
    if (disarmAfter) {
      try {
        await _call(1027, const <String, Object>{'data': true});
      } finally {
        _armed = false;
      }
    }
  }

  /// 将三轴归一化输入乘以安全上限后调用Go2 Move。
  Future<void> _sendVelocity() async {
    _requireArmed('move');
    await _call(1008, <String, double>{
      'x': _axes['throttle']! * _maximumForwardSpeed,
      'y': _axes['roll']! * _maximumLateralSpeed,
      'z': _axes['yaw']! * _maximumYawSpeed,
    }, noReply: true);
    _lastMotion = DateTime.now();
  }

  /// 发送零速度，并根据[disarm]决定是否重新锁定遥操作。
  Future<void> _stop({required bool disarm}) async {
    _axes.updateAll((_, _) => 0);
    await _call(1008, const <String, double>{
      'x': 0,
      'y': 0,
      'z': 0,
    }, noReply: true);
    _lastMotion = DateTime.now();
    if (disarm) {
      try {
        await _call(1027, const <String, Object>{'data': true});
      } finally {
        _armed = false;
      }
    }
  }

  /// 通过MethodChannel执行单条Sport API调用。
  Future<String> _call(
    int apiId,
    Map<String, Object> parameter, {
    bool noReply = false,
  }) async {
    final response = await _channel
        .invokeMapMethod<Object?, Object?>('call', <String, Object>{
          'apiId': apiId,
          'parameter': jsonEncode(parameter),
          'noReply': noReply,
          'timeoutMs': noReply ? 1000 : 2500,
        });
    return response?['data']?.toString() ?? '';
  }

  /// 未解锁时拒绝所有会改变机器人运动状态的命令。
  void _requireArmed(String action) {
    if (!_armed) throw StateError('DDS直连控制器未解锁，已拒绝 $action');
  }

  /// 启动0.5秒失联停止和2秒Sport服务健康检查。
  void _startSafetyTimers() {
    _watchdog?.cancel();
    _healthTimer?.cancel();
    _watchdog = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final moving = _axes.values.any((value) => value != 0);
      if (_connected &&
          _armed &&
          moving &&
          DateTime.now().difference(_lastMotion) > _deadmanTimeout) {
        try {
          await _stop(disarm: false);
          _events.add('DDS 看门狗已发送零速度');
        } catch (error) {
          _markDisconnected(error);
        }
      }
    });
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_connected || _healthCheckRunning) return;
      _healthCheckRunning = true;
      try {
        _serverApiVersion = await _call(1, const <String, Object>{});
      } catch (error) {
        _markDisconnected(error);
      } finally {
        _healthCheckRunning = false;
      }
    });
  }

  /// 将运行期 DDS 错误转换为断开事件。
  ///
  /// Controller 收到后保持错误状态，不会自动重连 DDS；
  /// 用户可以在检查网络后手动再次连接。
  void _markDisconnected(Object error) {
    if (!_connected) return;
    _connected = false;
    _armed = false;
    _axes.updateAll((_, _) => 0);
    _events.add('DDS连接已断开 $error');
  }

  /// 把中心8%范围内的摇杆抖动归零，并限制到[-1,1]。
  static double _deadband(double value) {
    if (value.abs() < 0.08) return 0;
    return value.clamp(-1, 1).toDouble();
  }

  /// 发布与网关状态结构兼容的JSON，复用现有UI状态解析。
  void _emitStatus(String type, {int? sequence, String? action}) {
    _events.add(
      'DDS $type  ${jsonEncode(<String, Object?>{
        'type': type,
        'sequence': sequence,
        'action': action,
        'armed': _armed,
        'axes': _axes,
        'driver': 'android-cyclonedds',
        'robot': <String, Object?>{'connected': _connected, 'networkInterface': interfaceName, 'robotIp': '192.168.123.161', 'serverApiVersion': _serverApiVersion, 'connectionError': null},
      })}',
    );
  }
}

class UnitreeGatewayTransport implements DeviceTransport {
  /// 创建连接笔记本 Python 网关的 WebSocket Transport。
  ///
  /// [host] 应填写 Windows 笔记本的局域网 IP；[token] 必须与网关的
  /// `GATEWAY_TOKEN` 一致，网关未配置令牌时可以留空。
  UnitreeGatewayTransport({
    required this.host,
    required this.port,
    this.token = '',
    this.secure = false,
  });

  final String host;
  final int port;
  final String token;
  final bool secure;
  final _events = StreamController<String>.broadcast();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Completer<void>? _readyCompleter;

  /// 返回包含 WebSocket 地址的链路名称。
  @override
  String get name => '宇树网关 ${secure ? 'wss' : 'ws'}://$host:$port';

  /// 返回网关 ready、ACK、状态、错误和断开事件。
  @override
  Stream<String> get events => _events.stream;

  /// 建立 WebSocket，完成 hello/ready 握手，并启动五秒心跳。
  @override
  Future<void> connect() async {
    final scheme = secure ? 'wss' : 'ws';
    final uri = Uri.parse('$scheme://$host:$port');
    final socket = await WebSocket.connect(uri.toString()).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('连接宇树网关超时'),
    );
    _socket = socket;
    _readyCompleter = Completer<void>();
    _subscription = socket.listen(
      _handleMessage,
      onError: (Object error) {
        if (!(_readyCompleter?.isCompleted ?? true)) {
          _readyCompleter?.completeError(error);
        }
        _events.add('WebSocket 错误 $error');
      },
      onDone: () {
        if (!(_readyCompleter?.isCompleted ?? true)) {
          _readyCompleter?.completeError(StateError('网关在握手前断开'));
        }
        _events.add('网关连接已断开 code=${socket.closeCode}');
      },
      cancelOnError: false,
    );
    socket.add(
      jsonEncode(<String, Object>{
        'type': 'hello',
        'protocol': 'ax12-unitree-v1',
        'clientId': 'ax12-android',
        'token': token,
      }),
    );
    await _readyCompleter!.future.timeout(const Duration(seconds: 5));
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_socket?.readyState == WebSocket.open) {
        _socket?.add(
          jsonEncode(<String, Object>{
            'type': 'ping',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        _socket?.add(jsonEncode(<String, Object>{'type': 'status'}));
      }
    });
  }

  /// 发送协议层生成的 JSON 命令；未连接时抛出明确状态错误。
  @override
  Future<void> send(Uint8List data) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('宇树网关尚未连接');
    }
    socket.add(utf8.decode(data, allowMalformed: false).trim());
  }

  /// 停止心跳、取消订阅并正常关闭 WebSocket。
  @override
  Future<void> disconnect() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close(WebSocketStatus.normalClosure, 'app disconnect');
    }
    _readyCompleter = null;
  }

  /// 解析网关 JSON，完成 ready 握手并把其余响应转成可读日志。
  void _handleMessage(dynamic raw) {
    final text = raw is List<int>
        ? utf8.decode(raw, allowMalformed: true)
        : raw.toString();
    try {
      final value = jsonDecode(text);
      if (value is! Map) throw const FormatException('根节点不是对象');
      final type = value['type']?.toString() ?? 'unknown';
      if (type == 'ready' && !(_readyCompleter?.isCompleted ?? true)) {
        _readyCompleter?.complete();
      }
      if (type != 'pong') {
        _events.add('网关 $type  $text');
      }
    } catch (error) {
      _events.add('网关返回无法解析: $text ($error)');
    }
  }
}

class MockDeviceTransport implements DeviceTransport {
  final _events = StreamController<String>.broadcast();
  bool _connected = false;

  /// 返回模拟链路名称。
  @override
  String get name => '模拟设备';

  /// 返回模拟设备产生的广播事件流。
  @override
  Stream<String> get events => _events.stream;

  /// 模拟约 180 ms 的连接延迟，然后发出“已连接”事件。
  @override
  Future<void> connect() async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    _connected = true;
    _events.add('模拟设备已连接');
  }

  /// 模拟接收字节并返回 ACK；未连接时抛出 [StateError]。
  @override
  Future<void> send(Uint8List data) async {
    if (!_connected) throw StateError('模拟设备尚未连接');
    final text = utf8.decode(data, allowMalformed: true).trim();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    _events.add('ACK $text');
  }

  /// 清除模拟连接标记，并在需要时发出断开事件。
  @override
  Future<void> disconnect() async {
    if (_connected) _events.add('模拟设备已断开');
    _connected = false;
  }
}

class UdpDeviceTransport implements DeviceTransport {
  /// 创建发往 [host]:[port] 的 UDP 单播链路。
  UdpDeviceTransport({required this.host, required this.port});

  final String host;
  final int port;
  final _events = StreamController<String>.broadcast();
  RawDatagramSocket? _socket;
  InternetAddress? _target;
  StreamSubscription<RawSocketEvent>? _subscription;

  /// 返回包含目标主机与端口的链路名称。
  @override
  String get name => 'Wi-Fi UDP $host:$port';

  /// 返回 UDP 回包和本地状态组成的广播事件流。
  @override
  Stream<String> get events => _events.stream;

  /// 解析目标地址、绑定随机本地 IPv4 端口，并开始读取 UDP 回包。
  ///
  /// UDP 没有握手；本方法成功只表示本地 Socket 已就绪。
  @override
  Future<void> connect() async {
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) throw SocketException('无法解析地址 $host');
    _target = addresses.first;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    _socket = socket;
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final packet = datagram!;
        final text = utf8.decode(packet.data, allowMalformed: true).trim();
        _events.add('RX ${packet.address.address}:${packet.port}  $text');
      }
    });
    _events.add('UDP 本地端口 ${socket.port} 已就绪');
  }

  /// 向目标地址发送一份 UDP 数据报，并校验实际发送字节数。
  @override
  Future<void> send(Uint8List data) async {
    final socket = _socket;
    final target = _target;
    if (socket == null || target == null) throw StateError('UDP 尚未连接');
    final count = socket.send(data, target, port);
    if (count != data.length) {
      throw SocketException('UDP 仅发送 $count/${data.length} 字节');
    }
  }

  /// 停止监听、关闭 UDP Socket 并清空目标地址。
  @override
  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _target = null;
  }
}

class BleGattDeviceTransport implements DeviceTransport {
  /// 创建 BLE GATT 链路。
  ///
  /// [notifyCharacteristicUuid] 为空时只写不订阅设备回包。
  BleGattDeviceTransport({
    required this.deviceId,
    required this.serviceUuid,
    required this.writeCharacteristicUuid,
    this.notifyCharacteristicUuid,
  });

  final String deviceId;
  final String serviceUuid;
  final String writeCharacteristicUuid;
  final String? notifyCharacteristicUuid;
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final _events = StreamController<String>.broadcast();
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _notificationSubscription;
  QualifiedCharacteristic? _writeCharacteristic;
  bool _connected = false;

  /// 返回包含 BLE 设备 ID 的链路名称。
  @override
  String get name => 'BLE GATT $deviceId';

  /// 返回 BLE 连接状态、Notify 回包和错误组成的事件流。
  @override
  Stream<String> get events => _events.stream;

  /// 连接设备、发现写特征，并按需订阅 Notify 特征。
  ///
  /// 连接超时或 UUID 非法时抛出异常；成功后写特征才可用于 [send]。
  @override
  Future<void> connect() async {
    final service = Uuid.parse(serviceUuid.trim());
    final writeUuid = Uuid.parse(writeCharacteristicUuid.trim());
    final completer = Completer<void>();

    _connectionSubscription = _ble
        .connectToDevice(
          id: deviceId,
          servicesWithCharacteristicsToDiscover: {
            service: [
              writeUuid,
              if (notifyCharacteristicUuid?.trim().isNotEmpty ?? false)
                Uuid.parse(notifyCharacteristicUuid!.trim()),
            ],
          },
          connectionTimeout: const Duration(seconds: 12),
        )
        .listen(
          (update) {
            _events.add('BLE 状态 ${update.connectionState.name}');
            if (update.connectionState == DeviceConnectionState.connected) {
              _connected = true;
              if (!completer.isCompleted) completer.complete();
            } else if (update.connectionState ==
                DeviceConnectionState.disconnected) {
              _connected = false;
            }
          },
          onError: (Object error) {
            if (!completer.isCompleted) completer.completeError(error);
            _events.add('BLE 错误 $error');
          },
        );

    await completer.future.timeout(const Duration(seconds: 15));
    _writeCharacteristic = QualifiedCharacteristic(
      serviceId: service,
      characteristicId: writeUuid,
      deviceId: deviceId,
    );

    final notify = notifyCharacteristicUuid?.trim();
    if (notify != null && notify.isNotEmpty) {
      final characteristic = QualifiedCharacteristic(
        serviceId: service,
        characteristicId: Uuid.parse(notify),
        deviceId: deviceId,
      );
      _notificationSubscription = _ble
          .subscribeToCharacteristic(characteristic)
          .listen(
            (data) => _events.add('BLE RX ${_hex(data)}'),
            onError: (Object error) => _events.add('BLE Notify 错误 $error'),
          );
    }
  }

  /// 使用 Write With Response 向已解析的 GATT 写特征发送 [data]。
  ///
  /// 厂商若要求无响应写入，应在此替换 API，并同步配置发送限流。
  @override
  Future<void> send(Uint8List data) async {
    final characteristic = _writeCharacteristic;
    if (!_connected || characteristic == null) throw StateError('BLE 尚未连接');
    await _ble.writeCharacteristicWithResponse(characteristic, value: data);
  }

  /// 取消 Notify 与连接订阅，并清除连接状态和写特征引用。
  @override
  Future<void> disconnect() async {
    _connected = false;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _writeCharacteristic = null;
  }

  /// 将 Notify 字节转换成大写、空格分隔的十六进制文本。
  static String _hex(List<int> data) => data
      .map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

class BleDiscoveryService {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  /// 在 [duration] 内扫描 BLE 广播，按设备 ID 去重并按 RSSI 降序返回。
  ///
  /// Android 会先请求定位、扫描和连接权限；Android 9 还要求系统位置
  /// 服务处于开启状态。扫描流出错时抛出 [StateError]。
  Future<List<BleDeviceSummary>> scan({
    Duration duration = const Duration(seconds: 5),
  }) async {
    if (Platform.isAndroid) {
      await <Permission>[
        Permission.locationWhenInUse,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    }

    final devices = <String, BleDeviceSummary>{};
    Object? scanError;
    final subscription = _ble
        .scanForDevices(withServices: const [], scanMode: ScanMode.lowLatency)
        .listen((device) {
          devices[device.id] = BleDeviceSummary(
            id: device.id,
            name: device.name,
            rssi: device.rssi,
          );
        }, onError: (Object error) => scanError = error);
    await Future<void>.delayed(duration);
    await subscription.cancel();
    if (scanError != null) throw StateError('BLE 扫描失败: $scanError');
    final result = devices.values.toList()
      ..sort((left, right) => right.rssi.compareTo(left.rssi));
    return result;
  }
}
