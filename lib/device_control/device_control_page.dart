import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'device_bridge_controller.dart';
import 'device_models.dart';
import 'device_transport.dart';

class DeviceControlPage extends StatefulWidget {
  /// 创建设备控制页面，并复用应用级 AX12 广播流 [ax12Events]。
  const DeviceControlPage({super.key, required this.ax12Events});

  final Stream<dynamic> ax12Events;

  /// 创建保存连接配置和 Controller 的页面状态对象。
  @override
  State<DeviceControlPage> createState() => _DeviceControlPageState();
}

class _DeviceControlPageState extends State<DeviceControlPage> {
  late final DeviceBridgeController _controller;
  final _hostController = TextEditingController(text: '192.168.0.124');
  final _portController = TextEditingController(text: '9000');
  final _gatewayPortController = TextEditingController(text: '8765');
  final _gatewayTokenController = TextEditingController();
  final _serviceUuidController = TextEditingController(
    text: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
  );
  final _writeUuidController = TextEditingController(
    text: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  );
  final _notifyUuidController = TextEditingController(
    text: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
  );

  // 产品界面只开放两种宇树链路；通用UDP、BLE、Mock仍保留在底层。
  DeviceLinkKind _linkKind = DeviceLinkKind.unitreeGateway;
  List<UnitreeDdsInterface> _ddsInterfaces = const [];
  UnitreeDdsInterface? _selectedDdsInterface;
  bool _loadingDdsInterfaces = false;
  List<BleDeviceSummary> _bleDevices = const [];
  BleDeviceSummary? _selectedBleDevice;
  bool _scanning = false;
  Timer? _manualMotionTimer;
  String? _manualMotionAction;

  /// 初始化业务 Controller，并把其状态变化绑定到页面刷新。
  @override
  void initState() {
    super.initState();
    _controller = DeviceBridgeController(ax12Events: widget.ax12Events)
      ..addListener(_refresh);
    _hostController.addListener(_onGatewaySettingChanged);
    _gatewayPortController.addListener(_onGatewaySettingChanged);
    _gatewayTokenController.addListener(_onGatewaySettingChanged);
  }

  /// 响应 Controller 通知；页面仍挂载时触发一次重建。
  void _refresh() {
    if (mounted) setState(() {});
  }

  /// 修改网关地址、端口或令牌时立即废弃旧连接。
  ///
  /// 新地址只会在用户再次点击“连接设备”后使用，避免输入过程中后台连接
  /// 又把页面拉回旧地址，也不会对尚未连接的普通编辑产生额外操作。
  void _onGatewaySettingChanged() {
    if (_controller.linkState == DeviceLinkState.disconnected) return;
    unawaited(_controller.disconnect());
  }

  /// 移除监听并释放 Controller 与所有输入框控制器。
  @override
  void dispose() {
    _manualMotionTimer?.cancel();
    _hostController.removeListener(_onGatewaySettingChanged);
    _gatewayPortController.removeListener(_onGatewaySettingChanged);
    _gatewayTokenController.removeListener(_onGatewaySettingChanged);
    _controller
      ..removeListener(_refresh)
      ..dispose();
    _hostController.dispose();
    _portController.dispose();
    _gatewayPortController.dispose();
    _gatewayTokenController.dispose();
    _serviceUuidController.dispose();
    _writeUuidController.dispose();
    _notifyUuidController.dispose();
    super.dispose();
  }

