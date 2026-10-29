import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ax12_sources.dart';
import 'device_control/device_control_page.dart';

/// Flutter 应用入口，启动 AX12 监听与外部设备控制根组件。
void main() => runApp(const Ax12UmbusMonitorApp());

class Ax12UmbusMonitorApp extends StatelessWidget {
  /// 创建根应用；测试可注入 [eventStream]，实机则使用原生 EventChannel。
  const Ax12UmbusMonitorApp({super.key, this.eventStream});

  final Stream<dynamic>? eventStream;

  /// 创建共享 AX12 广播流、全局主题和双页面导航壳。
  @override
  Widget build(BuildContext context) {
    final ax12Events =
        eventStream ??
        const EventChannel(
          'com.remotecontrol.remote/umbus',
        ).receiveBroadcastStream();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AX12 UMBUS 监听器',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6E83FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
        cardTheme: const CardThemeData(
          color: Color(0xFF171B25),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xFF2A3040)),
          ),
        ),
      ),
      home: RemoteBridgeShell(ax12Events: ax12Events),
    );
  }
}

class RemoteBridgeShell extends StatefulWidget {
  /// 创建“设备控制 / AX12 输入”导航壳，并向两页传递同一广播流。
  const RemoteBridgeShell({super.key, required this.ax12Events});

  final Stream<dynamic> ax12Events;

  /// 创建保存当前底部导航索引的 State。
  @override
  State<RemoteBridgeShell> createState() => _RemoteBridgeShellState();
}

class _RemoteBridgeShellState extends State<RemoteBridgeShell> {
  int _selectedIndex = 0;

  /// 用 IndexedStack 构建双页导航，切换时保留各页面状态。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          UmbusMonitorPage(eventStream: widget.ax12Events),
          DeviceControlPage(ax12Events: widget.ax12Events),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (value) =>
            setState(() => _selectedIndex = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.gamepad_outlined),
            selectedIcon: Icon(Icons.gamepad),
            label: 'AX12 输入',
          ),
          NavigationDestination(
            icon: Icon(Icons.router_outlined),
            selectedIcon: Icon(Icons.router),
            label: '设备控制',
          ),
        ],
      ),
    );
  }
}

class UmbusSnapshot {
  /// 创建一帧强类型 AX12 输入快照。
  const UmbusSnapshot({
    required this.sequence,
    required this.timestamp,
    required this.gimbals,
    required this.channels,
    required this.mapped,
  });

  /// 将 EventChannel 的动态 Map 容错转换为强类型快照。
  ///
  /// 缺失集合使用空集合，无法转换的数值使用 0。
  factory UmbusSnapshot.fromMap(Map<dynamic, dynamic> data) {
    /// 将平台通道中的动态数值安全转换为 int，转换失败时返回 0。
    int number(dynamic value) => (value as num?)?.toInt() ?? 0;
    final mappedData = data['mapped'] as Map<dynamic, dynamic>? ?? const {};
    return UmbusSnapshot(
      sequence: number(data['sequence']),
      timestamp: number(data['timestamp']),
      gimbals: (data['gimbals'] as List<dynamic>? ?? const [])
          .map(number)
          .toList(growable: false),
      channels: (data['channels'] as List<dynamic>? ?? const [])
          .map(number)
          .toList(growable: false),
      mapped: mappedData.map(
        (key, value) => MapEntry(key.toString(), number(value)),
      ),
    );
  }

  final int sequence;
  final int timestamp;
  final List<int> gimbals;
  final List<int> channels;
  final Map<String, int> mapped;
}

class ControlChange {
  /// 创建一条控件变化记录，保存名称、前后值和发生时间。
  const ControlChange(this.name, this.before, this.after, this.time);

  final String name;
  final int before;
  final int after;
  final DateTime time;

  /// 返回本次变化的绝对幅度，用于同一帧内判断主要操作。
  int get magnitude => (after - before).abs();
}

