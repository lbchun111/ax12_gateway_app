import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ax12_gateway_app/device_control/control_router.dart';
import 'package:ax12_gateway_app/device_control/device_bridge_controller.dart';
import 'package:ax12_gateway_app/device_control/device_control_page.dart';
import 'package:ax12_gateway_app/device_control/device_models.dart';
import 'package:ax12_gateway_app/device_control/device_protocol.dart';
import 'package:ax12_gateway_app/device_control/device_transport.dart';
import 'package:ax12_gateway_app/main.dart';
import 'package:ax12_gateway_app/ax12_sources.dart';

class _ThrowOnceProtocol implements DeviceProtocol {
  bool _shouldThrow = true;

  @override
  String get name => 'throw-once';

  @override
  String get description => '测试首次编码失败后队列能否继续发送';

  @override
  Uint8List encode(DeviceCommand command) {
    if (_shouldThrow) {
      _shouldThrow = false;
      throw const FormatException('模拟编码失败');
    }
    return Uint8List.fromList([command.rawValue & 0xFF]);
  }
}

class _GatewayStatusTransport implements DeviceTransport {
  final _events = StreamController<String>.broadcast(sync: true);

  @override
  String get name => '测试宇树网关';

  @override
  Stream<String> get events => _events.stream;

  @override
  Future<void> connect() async {
    emit(
      '网关 ready  {"type":"ready","armed":false,'
      '"robot":{"connected":false,"connectionError":"Go2 不可达",'
      '"serverApiVersion":null}}',
    );
  }

  void emit(String message) => _events.add(message);

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> disconnect() async {}
}

class _ControllableGatewayTransport implements DeviceTransport {
  _ControllableGatewayTransport(this.label, {this.connectGate});

  final String label;
  final Completer<void>? connectGate;
  final _events = StreamController<String>.broadcast(sync: true);
  int connectCount = 0;
  int disconnectCount = 0;

  @override
  String get name => label;

  @override
  Stream<String> get events => _events.stream;

  @override
  Future<void> connect() async {
    connectCount += 1;
    await connectGate?.future;
  }

  void emit(String message) => _events.add(message);

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> disconnect() async {
    disconnectCount += 1;
  }

  Future<void> close() => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('设备控制页当前只展示宇树网关连接方式', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);

    await tester.pumpWidget(
      MaterialApp(home: DeviceControlPage(ax12Events: events.stream)),
    );

