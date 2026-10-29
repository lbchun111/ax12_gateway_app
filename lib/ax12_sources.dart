/// AX12 A6/0x63 报告的输入源定义，页面与设备控制共用此表。
abstract final class Ax12Sources {
  /// 原厂 RcSrcEnable 使用 0x8000 标记未启用的输入，不能作为控制值发送。
  static const invalid = -32768;

  /// 按 42 路 SRC 布局定义索引；不能继续使用旧 33 路布局的索引。
  /// POT 和 S 是原厂不同的输入组，保留名称以避免混淆旋钮与滑杆。
  static const controls = <int, String>{
    4: 'POT1',
    5: 'POT2',
    12: 'S1',
    13: 'S2',
    20: 'SA',
    21: 'SB',
    22: 'SC',
    23: 'SD',
    24: 'SE',
    25: 'SF',
    35: '6POS',
    36: 'CNT1',
    42: 'T1',
    43: 'T2',
    44: 'T3',
    45: 'T4',
  };

  /// 格式化输入状态；无数据与未启用状态分别显示，保留所有有效负数。
  static String display(int? value) => value == null
      ? '--'
      : value == invalid
      ? '未启用'
      : '$value';
}
