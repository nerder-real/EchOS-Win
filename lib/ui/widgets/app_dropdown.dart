// 自建下拉：与 AppMenuButton（分享/备份）同一条 PopupMenuButton 渲染路径，
// 收起值 / 菜单项共用同一 TextStyle 常量 → 字体表现完全一致，杜绝 DropdownButton
// 内部 DefaultTextStyle 合并导致的大小/字重/字距漂移。
import 'package:flutter/material.dart';

import '../theme.dart';

class AppDropdown<T> extends StatelessWidget {
  final T value;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T>? onChanged;
  final double width;
  final double fontSize;
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.labelOf,
    this.onChanged,
    this.width = 96,
    this.fontSize = EchTheme.fsLabel,
  });

  // 收起值 + 菜单项共用的唯一样式（字号/字重/字距/行高全部走常量）
  TextStyle _label(ThemeData t) => TextStyle(
        fontSize: fontSize,
        fontWeight: EchTheme.fwContent,
        letterSpacing: EchTheme.letterSpacing,
        color: EchTheme.text(t),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: width,
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        color: EchTheme.inputBg(t),
        border: Border.all(color: EchTheme.cardBorder(t)),
      ),
      child: PopupMenuButton<T>(
        tooltip: '',
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final it in items)
            PopupMenuItem<T>(
              value: it,
              height: 32,
              child: Row(children: [
                if (it == value)
                  Icon(Icons.check_rounded,
                      size: 14, color: EchTheme.blue)
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(labelOf(it),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _label(t)),
                ),
              ]),
            ),
        ],
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10))),
        color: EchTheme.card(t),
        elevation: 8,
        child: Row(children: [
          Expanded(
            child: Center(
              child: Text(labelOf(value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _label(t)),
            ),
          ),
          Icon(Icons.arrow_drop_down,
              size: 15, color: EchTheme.textMuted(t)),
        ]),
      ),
    );
  }
}