  /// 构建三页签设备控制页面，避免连接、操控和日志挤在同一长列表中。
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('宇树 Go2 控制', style: TextStyle(fontWeight: FontWeight.w800)),
              Text(
                'AX12 → 笔记本网关 → Go2',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
              ),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: _StatusChip(
                state: _controller.linkState,
                showRobot:
                    _linkKind == DeviceLinkKind.unitreeGateway ||
                    _linkKind == DeviceLinkKind.unitreeDds,
                robotConnected: _controller.robotConnected,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              const Material(
                color: Colors.transparent,
                child: TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.link), text: '连接'),
                    Tab(icon: Icon(Icons.sports_esports), text: '手动控制'),
                    Tab(
                      icon: Icon(Icons.monitor_heart_outlined),
                      text: '状态与日志',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildTabPage(
                      const ValueKey('connection-tab-page'),
                      _buildConnectionPanel(showControl: false),
                    ),
                    _buildTabPage(
                      const ValueKey('control-tab-page'),
                      _buildConnectionPanel(showConnection: false),
                    ),
                    _buildTabPage(
                      const ValueKey('monitor-tab-page'),
                      _buildMonitorPanel(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 为每个页签提供独立滚动区域，并限制宽屏内容宽度以便阅读和操作。
  Widget _buildTabPage(Key key, Widget child) {
    return SingleChildScrollView(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: child,
        ),
      ),
    );
  }

  /// 构建连接选择、连接参数、协议开关和手动测试命令区域。
  Widget _buildConnectionPanel({
    bool showConnection = true,
    bool showControl = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showConnection)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '1 选择宇树连接方式',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<DeviceLinkKind>(
                    segments: const [
                      ButtonSegment(
                        value: DeviceLinkKind.unitreeGateway,
                        icon: Icon(Icons.computer_outlined),
                        label: Text('笔记本网关'),
                      ),
                      // ButtonSegment(
                      //   value: DeviceLinkKind.unitreeDds,
                      //   icon: Icon(Icons.router_outlined),
                      //   label: Text('Android DDS直连'),
                      // ),
                    ],
                    selected: {_linkKind},
                    onSelectionChanged:
                        _controller.isConnected ||
                            _controller.linkState == DeviceLinkState.connecting
                        ? null
                        : (selection) {
                            final value = selection.first;
                            setState(() => _linkKind = value);
                            if (value == DeviceLinkKind.unitreeDds) {
                              _loadDdsInterfaces();
                            }
                          },
                  ),
                  const SizedBox(height: 14),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: switch (_linkKind) {
                      DeviceLinkKind.mock => const _InfoText(
                        key: ValueKey('mock'),
                        text: '不需要真实设备。所有发送数据会立即返回 ACK，适合演示完整链路。',
                      ),
                      DeviceLinkKind.unitreeGateway => _buildGatewayFields(),
                      DeviceLinkKind.unitreeDds => _buildDdsFields(),
                      DeviceLinkKind.wifiUdp => _buildUdpFields(),
                      DeviceLinkKind.bleGatt => _buildBleFields(),
                    },
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed:
                        _controller.linkState == DeviceLinkState.connecting
                        ? null
                        : _controller.isConnected
                        ? _controller.disconnect
                        : _connect,
                    icon: Icon(
                      _controller.isConnected ? Icons.link_off : Icons.link,
                    ),
                    label: Text(
                      _controller.linkState == DeviceLinkState.connecting
                          ? '连接中…'
                          : _controller.isConnected
                          ? '断开设备'
                          : '连接设备',
                    ),
                  ),
                  if ((_linkKind == DeviceLinkKind.unitreeGateway ||
                          _linkKind == DeviceLinkKind.unitreeDds) &&
                      _controller.isConnected) ...[
                    const SizedBox(height: 12),
                    _buildRobotConnectionStatus(),
                  ],
                  if (_controller.errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _controller.errorMessage!,
                      style: const TextStyle(color: Color(0xFFFF8A80)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (showConnection && showControl) const SizedBox(height: 12),
        if (showControl)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '2 协议与发送',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.data_object),
                    title: Text(_controller.protocol.name),
                    subtitle: Text(_controller.protocol.description),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('AX12 操作自动发送'),
                    subtitle: const Text('关闭后仍可观察输入，但不会发送到设备'),
                    value: _controller.automaticSending,
                    onChanged: _controller.setAutomaticSending,
                  ),
                  const Divider(),
                  const Text('Go2 手动控制'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => _controller.sendManual('arm', 1024),
                        child: const Text('解锁并准备运动'),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            _controller.sendManual('stand_up', 1024),
                        child: const Text('站起'),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            _controller.sendManual('stand_down', -1024),
                        child: const Text('趴下'),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            _controller.sendManual('balance_stand', 1024),
                        child: const Text('平衡站立'),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            _controller.sendManual('recovery_stand', 1024),
                        child: const Text('恢复站立'),
                      ),
                      OutlinedButton(
                        onPressed: () => _controller.sendManual('damp', 1024),
                        child: const Text('阻尼模式'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFB3261E),
                        ),
                        onPressed: () =>
                            _controller.sendManual('emergency_stop', 0),
                        child: const Text('急停并锁定'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _controller.robotArmed == true
                        ? '移动控制已解锁：按住按钮移动，松开立即停止'
                        : '移动控制未解锁：请先连接 Go2 并点击“解锁并准备运动”',
                    style: TextStyle(
                      color: _controller.robotArmed == true
                          ? const Color(0xFF62D7A7)
                          : const Color(0xFFFFCA6B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _HoldToMoveButton(
                        label: '前进',
                        icon: Icons.arrow_upward,
                        enabled: _manualMotionEnabled,
                        active: _manualMotionAction == 'move_forward',
                        onStart: () => _startManualMotion('move_forward', 1024),
                        onStop: _stopManualMotion,
                      ),
                      _HoldToMoveButton(
                        label: '后退',
                        icon: Icons.arrow_downward,
                        enabled: _manualMotionEnabled,
                        active: _manualMotionAction == 'move_backward',
                        onStart: () =>
                            _startManualMotion('move_backward', -1024),
                        onStop: _stopManualMotion,
                      ),
                      _HoldToMoveButton(
                        label: '左转',
                        icon: Icons.rotate_left,
                        enabled: _manualMotionEnabled,
                        active: _manualMotionAction == 'turn_left',
                        onStart: () => _startManualMotion('turn_left', -512),
                        onStop: _stopManualMotion,
                      ),
                      _HoldToMoveButton(
                        label: '右转',
                        icon: Icons.rotate_right,
                        enabled: _manualMotionEnabled,
                        active: _manualMotionAction == 'turn_right',
                        onStart: () => _startManualMotion('turn_right', 512),
                        onStop: _stopManualMotion,
                      ),
                      FilledButton.tonal(
                        onPressed: _manualMotionEnabled
                            ? () => _stopManualMotion(forceSend: true)
                            : null,
                        child: const Text('停止移动'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const _InfoText(
                    text:
                        '安全映射：拨杆只监视、不控制机器人；请使用界面按钮解锁、停止和切换姿态。'
                        'T1/T2/T3/T4=站起/趴下/平衡/恢复。摇杆：左纵前后、右横横移、左横旋转。',
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 只有网关、机器人和外部控制租约均可用时才允许手动移动。
  bool get _manualMotionEnabled =>
      _controller.isConnected &&
      _controller.robotConnected == true &&
      _controller.robotArmed == true;

  /// 按下方向按钮后立即发送，并以 100ms 周期续发以保持 Go2 运动。
  void _startManualMotion(String action, int value) {
    if (!_manualMotionEnabled) {
      _showMessage('请先连接 Go2 并解锁移动控制');
      return;
    }
    _manualMotionTimer?.cancel();
    setState(() => _manualMotionAction = action);
    unawaited(_controller.sendManual(action, value));
    _manualMotionTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_manualMotionEnabled || _manualMotionAction != action) {
        _stopManualMotion();
        return;
      }
      unawaited(_controller.sendManual(action, value));
    });
  }

  /// 松开方向按钮时只清零速度，不取消解锁，便于继续切换方向。
  void _stopManualMotion({bool forceSend = false}) {
    final wasMoving = _manualMotionAction != null;
    _manualMotionTimer?.cancel();
    _manualMotionTimer = null;
    if (mounted) setState(() => _manualMotionAction = null);
    if ((wasMoving || forceSend) && _manualMotionEnabled) {
      unawaited(_controller.sendManual('motion_stop', 0));
    }
  }

  /// 显示当前宇树链路之后的Go2实际连接状态和可操作错误原因。
  Widget _buildRobotConnectionStatus() {
    final connected = _controller.robotConnected;
    final color = connected == true
        ? const Color(0xFF62D7A7)
        : connected == false
        ? const Color(0xFFFF8A80)
        : const Color(0xFFFFCA6B);
    final linkName = _linkKind == DeviceLinkKind.unitreeDds
        ? 'Android DDS'
        : '笔记本网关';
    final title = connected == true
        ? 'Go2 机器人已连接'
        : connected == false
        ? '$linkName 已连接，但 Go2 机器人未连接'
        : '$linkName 已连接，正在读取机器人状态';
    final detail = connected == true
        ? 'SDK ${_controller.robotServerApiVersion ?? '版本未知'} · '
              '${_controller.robotArmed == true ? '已解锁' : '已锁定'}'
        : connected == false
        ? (_controller.robotConnectionError ?? '机器人未返回在线状态，请检查电源、网线和 IP')
        : '请稍候，状态会每 5 秒自动刷新。';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.65)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            connected == true
                ? Icons.check_circle_outline
                : connected == false
                ? Icons.error_outline
                : Icons.sync,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(detail, style: TextStyle(color: color, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建 WSL2 Python 宇树网关的主机、端口和共享令牌输入区域。
  Widget _buildGatewayFields() {
    return Column(
      key: const ValueKey('unitreeGateway'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Windows 笔记本局域网 IP',
                  hintText: '例如 192.168.1.10',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _gatewayPortController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '端口',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _gatewayTokenController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '网关令牌（未配置可留空）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        const _InfoText(
          text:
              'App → Wi-Fi WebSocket → Windows/WSL2 网关 → CycloneDDS → 宇树机器人。连接后必须先解锁。',
        ),
      ],
    );
  }

  /// 构建Android CycloneDDS直连的网卡选择和阶段性安全说明。
  Widget _buildDdsFields() {
    return Column(
      key: const ValueKey('unitreeDds'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<UnitreeDdsInterface>(
                initialValue: _ddsInterfaces.contains(_selectedDdsInterface)
                    ? _selectedDdsInterface
                    : null,
                decoration: const InputDecoration(
                  labelText: '连接Go2的Android网卡',
                  border: OutlineInputBorder(),
                ),
                hint: const Text('请刷新并选择网卡'),
                items: [
                  for (final item in _ddsInterfaces)
                    DropdownMenuItem(value: item, child: Text(item.label)),
                ],
                onChanged: (value) =>
                    setState(() => _selectedDdsInterface = value),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.outlined(
              tooltip: '刷新Android网卡',
              onPressed: _loadingDdsInterfaces ? null : _loadDdsInterfaces,
              icon: _loadingDdsInterfaces
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const _InfoText(
          text:
              'AX12 Android → CycloneDDS → Go2 Sport。首次连接只执行公开API版本探测；'
              '成功后仍需点击“解锁”才能发送姿态或摇杆动作。请选择与Go2同网段且支持组播的网卡。',
        ),
      ],
    );
  }

  /// 枚举IPv4网卡并优先选择192.168.123网段、其次以太网、最后第一项。
  Future<void> _loadDdsInterfaces() async {
    if (_loadingDdsInterfaces) return;
    setState(() => _loadingDdsInterfaces = true);
    try {
      final interfaces = await UnitreeDdsDeviceTransport.listInterfaces();
      if (!mounted) return;
      UnitreeDdsInterface? selected;
      for (final item in interfaces) {
        if (item.addresses.any(
          (address) => address.startsWith('192.168.123.'),
        )) {
          selected = item;
          break;
        }
      }
      selected ??= interfaces.cast<UnitreeDdsInterface?>().firstWhere(
        (item) => item?.name.startsWith('eth') == true,
        orElse: () => null,
      );
      selected ??= interfaces.isEmpty ? null : interfaces.first;
      setState(() {
        _ddsInterfaces = interfaces;
        _selectedDdsInterface = selected;
      });
      if (interfaces.isEmpty) _showMessage('未发现可用IPv4网卡');
    } catch (error) {
      _showMessage('读取Android网卡失败：$error');
    } finally {
      if (mounted) setState(() => _loadingDdsInterfaces = false);
    }
  }

  /// 构建 Wi-Fi UDP 的目标主机和端口输入区域。
  Widget _buildUdpFields() {
    return Column(
      key: const ValueKey('udp'),
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: '设备 IP 或域名',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'UDP 端口',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const _InfoText(
          text: 'Demo 使用 UDP。以后可新增 TCP、WebSocket、HTTP 或 MQTT Transport。',
        ),
      ],
    );
  }

  /// 构建 BLE 扫描、设备选择以及 Service/Write/Notify UUID 输入区域。
  Widget _buildBleFields() {
    return Column(
      key: const ValueKey('ble'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _scanning ? null : _scanBle,
          icon: _scanning
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.bluetooth_searching),
          label: Text(_scanning ? '扫描中…' : '扫描 BLE 设备'),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<BleDeviceSummary>(
          initialValue: _selectedBleDevice,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '目标设备',
            border: OutlineInputBorder(),
          ),
          items: _bleDevices
              .map(
                (device) => DropdownMenuItem(
                  value: device,
                  child: Text(device.label, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: (value) => setState(() => _selectedBleDevice = value),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _serviceUuidController,
          decoration: const InputDecoration(
            labelText: 'Service UUID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _writeUuidController,
          decoration: const InputDecoration(
            labelText: 'Write Characteristic UUID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _notifyUuidController,
          decoration: const InputDecoration(
            labelText: 'Notify UUID 可选',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        const _InfoText(text: '默认填入常见 UART 示例 UUID，实际对接时替换为设备厂商提供的 UUID。'),
      ],
    );
  }

  /// 构建帧计数、最新动作、最近发送内容、映射和通信日志区域。
  Widget _buildMonitorPanel() {
    final latest = _controller.latestInput;
    final packet = _controller.latestPacket;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '实时链路',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text('AX12 帧 ${_controller.receivedFrames}'),
                  ],
                ),
                const SizedBox(height: 12),
                _MetricRow(
                  label: '最新输入',
                  value: latest == null
                      ? '等待操作遥控器…'
                      : '${latest.source}  ${latest.rawValue}',
                ),
                _MetricRow(label: '映射动作', value: latest?.action ?? '--'),
                _MetricRow(
                  label: '归一化值',
                  value: latest?.normalizedValue.toStringAsFixed(4) ?? '--',
                ),
                _MetricRow(
                  label: '设备连接',
                  value: _controller.connectedTransportName ?? '未连接',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: const Icon(Icons.outbox_outlined),
            title: const Text('最近发送的数据'),
            subtitle: Text(packet?.command.action ?? '尚未发送'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SelectableText(
                  packet == null
                      ? '连接宇树网关后操作遥控器，或点击左侧测试命令。'
                      : utf8.decode(packet.bytes, allowMalformed: true).trim(),
                  style: const TextStyle(fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: Text('动作映射 · ${_controller.router.bindings.length}'),
            subtitle: const Text('协议和 UI 都可以独立替换'),
            children: [
              for (final binding in _controller.router.bindings)
                ListTile(
                  dense: true,
                  title: Text(binding.sourceName),
                  trailing: Text(
                    binding.action,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text('通信日志 · ${_controller.logs.length}'),
            trailing: IconButton(
              tooltip: '清空日志',
              onPressed: _controller.logs.isEmpty
                  ? null
                  : _controller.clearLogs,
              icon: const Icon(Icons.delete_outline),
            ),
            children: [
              if (_controller.logs.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: Text('暂无日志'),
                )
              else
                for (final entry in _controller.logs.take(30))
                  ListTile(
                    dense: true,
                    leading: Icon(
                      entry.isError ? Icons.error_outline : Icons.chevron_right,
                      color: entry.isError ? const Color(0xFFFF8A80) : null,
                    ),
                    title: Text(entry.message),
                    trailing: Text(_formatTime(entry.time)),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  /// 按当前连接类型校验页面参数、创建对应 Transport 并请求连接。
  Future<void> _connect() async {
    switch (_linkKind) {
      case DeviceLinkKind.mock:
        await _controller.connect(MockDeviceTransport());
      case DeviceLinkKind.unitreeGateway:
        final port = int.tryParse(_gatewayPortController.text.trim());
        if (port == null || port < 1 || port > 65535) {
          _showMessage('请输入 1 到 65535 的有效 WebSocket 端口');
          return;
        }
        final host = _hostController.text.trim();
        if (host.isEmpty) {
          _showMessage('请输入 Windows 笔记本局域网 IP');
          return;
        }
        await _controller.connect(
          UnitreeGatewayTransport(
            host: host,
            port: port,
            token: _gatewayTokenController.text,
          ),
        );
      case DeviceLinkKind.unitreeDds:
        final interface = _selectedDdsInterface;
        if (interface == null) {
          _showMessage('请先刷新并选择连接Go2的Android网卡');
          return;
        }
        if (!interface.supportsMulticast) {
          _showMessage('所选网卡未报告组播能力，DDS发现可能失败');
        }
        await _controller.connect(
          UnitreeDdsDeviceTransport(interfaceName: interface.name),
        );
      case DeviceLinkKind.wifiUdp:
        final port = int.tryParse(_portController.text.trim());
        if (port == null || port < 1 || port > 65535) {
          _showMessage('请输入 1 到 65535 的有效 UDP 端口');
          return;
        }
        await _controller.connect(
          UdpDeviceTransport(host: _hostController.text.trim(), port: port),
        );
      case DeviceLinkKind.bleGatt:
        final device = _selectedBleDevice;
        if (device == null) {
          _showMessage('请先扫描并选择 BLE 设备');
          return;
        }
        await _controller.connect(
          BleGattDeviceTransport(
            deviceId: device.id,
            serviceUuid: _serviceUuidController.text,
            writeCharacteristicUuid: _writeUuidController.text,
            notifyCharacteristicUuid: _notifyUuidController.text,
          ),
        );
    }
  }

  /// 扫描 BLE 设备、更新列表，并默认选择 RSSI 最强的设备。
  Future<void> _scanBle() async {
    setState(() => _scanning = true);
    try {
      final devices = await BleDiscoveryService().scan();
      if (!mounted) return;
      setState(() {
        _bleDevices = devices;
        _selectedBleDevice = devices.isEmpty ? null : devices.first;
      });
      _showMessage(
        devices.isEmpty ? '没有发现 BLE 设备' : '发现 ${devices.length} 个设备',
      );
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 在页面仍挂载时显示一条 SnackBar 提示。
  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 将时间格式化为 24 小时制 `HH:mm:ss`。
  String _formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';
}

class _StatusChip extends StatelessWidget {
  /// 创建连接状态标签。
  const _StatusChip({
    required this.state,
    required this.showRobot,
    required this.robotConnected,
  });

  final DeviceLinkState state;
  final bool showRobot;
  final bool? robotConnected;

  /// 将链路状态映射为中文标签、颜色和圆点图标。
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      DeviceLinkState.disconnected => ('未连接', const Color(0xFF939DB2)),
      DeviceLinkState.connecting => ('连接中', const Color(0xFFFFCA6B)),
      DeviceLinkState.connected when showRobot && robotConnected == false => (
        '网关在线 · 机器人离线',
        const Color(0xFFFF8A80),
      ),
      DeviceLinkState.connected when showRobot && robotConnected == true => (
        '机器人已连接',
        const Color(0xFF62D7A7),
      ),
      DeviceLinkState.connected => ('网关已连接', const Color(0xFF62D7A7)),
      DeviceLinkState.error => ('连接错误', const Color(0xFFFF8A80)),
    };
    return Chip(
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(label),
    );
  }
}

class _InfoText extends StatelessWidget {
  /// 创建使用统一辅助文字样式的说明组件。
  const _InfoText({super.key, required this.text});

  final String text;

  /// 构建带固定颜色和行高的说明文本。
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(color: Color(0xFFA9B1C3), height: 1.35),
  );
}

class _HoldToMoveButton extends StatelessWidget {
  /// 创建按住持续移动、松开立即停止的方向按钮。
  const _HoldToMoveButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.active,
    required this.onStart,
    required this.onStop,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final bool active;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: enabled ? (_) => onStart() : null,
      onPointerUp: enabled ? (_) => onStop() : null,
      onPointerCancel: enabled ? (_) => onStop() : null,
      child: OutlinedButton.icon(
        style: active
            ? OutlinedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              )
            : null,
        onPressed: enabled ? () {} : null,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  /// 创建一行“固定宽度标签 + 等宽值”的指标组件。
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  /// 构建对齐的指标行，长值使用剩余宽度显示。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF939DB2)),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}