class UmbusMonitorPage extends StatefulWidget {
  /// 创建 AX12 输入监听页；可选 [eventStream] 便于共享或测试注入。
  const UmbusMonitorPage({super.key, this.eventStream});

  final Stream<dynamic>? eventStream;

  /// 创建维护串口状态、快照和历史变化的 State。
  @override
  State<UmbusMonitorPage> createState() => _UmbusMonitorPageState();
}

class _UmbusMonitorPageState extends State<UmbusMonitorPage> {
  static const _channel = EventChannel('com.remotecontrol.remote/umbus');
  static const _channelNames = Ax12Sources.controls;
  static const _gimbalNames = <int, String>{
    0: 'Yaw / 左横',
    1: 'Pitch / 右纵',
    2: 'Throttle / 左纵',
    3: 'Roll / 右横',
  };

  StreamSubscription<dynamic>? _subscription;
  UmbusSnapshot? _snapshot;
  String _status = '正在打开 /dev/ttyS0…';
  String? _error;
  final List<ControlChange> _changes = [];
  bool _showDetails = false;

  /// 选择注入流或原生 EventChannel，并注册事件与错误回调。
  @override
  void initState() {
    super.initState();
    final stream = widget.eventStream ?? _channel.receiveBroadcastStream();
    _subscription = stream.listen(_onEvent, onError: _onStreamError);
  }

  /// 处理 status、error 和 frame 三类原生事件。
  ///
  /// 帧事件会与上一帧逐通道比较，过滤不超过 2 的抖动，并最多保留
  /// 最近 60 条有效控件变化。
  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    if (type == 'status') {
      setState(() {
        _status = raw['message']?.toString() ?? '串口状态已更新';
        if (raw['state'] != 'crc_error') _error = null;
      });
      return;
    }
    if (type == 'error') {
      setState(() {
        _error = raw['message']?.toString() ?? '未知串口错误';
        _status = raw['code']?.toString() ?? 'ERROR';
      });
      return;
    }
    if (type != 'frame') return;

    final next = UmbusSnapshot.fromMap(raw);
    final previous = _snapshot;
    if (previous != null) {
      final frameChanges = <ControlChange>[];
      final eventTime = DateTime.now();
      final count = previous.channels.length < next.channels.length
          ? previous.channels.length
          : next.channels.length;
      for (var index = 0; index < count; index++) {
        final before = previous.channels[index];
        final after = next.channels[index];
        // 输入启停属于状态变化，不能记录为一次实体操作。
        if (before == Ax12Sources.invalid || after == Ax12Sources.invalid) {
          continue;
        }
        // Ignore one- or two-count ADC jitter. Switches and intentional knob
        // movement produce a much larger delta on the AX12.
        // Trim values at virtual indices 42..45 can move by only one count
        // per click; analog SRC values retain the larger jitter threshold.
        final threshold = index >= 42 ? 0 : 2;
        if ((after - before).abs() > threshold) {
          final channel = index < 42
              ? 'SRC${index.toString().padLeft(2, '0')}'
              : 'TRIM${index - 42}';
          final knownName = _gimbalNames[index] ?? _channelNames[index];
          frameChanges.add(
            ControlChange(
              knownName == null ? channel : '$knownName / $channel',
              before,
              after,
              eventTime,
            ),
          );
        }
      }
      // One physical movement can cause small cross-axis ADC changes in the
      // same MCU frame. Put the largest delta first so the simple page reports
      // the dominant operation instead of whichever SRC index was visited last.
      frameChanges.sort(
        (left, right) => right.magnitude.compareTo(left.magnitude),
      );
      _changes.insertAll(0, frameChanges);
      if (_changes.length > 60) _changes.removeRange(60, _changes.length);
    }

