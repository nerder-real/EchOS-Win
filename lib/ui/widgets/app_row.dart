// 统一的"标签 + 内容"行，所有分组共用，保证三张卡片里标签列宽一致。
import 'package:flutter/material.dart';

import '../theme.dart';

class AppRow extends StatelessWidget {
  static const double labelWidth = 108;
  final String label;
  final Widget child;
  final double width;
  const AppRow({
    super.key,
    required this.label,
    required this.child,
    this.width = labelWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: width,
          child: Text(label, style: EchTheme.labelStyle(EchTheme.textSoft(Theme.of(context)))),
        ),
        Expanded(child: child),
      ],
    );
  }
}