    expect(find.text('笔记本网关'), findsOneWidget);
    expect(find.text('Android DDS直连'), findsNothing);
    expect(find.text('Wi-Fi'), findsNothing);
    expect(find.text('BLE'), findsNothing);
    expect(find.text('模拟'), findsNothing);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('手动控制'), findsOneWidget);
    expect(find.text('状态与日志'), findsOneWidget);

    await tester.tap(find.text('手动控制'));
    await tester.pumpAndSettle();
    expect(find.text('后退'), findsOneWidget);
    expect(find.text('右转'), findsOneWidget);
    expect(find.text('停止移动'), findsOneWidget);
    expect(find.textContaining('请先连接 Go2 并点击“解锁并准备运动”'), findsOneWidget);

    await tester.tap(find.text('状态与日志'));
    await tester.pumpAndSettle();
    expect(find.text('实时链路'), findsOneWidget);
  });

  test('Android DDS只开放Sport白名单，并按限速映射站起和摇杆', () async {
    const channel = MethodChannel('com.remotecontrol.remote/unitree_dds');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'connect' => <String, Object>{
              'connected': true,
              'serverApiVersion': 'test-version',
            },
            'call' => <String, Object>{'code': 0, 'data': ''},
            'close' => null,
            _ => throw PlatformException(code: 'unexpected'),
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final transport = UnitreeDdsDeviceTransport(interfaceName: 'eth0');
    addTearDown(transport.disconnect);
    final protocol = JsonLineDeviceProtocol();
    await transport.connect();
    await transport.send(
      protocol.encode(
        DeviceCommand(
          action: 'arm',
          source: 'test',
          rawValue: 1024,
          normalizedValue: 1,
          timestamp: DateTime(2026),
        ),
      ),
    );
    await transport.send(
      protocol.encode(
        DeviceCommand(
          action: 'stand_up',
          source: 'test',
          rawValue: 1024,
          normalizedValue: 1,
          timestamp: DateTime(2026),
        ),
      ),
    );
    await transport.send(
      protocol.encode(
        DeviceCommand(
          action: 'throttle',
          source: 'test',
          rawValue: 512,
          normalizedValue: 0.5,
          timestamp: DateTime(2026),
        ),
      ),
    );

    final sportCalls = calls.where((call) => call.method == 'call').toList();
    expect(sportCalls[0].arguments['apiId'], 1027);
    expect(
      jsonDecode(sportCalls[0].arguments['parameter'] as String)['data'],
      isFalse,
    );
    expect(sportCalls[1].arguments['apiId'], 1004);
    expect(sportCalls[2].arguments['apiId'], 1008);
    final move = jsonDecode(sportCalls[2].arguments['parameter'] as String);
    expect(move['x'], 0.4);
    expect(move['y'], 0.0);
    expect(move['z'], 0.0);
  });

  testWidgets('42路映射从有效SRC更新，未启用值显示状态文本', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    await tester.pumpWidget(Ax12UmbusMonitorApp(eventStream: events.stream));
    final channels = List<int>.filled(46, Ax12Sources.invalid)
      ..[12] = -289
      ..[13] = 500
      ..[20] = -500;
    events.add({
      'type': 'frame', 'sequence': 1, 'timestamp': 1,
      'gimbals': <int>[0, 0, 0, 0], 'channels': channels,
      // 模拟旧原生 mapped 数据，详细卡片仍应使用正确的 channels 索引。
      'mapped': {'S1': -32768, 'S2': -32768},
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('详细'));
    await tester.pumpAndSettle();
    expect(find.text('-289'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    expect(find.text('未启用'), findsWidgets);
    channels[12] = 117;
    channels[13] = -213;
    events.add({
      'type': 'frame',
      'sequence': 2,
      'timestamp': 2,
      'gimbals': <int>[0, 0, 0, 0],
      'channels': List<int>.from(channels),
    });
    await tester.pumpAndSettle();
    expect(find.text('117'), findsOneWidget);
    expect(find.text('-213'), findsOneWidget);
    expect(find.text('-289'), findsNothing);
  });

  test('所有默认控件绑定与42路映射一致，无效值不生成设备命令', () {
    expect(
      ControlRouter.defaultBindings.any(
        (binding) => binding.action.startsWith('switch_'),
      ),
      isFalse,
      reason: '拨杆快照可能随摇杆成批误跳变，默认映射不得控制机器人',
    );
    for (final binding in ControlRouter.defaultBindings.where(
      (b) => b.sourceIndex >= 4,
    )) {
      expect(
        binding.sourceName.split(' / ').first,
        Ax12Sources.controls[binding.sourceIndex],
      );
    }
    final router = ControlRouter();
    final now = DateTime(2026, 10, 22);
    final channels = List<int>.filled(46, Ax12Sources.invalid);
    expect(router.process(channels, now), isEmpty);
    channels[12] = 0;
    expect(router.process(channels, now), isEmpty);
    channels[12] = 100;
    final commands = router.process(channels, now);
    expect(commands.single.action, 'knob_s1');
    expect(commands.single.rawValue, 100);
    channels[12] = Ax12Sources.invalid;
    expect(
      router.process(channels, now.add(const Duration(seconds: 1))),
      isEmpty,
    );
    channels[12] = 200;
    expect(
      router.process(channels, now.add(const Duration(seconds: 2))),
      isEmpty,
    );
  });

  testWidgets('T1 单次变化会显示在最新操作和详细页', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);

    await tester.pumpWidget(Ax12UmbusMonitorApp(eventStream: events.stream));
    expect(find.text('AX12 控件监听'), findsOneWidget);

    final initialChannels = List<int>.generate(46, (index) => 1000 + index)
      ..setRange(42, 46, const [0, 0, 0, 0]);
    events.add(<String, dynamic>{
      'type': 'frame',
      'sequence': 42,
      'timestamp': 12345,
      'gimbals': <int>[10, -20, 30, -40],
      'channels': initialChannels,
      'mapped': <String, int>{
        'S1': 1006,
        'S2': 1007,
        'SA': 1014,
        'SB': 1015,
        'SC': 1016,
        'SD': 1017,
        'SF': 1019,
        '6POS': 1029,
        'SE': 1030,
        'T1': 0,
        'T2': 0,
        'T3': 0,
        'T4': 0,
      },
    });
    await tester.pumpAndSettle();

    final changedChannels = List<int>.from(initialChannels);
    changedChannels[42] = 1;
    events.add(<String, dynamic>{
      'type': 'frame',
      'sequence': 43,
      'timestamp': 12346,
      'gimbals': <int>[10, -20, 30, -40],
      'channels': changedChannels,
      'mapped': <String, int>{'T1': 1},
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('T1 / TRIM0'), findsWidgets);
    expect(find.text('历史操作 · 0'), findsOneWidget);

    await tester.tap(find.text('详细'));
    await tester.pumpAndSettle();

    expect(find.textContaining('/dev/ttyS0'), findsWidgets);
    expect(find.text('Yaw / 左横'), findsOneWidget);
    expect(find.text('T1'), findsWidgets);
  });

  testWidgets('右摇杆纵向操作优先于同帧横向小幅抖动显示', (tester) async {
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);

    await tester.pumpWidget(Ax12UmbusMonitorApp(eventStream: events.stream));
    final initialChannels = List<int>.filled(46, 0);
    events.add(<String, dynamic>{
      'type': 'frame',
      'sequence': 1,
      'timestamp': 1,
      'gimbals': initialChannels.take(4).toList(),
      'channels': initialChannels,
      'mapped': const <String, int>{},
    });
    await tester.pumpAndSettle();

    final changedChannels = List<int>.from(initialChannels)
      ..[1] = 400
      ..[3] = 3;
    events.add(<String, dynamic>{
      'type': 'frame',
      'sequence': 2,
      'timestamp': 2,
      'gimbals': changedChannels.take(4).toList(),
      'channels': changedChannels,
      'mapped': const <String, int>{},
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('控件  Pitch / 右纵 / SRC01'), findsOneWidget);
    expect(find.text('历史操作 · 1'), findsOneWidget);
  });

  test('T1 单次增加 1 会生成设备控制命令', () {
    final router = ControlRouter();
    final before = List<int>.filled(46, 0);
    final after = List<int>.from(before)..[42] = 1;
    final now = DateTime(2026, 10, 20);

    expect(router.process(before, now), isEmpty);
    final commands = router.process(
      after,
      now.add(const Duration(milliseconds: 1)),
    );

    expect(commands, hasLength(1));
    expect(commands.single.action, 'trim_t1');
    expect(commands.single.source, 'T1 / TRIM0');
    expect(commands.single.rawValue, 1);
  });

  test('慢速摇杆的逐帧小变化会累计并生成命令', () {
    final router = ControlRouter();
    final start = List<int>.filled(46, 0);
    final now = DateTime(2026, 10, 20);

    expect(router.process(start, now), isEmpty);
    expect(router.process(List<int>.from(start)..[0] = 1, now), isEmpty);
    expect(router.process(List<int>.from(start)..[0] = 2, now), isEmpty);
    final commands = router.process(
      List<int>.from(start)..[0] = 3,
      now.add(const Duration(milliseconds: 1)),
    );

    expect(commands, hasLength(1));
    expect(commands.single.action, 'yaw');
    expect(commands.single.rawValue, 3);
  });

  test('摇杆保持在非中心位置时每100毫秒续发，回中后不重复', () {
    final router = ControlRouter();
    final center = List<int>.filled(46, 0);
    final held = List<int>.from(center)..[2] = 512;
    final now = DateTime(2026, 10, 26);

    expect(router.process(center, now), isEmpty);
    expect(
      router
          .process(held, now.add(const Duration(milliseconds: 10)))
          .single
          .action,
      'throttle',
    );
    expect(
      router.process(held, now.add(const Duration(milliseconds: 80))),
      isEmpty,
    );
    expect(
      router
          .process(held, now.add(const Duration(milliseconds: 120)))
          .single
          .action,
      'throttle',
    );

    final released = router.process(
      center,
      now.add(const Duration(milliseconds: 180)),
    );
    expect(released.single.normalizedValue, 0);
    expect(
      router.process(center, now.add(const Duration(milliseconds: 400))),
      isEmpty,
    );
  });

  test('中心附近偏移不会触发摇杆续发', () {
    final router = ControlRouter();
    final centerOffset = List<int>.filled(46, 0)..[2] = 44;
    final now = DateTime(2026, 10, 26);

    expect(router.process(centerOffset, now), isEmpty);
    expect(
      router.process(centerOffset, now.add(const Duration(milliseconds: 500))),
      isEmpty,
    );
  });

  test('协议编码失败一次后发送队列仍可继续工作', () async {
    final events = StreamController<dynamic>.broadcast();
    final controller = DeviceBridgeController(
      ax12Events: events.stream,
      protocol: _ThrowOnceProtocol(),
    );
    addTearDown(() async {
      controller.dispose();
      await events.close();
    });

    await controller.connect(MockDeviceTransport());
    await controller.sendManual('first', 1);
    expect(controller.errorMessage, contains('模拟编码失败'));

    await controller.sendManual('second', 2);
    expect(controller.latestPacket?.command.action, 'second');
    expect(
      controller.logs.any((entry) => entry.message.contains('TX second')),
      isTrue,
    );
  });

  test('网关在线时会解析并刷新 Go2 离线和恢复状态', () async {
    final ax12Events = StreamController<dynamic>.broadcast();
    final transport = _GatewayStatusTransport();
    final controller = DeviceBridgeController(ax12Events: ax12Events.stream);
    addTearDown(() async {
      controller.dispose();
      await transport._events.close();
      await ax12Events.close();
    });

    await controller.connect(transport);
    expect(controller.isConnected, isTrue);
    expect(controller.robotConnected, isFalse);
    expect(controller.robotConnectionError, 'Go2 不可达');
    expect(controller.robotArmed, isFalse);

    transport.emit(
      '网关 status  {"type":"status","armed":true,'
      '"robot":{"connected":true,"connectionError":null,'
      '"serverApiVersion":"1.0.0.1"}}',
    );
    expect(controller.robotConnected, isTrue);
    expect(controller.robotConnectionError, isNull);
    expect(controller.robotServerApiVersion, '1.0.0.1');
    expect(controller.robotArmed, isTrue);
  });

  test('网关异常断开后保持错误状态且不自动重连', () async {
    final ax12Events = StreamController<dynamic>.broadcast();
    final transport = _ControllableGatewayTransport('测试网关');
    final controller = DeviceBridgeController(ax12Events: ax12Events.stream);
    addTearDown(() async {
      controller.dispose();
      await transport.close();
      await ax12Events.close();
    });

    await controller.connect(transport);
    transport.emit('网关连接已断开 code=1006');

    expect(controller.linkState, DeviceLinkState.error);
    expect(controller.errorMessage, contains('手动重新连接'));
    expect(transport.connectCount, 1);
    expect(
      controller.logs.any((entry) => entry.message.contains('自动重连')),
      isFalse,
    );
  });

  test('切换地址后旧连接的迟到结果不能覆盖新连接', () async {
    final ax12Events = StreamController<dynamic>.broadcast();
    final oldGate = Completer<void>();
    final oldTransport = _ControllableGatewayTransport(
      '旧地址',
      connectGate: oldGate,
    );
    final newTransport = _ControllableGatewayTransport('新地址');
    final controller = DeviceBridgeController(ax12Events: ax12Events.stream);
    addTearDown(() async {
      controller.dispose();
      await oldTransport.close();
      await newTransport.close();
      await ax12Events.close();
    });

    final oldConnect = controller.connect(oldTransport);
    await Future<void>.delayed(Duration.zero);
    await controller.connect(newTransport);
    oldGate.complete();
    await oldConnect;

    expect(controller.linkState, DeviceLinkState.connected);
    expect(controller.connectedTransportName, '新地址');
    expect(oldTransport.disconnectCount, greaterThanOrEqualTo(1));
    expect(newTransport.connectCount, 1);
  });
}