    setState(() {
      _snapshot = next;
      _error = null;
      _status = 'AX12 A6/0x63 · MCU 帧 ${next.sequence}';
    });
  }

  /// 将 EventChannel 自身抛出的 Stream 错误显示到页面。
  void _onStreamError(Object error) {
    setState(() => _error = error.toString());
  }

  /// 页面销毁时取消 AX12 事件订阅。
  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// 根据 [_showDetails] 在简约监听页和详细诊断页之间切换。
  @override
  Widget build(BuildContext context) {
    if (!_showDetails) return _buildSimplePage(context);
    return _buildDetailedPage(context);
  }

  /// 构建默认简约页，只突出最新操作和可折叠历史记录。
  Widget _buildSimplePage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'AX12 控件监听',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: '清空操作记录',
            onPressed: _changes.isEmpty ? null : () => setState(_changes.clear),
            icon: const Icon(Icons.delete_outline),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _showDetails = true),
            icon: const Icon(Icons.tune),
            label: const Text('详细'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF171B25),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF2A3040)),
              ),
              child: SelectableText(
                _latestOutput(),
                style: const TextStyle(
                  height: 1.45,
                  fontSize: 16,
                  fontFamily: 'monospace',
                  color: Color(0xFFE7EAF3),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildHistoryCard(),
          ],
        ),
      ),
    );
  }

  /// 生成简约页顶部文本，覆盖错误、等待、无操作和最新操作状态。
  String _latestOutput() {
    final snapshot = _snapshot;
    if (_error != null) return '连接失败\n$_error';
    if (snapshot == null) return '$_status\n\n等待 AX12 MCU 数据…';
    if (_changes.isEmpty) {
      return '状态  已连接  ·  MCU 帧 ${snapshot.sequence}'
          '\n\n等待操作…'
          '\n拨动开关、按下按钮、旋转旋钮或移动摇杆。';
    }

    final latest = _changes.first;
    return '状态  已连接  ·  MCU 帧 ${snapshot.sequence}'
        '\n\n最新操作'
        '\n控件  ${latest.name}'
        '\n数值  ${latest.before} → ${latest.after}'
        '\n时间  ${_formatTime(latest.time)}';
  }

  /// 构建可展开/收起的历史卡片；最新一条不在历史中重复显示。
  Widget _buildHistoryCard() {
    final history = _changes.length <= 1
        ? const <ControlChange>[]
        : _changes.sublist(1);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: const Icon(Icons.history, color: Color(0xFF95A4FF)),
        title: Text(
          '历史操作 · ${history.length}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: const Text('点击展开 / 收起'),
        children: [
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: Text('暂无历史操作', style: TextStyle(color: Color(0xFF939DB2))),
            )
          else
            for (final change in history)
              ListTile(
                dense: true,
                leading: const Icon(Icons.swap_horiz),
                title: Text(change.name),
                subtitle: Text(
                  '${change.before} → ${change.after}',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                trailing: Text(
                  _formatTime(change.time),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF939DB2),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  /// 将时间格式化为 24 小时制 `HH:mm:ss`。
  String _formatTime(DateTime time) {
    /// 将单个时间分量补齐为两位十进制文本。
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  /// 构建包含状态、四轴、映射、42 路 SRC、4 路 Trim 和变化记录的详细页。
  Widget _buildDetailedPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AX12 UMBUS 监听器',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              '/dev/ttyS0 · 921600 8N1',
              style: TextStyle(fontSize: 12, color: Color(0xFF9DA6BA)),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => setState(() => _showDetails = false),
            icon: const Icon(Icons.subject),
            label: const Text('简约'),
          ),
          IconButton(
            tooltip: '清空变化记录',
            onPressed: _changes.isEmpty ? null : () => setState(_changes.clear),
            icon: const Icon(Icons.delete_outline),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = <Widget>[
              _StatusCard(status: _status, error: _error),
              const SizedBox(height: 14),
              _GimbalCard(snapshot: _snapshot),
              const SizedBox(height: 14),
              _MappedControlsCard(snapshot: _snapshot),
              const SizedBox(height: 14),
              _ChannelGrid(snapshot: _snapshot),
              const SizedBox(height: 14),
              _ChangesCard(changes: _changes),
            ];
            return ListView(
              padding: EdgeInsets.symmetric(
                horizontal: constraints.maxWidth >= 900 ? 24 : 14,
                vertical: 8,
              ),
              children: content,
            );
          },
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  /// 创建串口状态卡片。
  const _StatusCard({required this.status, required this.error});

  final String status;
  final String? error;

  /// 按是否存在错误选择颜色与图标，并显示状态详情。
  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Card(
      color: failed ? const Color(0xFF3A1E27) : const Color(0xFF17362F),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              failed ? Icons.error_outline : Icons.radio_button_checked,
              color: failed ? const Color(0xFFFF8492) : const Color(0xFF67E0AE),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (failed) ...[
                    const SizedBox(height: 5),
                    Text(error!, style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GimbalCard extends StatelessWidget {
  /// 创建四轴数值卡片。
  const _GimbalCard({required this.snapshot});

  final UmbusSnapshot? snapshot;

  /// 展示 Yaw、Pitch、Throttle、Roll 原始值与归一化进度。
  @override
  Widget build(BuildContext context) {
    const names = ['Yaw / 左横', 'Pitch / 右纵', 'Throttle / 左纵', 'Roll / 右横'];
    final values = snapshot?.gimbals ?? const <int>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '四轴摇杆候选值',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: List.generate(names.length, (index) {
                final value = index < values.length ? values[index] : 0;
                final normalized = ((value + 500) / 1000).clamp(0.0, 1.0);
                return SizedBox(
                  width: 240,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              names[index],
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          Text(
                            Ax12Sources.display(value),
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: normalized),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _MappedControlsCard extends StatelessWidget {
  /// 创建已确认 AX12 控件映射卡片。
  const _MappedControlsCard({required this.snapshot});

  final UmbusSnapshot? snapshot;

  /// 展示 S1、S2、SA、SB、SC、SD、SF、6POS、SE 和 T1–T4 数值。
  @override
  Widget build(BuildContext context) {
    const controls = Ax12Sources.controls;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AX12 实机控件映射',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final control in controls.entries)
                  Container(
                    width: 112,
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: const Color(0xFF202638),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          control.value,
                          style: const TextStyle(color: Color(0xFFAAB4CC)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          Ax12Sources.display(
                            snapshot != null &&
                                    control.key < snapshot!.channels.length
                                ? snapshot!.channels[control.key]
                                : snapshot?.mapped[control.value],
                          ),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelGrid extends StatelessWidget {
  /// 创建全部 42 路 SRC 与 4 路 Trim 原始值网格。
  const _ChannelGrid({required this.snapshot});

  final UmbusSnapshot? snapshot;

  /// 以 SRC00–SRC41、T1–T4 网格展示所有输入，辅助发现未知控件映射。
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '实机输入源 SRC00–SRC41 + T1–T4',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text(
              '拨动任意开关或旋钮，下方会立即记录变化的通道',
              style: TextStyle(fontSize: 11, color: Color(0xFF939DB2)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(46, (index) {
                final value =
                    snapshot != null && index < snapshot!.channels.length
                    ? snapshot!.channels[index]
                    : null;
                return Container(
                  width: 96,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111620),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    '${index < 42 ? 'SRC${index.toString().padLeft(2, '0')}' : 'T${index - 41}'}  ${Ax12Sources.display(value)}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChangesCard extends StatelessWidget {
  /// 创建详细页控件变化记录卡片。
  const _ChangesCard({required this.changes});

  final List<ControlChange> changes;

  /// 展示最近变化的控件名、前后值和发生时间。
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '控件变化记录 · ${changes.length}/60',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            if (changes.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '等待摇杆外的开关、旋钮或微调变化…',
                    style: TextStyle(color: Color(0xFF939DB2)),
                  ),
                ),
              )
            else
              for (final change in changes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.swap_horiz,
                    color: Color(0xFF95A4FF),
                  ),
                  title: Text(change.name),
                  subtitle: Text(
                    '${change.before} → ${change.after}',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  trailing: Text(
                    '${change.time.hour.toString().padLeft(2, '0')}:${change.time.minute.toString().padLeft(2, '0')}:${change.time.second.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF939DB2),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
