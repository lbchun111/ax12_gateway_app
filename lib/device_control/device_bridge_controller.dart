import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'control_router.dart';
import 'device_models.dart';
import 'device_protocol.dart';
import 'device_transport.dart';

class DeviceBridgeController extends ChangeNotifier {
  static const _joystickActions = {'yaw', 'pitch', 'throttle', 'roll'};

  /// 创建连接 AX12 输入、动作路由、设备协议和通信链路的总控制器。
  ///
  /// 构造后会立即订阅 [ax12Events]，页面销毁时必须调用 [dispose]。
  DeviceBridgeController({
    required Stream<dynamic> ax12Events,
    DeviceProtocol? protocol,
    ControlRouter? router,
  }) : protocol = protocol ?? JsonLineDeviceProtocol(),
       router = router ?? ControlRouter() {
    _ax12Subscription = ax12Events.listen(_onAx12Event, onError: _onAx12Error);
  }

  final DeviceProtocol protocol;
  final ControlRouter router;
  final List<BridgeLogEntry> logs = [];

  late final StreamSubscription<dynamic> _ax12Subscription;
  DeviceTransport? _transport;
  StreamSubscription<String>? _transportSubscription;
  int _connectionGeneration = 0;
  Future<void> _sendQueue = Future<void>.value();

  DeviceLinkState linkState = DeviceLinkState.disconnected;
  bool automaticSending = true;
  int receivedFrames = 0;
  DeviceCommand? latestInput;
  OutboundPacket? latestPacket;
  String? errorMessage;
  String? connectedTransportName;
  bool? robotConnected;
  bool? robotArmed;
  String? robotConnectionError;
  String? robotServerApiVersion;

  /// 返回当前链路是否已连接并可执行发送。
  bool get isConnected => linkState == DeviceLinkState.connected;

  /// 使旧连接立即失效，再连接新的 [transport] 并监听其事件。
  ///
  /// 每次调用都会生成新的连接代次。旧地址的连接、事件或异常即使稍后
  /// 才返回，也不能覆盖当前状态。连接异常只显示错误，不自动重连；必须
  /// 由用户再次点击“连接设备”。
  Future<void> connect(DeviceTransport transport) async {
    final generation = ++_connectionGeneration;
    final previousTransport = _transport;
    final previousSubscription = _transportSubscription;
    _transport = null;
    _transportSubscription = null;
    connectedTransportName = null;
    linkState = DeviceLinkState.connecting;
    errorMessage = null;
    _clearRobotStatus();
    _addLog('正在连接 ${transport.name}');
    notifyListeners();

    await _releaseTransport(previousTransport, previousSubscription);
    if (generation != _connectionGeneration) {
      await _disconnectQuietly(transport);
      return;
    }

    _transport = transport;
    try {
      _transportSubscription = transport.events.listen((message) {
        if (generation != _connectionGeneration ||
            !identical(_transport, transport)) {
          return;
        }
        _handleTransportMessage(message);
        if ((message.startsWith('网关连接已断开') || message.startsWith('DDS连接已断开')) &&
            identical(_transport, transport)) {
          final isDds = transport is UnitreeDdsDeviceTransport;
          connectedTransportName = null;
          linkState = DeviceLinkState.error;
          errorMessage = isDds
              ? 'Android DDS 与 Go2 的连接已断开，请手动重新连接'
              : '笔记本网关连接已断开，请检查地址和网络后手动重新连接';
          _clearRobotStatus();
          notifyListeners();
        }
      });
      await transport.connect();
      if (generation != _connectionGeneration ||
          !identical(_transport, transport)) {
        await _disconnectQuietly(transport);
        return;
      }
      connectedTransportName = transport.name;
      linkState = DeviceLinkState.connected;
      _addLog('已连接 ${transport.name}');
    } catch (error) {
      if (generation != _connectionGeneration ||
          !identical(_transport, transport)) {
        await _disconnectQuietly(transport);
        return;
      }
      linkState = DeviceLinkState.error;
      errorMessage = error.toString();
      _addLog('连接失败 $error', isError: true);
      final failedSubscription = _transportSubscription;
      _transportSubscription = null;
      _transport = null;
      connectedTransportName = null;
      _clearRobotStatus();
      await _releaseTransport(transport, failedSubscription);
    }
    notifyListeners();
  }

  /// 立即使当前连接及所有未完成回调失效，并恢复未连接状态。
  ///
  /// 状态会先更新为“未连接”，再在后台等待底层资源释放，因此远端关闭
  /// 响应缓慢时，按钮和地址输入也不会被旧连接卡住。
  Future<void> disconnect() async {
    ++_connectionGeneration;
    final transport = _transport;
    final subscription = _transportSubscription;
    final wasActive = linkState != DeviceLinkState.disconnected;
    _transport = null;
    _transportSubscription = null;
    connectedTransportName = null;
    errorMessage = null;
    _clearRobotStatus();
    linkState = DeviceLinkState.disconnected;
    if (wasActive) _addLog('连接已关闭');
    notifyListeners();
    await _releaseTransport(transport, subscription);
  }

  /// 取消事件订阅并有界等待 Transport 关闭，避免断开按钮长期无响应。
  Future<void> _releaseTransport(
    DeviceTransport? transport,
    StreamSubscription<String>? subscription,
  ) async {
    try {
      await subscription?.cancel().timeout(const Duration(seconds: 1));
    } catch (_) {
      // 连接代次已使回调失效，取消超时不应阻塞用户后续操作。
    }
    if (transport != null) await _disconnectQuietly(transport);
  }

