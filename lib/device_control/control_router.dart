import 'dart:math' as math;

import 'device_models.dart';
import '../ax12_sources.dart';

class ControlRouter {
  static const double _joystickDeadband = 0.08;

  /// 创建控制路由器；未提供 [bindings] 时使用 AX12 默认通道映射。
  ControlRouter({List<ControlBinding>? bindings})
    : bindings = bindings ?? defaultBindings;

  static const defaultBindings = <ControlBinding>[
    ControlBinding(
      sourceIndex: 0,
      sourceName: 'Yaw / SRC00',
      action: 'yaw',
      repeatInterval: Duration(milliseconds: 100),
    ),
    ControlBinding(
      sourceIndex: 1,
      sourceName: 'Pitch / SRC01',
      action: 'pitch',
      repeatInterval: Duration(milliseconds: 100),
    ),
    ControlBinding(
      sourceIndex: 2,
      sourceName: 'Throttle / SRC02',
      action: 'throttle',
      repeatInterval: Duration(milliseconds: 100),
    ),
    ControlBinding(
      sourceIndex: 3,
      sourceName: 'Roll / SRC03',
      action: 'roll',
      repeatInterval: Duration(milliseconds: 100),
    ),
    ControlBinding(sourceIndex: 4, sourceName: 'POT1 / SRC04', action: 'pot_1'),
    ControlBinding(sourceIndex: 5, sourceName: 'POT2 / SRC05', action: 'pot_2'),
    ControlBinding(
      sourceIndex: 12,
      sourceName: 'S1 / SRC12',
      action: 'knob_s1',
    ),
    ControlBinding(
      sourceIndex: 13,
      sourceName: 'S2 / SRC13',
      action: 'knob_s2',
    ),
    ControlBinding(
      sourceIndex: 42,
      sourceName: 'T1 / TRIM0',
      action: 'trim_t1',
      changeThreshold: 0,
      minimumInterval: Duration.zero,
    ),
    ControlBinding(
      sourceIndex: 43,
      sourceName: 'T2 / TRIM1',
      action: 'trim_t2',
      changeThreshold: 0,
      minimumInterval: Duration.zero,
    ),
    ControlBinding(
      sourceIndex: 44,
      sourceName: 'T3 / TRIM2',
      action: 'trim_t3',
      changeThreshold: 0,
      minimumInterval: Duration.zero,
    ),
    ControlBinding(
      sourceIndex: 45,
      sourceName: 'T4 / TRIM3',
      action: 'trim_t4',
      changeThreshold: 0,
      minimumInterval: Duration.zero,
    ),
  ];

  final List<ControlBinding> bindings;
  List<int>? _previous;
  final Map<int, DateTime> _lastSent = {};
  final Map<int, int> _lastEmittedValues = {};

  /// 比较当前和上一帧通道值，返回通过去抖与限流后的业务命令。
  ///
  /// 第一帧仅建立比较基准，不产生命令；[now] 同时用于限流和时间戳。
  List<DeviceCommand> process(List<int> channels, DateTime now) {
    final previous = _previous;
    _previous = List<int>.unmodifiable(channels);
    if (previous == null) {
      for (final binding in bindings) {
        if (binding.sourceIndex < channels.length) {
          _lastEmittedValues[binding.sourceIndex] =
              channels[binding.sourceIndex];
        }
      }
      return const [];
    }

    final commands = <DeviceCommand>[];
    for (final binding in bindings) {
      if (binding.sourceIndex >= previous.length ||
          binding.sourceIndex >= channels.length) {
        continue;
      }
      final before =
          _lastEmittedValues[binding.sourceIndex] ??
          previous[binding.sourceIndex];
      final after = channels[binding.sourceIndex];
      // 无效槽位不得发送；重新启用时仅建立基准，避免哨兵值造成大幅操作。
      if (after == Ax12Sources.invalid || before == Ax12Sources.invalid) {
        _lastEmittedValues[binding.sourceIndex] = after;
        _lastSent.remove(binding.sourceIndex);
        continue;
      }
      final lastSent = _lastSent[binding.sourceIndex];
      final changed = (after - before).abs() > binding.changeThreshold;
      final repeatInterval = binding.repeatInterval;
      final outsideCenterDeadband =
          _normalize(after).abs() >= _joystickDeadband;
      final repeatDue =
          !changed &&
          repeatInterval != null &&
          outsideCenterDeadband &&
          (lastSent == null || now.difference(lastSent) >= repeatInterval);
      if (!changed && !repeatDue) continue;

      if (changed &&
          lastSent != null &&
          now.difference(lastSent) < binding.minimumInterval) {
        continue;
      }
      _lastSent[binding.sourceIndex] = now;
      _lastEmittedValues[binding.sourceIndex] = after;
      commands.add(
        DeviceCommand(
          action: binding.action,
          source: binding.sourceName,
          rawValue: after,
          normalizedValue: _normalize(after),
          timestamp: now,
        ),
      );
    }
    return commands;
  }

  /// 将 UI 手动测试动作转换为标准命令，使其复用正常发送链路。
  DeviceCommand manual(String action, int value) {
    final now = DateTime.now();
    return DeviceCommand(
      action: action,
      source: 'UI / manual',
      rawValue: value,
      normalizedValue: _normalize(value),
      timestamp: now,
    );
  }

  /// 将演示用 AX12 数值按 1024 缩放并截断到 [-1, 1]。
  double _normalize(int value) => math.max(-1, math.min(1, value / 1024));
}