  /// 有界关闭单个 Transport；关闭失败不会触发重连或覆盖页面状态。
  Future<void> _disconnectQuietly(DeviceTransport transport) async {
    try {
      await transport.disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 底层 socket 可能已失效；控制器已丢弃该连接，无需再次重试。
    }
  }

  /// 开启或暂停 AX12 动作自动发送；暂停时仍继续解析和显示输入。
  void setAutomaticSending(bool value) {
    automaticSending = value;
    _addLog(value ? '已开启 AX12 自动发送' : '已暂停 AX12 自动发送');
    notifyListeners();
  }

  /// 创建一条 UI 手动命令并加入与 AX12 输入相同的串行发送队列。
  Future<void> sendManual(String action, int value) async {
    final command = router.manual(action, value);
    latestInput = command;
    notifyListeners();
    await _enqueue(command);
  }

  /// 清空页面通信日志并通知监听者刷新。
  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  /// 处理 Android EventChannel 的 AX12 帧或错误事件。
  ///
  /// 有效帧会交给 [ControlRouter.process]；只有自动发送开启且链路已连接
  /// 时，生成的命令才会进入发送队列。
  void _onAx12Event(dynamic raw) {
    if (raw is! Map) return;
    if (raw['type'] == 'error') {
      _onAx12Error(raw['message'] ?? raw['code'] ?? 'AX12 串口错误');
      return;
    }
    if (raw['type'] != 'frame') return;
    final rawChannels = raw['channels'];
    if (rawChannels is! List) return;
    final channels = rawChannels
        .map((value) => (value as num?)?.toInt() ?? 0)
        .toList(growable: false);
    receivedFrames += 1;
    final commands = router.process(channels, DateTime.now());
    if (commands.isNotEmpty) latestInput = commands.first;
    if (automaticSending && isConnected) {
      for (final command in commands) {
        // 宇树网关明确报告锁定时，不发送摇杆续发包，避免错误日志刷屏。
        // 解锁、姿态和其他开关命令仍会正常进入发送队列。
        if (robotArmed == false && _joystickActions.contains(command.action)) {
          continue;
        }
        _enqueue(command);
      }
    }
    notifyListeners();
  }

  /// 将 AX12 输入错误写入统一错误日志。
  void _onAx12Error(Object error) {
    _addLog('AX12 输入错误 $error', isError: true);
    notifyListeners();
  }

  /// 记录Transport文本事件，并从网关或DDS JSON中提取机器人实时状态。
  void _handleTransportMessage(String message) {
    _addLog(message);
    if (!message.startsWith('网关 ') && !message.startsWith('DDS ')) return;
    final jsonStart = message.indexOf('{');
    if (jsonStart < 0) return;
    try {
      final value = jsonDecode(message.substring(jsonStart));
      if (value is! Map) return;
      final robot = value['robot'];
      if (robot is! Map) return;
      robotConnected = robot['connected'] == true;
      robotConnectionError = robotConnected == true
          ? null
          : robot['connectionError']?.toString();
      robotServerApiVersion = robot['serverApiVersion']?.toString();
      robotArmed = value['armed'] is bool ? value['armed'] as bool : null;
      notifyListeners();
    } catch (_) {
      // 原始消息仍保留在日志中；无法解析的第三方响应不影响连接本身。
    }
  }

  /// 清空仅适用于宇树网关的机器人状态，避免切换链路后显示旧数据。
  void _clearRobotStatus() {
    robotConnected = null;
    robotArmed = null;
    robotConnectionError = null;
    robotServerApiVersion = null;
  }

  /// 把 [command] 链接到 Future 队列，保证异步写操作严格串行。
  Future<void> _enqueue(DeviceCommand command) async {
    _sendQueue = _sendQueue.then((_) => _send(command));
    await _sendQueue;
  }

  /// 编码并发送一条命令，同时更新最近数据包和 TX/错误日志。
  Future<void> _send(DeviceCommand command) async {
    final transport = _transport;
    if (!isConnected || transport == null) {
      _addLog('未连接设备，未发送 ${command.action}', isError: true);
      notifyListeners();
      return;
    }
    try {
      final bytes = protocol.encode(command);
      latestPacket = OutboundPacket(command: command, bytes: bytes);
      await transport.send(bytes);
      _addLog('TX ${command.action}  ${_preview(bytes)}');
    } catch (error) {
      errorMessage = error.toString();
      _addLog('发送失败 $error', isError: true);
    }
    notifyListeners();
  }

  /// 在日志头部插入新记录，并将列表限制为最近 80 条。
  void _addLog(String message, {bool isError = false}) {
    logs.insert(0, BridgeLogEntry(DateTime.now(), message, isError: isError));
    if (logs.length > 80) logs.removeRange(80, logs.length);
    notifyListeners();
  }

  /// 将发送字节生成最多 120 字符的 UTF-8 日志预览。
  ///
  /// 接入二进制协议后可将本方法替换为十六进制预览。
  String _preview(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  /// 释放 AX12、Transport 订阅和当前设备链路。
  @override
  void dispose() {
    ++_connectionGeneration;
    _ax12Subscription.cancel();
    _transportSubscription?.cancel();
    _transport?.disconnect();
    super.dispose();
  }
}
