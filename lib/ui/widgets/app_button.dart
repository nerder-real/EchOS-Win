// 现代按钮：渐变胶囊、柔和阴影、hover 微交互。
import 'package:flutter/material.dart';

import '../theme.dart';

/// 按钮：不传 gradient = 描边浅底（对齐 CSS .btn）；传 gradient = 渐变胶囊（主操作）
class AppButton extends StatelessWidget {
  final String label;
  final Gradient? gradient; // 指定渐变；null 用描边浅底
  final VoidCallback? onPressed;
  final bool enabled;
  final Widget? leading;
  final double? minWidth;
  final double fontSize;
  final double height;
  final FontWeight fontWeight;
  const AppButton(this.label,
      {super.key,
      this.gradient,
      this.onPressed,
      this.enabled = true,
      this.leading,
      this.minWidth,
      this.fontSize = EchTheme.fsTool,
      this.height = 30,
      this.fontWeight = EchTheme.fwContent});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isPill = gradient != null;
    final g = gradient ?? EchTheme.blueGradient();
    final fg = isPill
        ? Colors.white
        : EchTheme.text(t);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: height,
              width: minWidth,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: isPill ? g : null,
                color: isPill ? null : EchTheme.inputBg(t),
                borderRadius: BorderRadius.circular(8),
                border: isPill
                    ? null
                    : Border.all(color: EchTheme.cardBorder(t)),
                boxShadow: enabled && isPill
                    ? [
                        BoxShadow(
                          color: _gradStart(g).withValues(alpha: 0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 6)],
                  Text(label,
                      style: TextStyle(
                          fontSize: fontSize,
                          fontWeight: fontWeight,
                          color: fg,
                          letterSpacing: EchTheme.letterSpacing,
                          height: 1.3)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Color _gradStart(Gradient g) =>
      (g is LinearGradient && g.colors.isNotEmpty) ? g.colors.first : const Color(0xFF0A84FF);
}

/// 次要文字按钮（描边/透明）
class AppTextButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool enabled;
  final IconData? icon;
  final Color? color;
  final double fontSize;
  const AppTextButton(this.label,
      {super.key, this.onPressed, this.enabled = true, this.icon, this.color, this.fontSize = EchTheme.fsTool});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fg = color ?? EchTheme.text(t); // 不传色=普通文字色（日志文件/添加规则不再是默认蓝）
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 30,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: EchTheme.cardBorder(t)),
              color: EchTheme.inputBg(t),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 5),
              ],
              Text(label,
                  style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: EchTheme.fwContent,
                      color: fg,
                      letterSpacing: EchTheme.letterSpacing)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 下拉菜单按钮（分享/备份）—— 现代图标文字
class AppMenuButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final List<PopupMenuEntry<String>> items;
  final ValueChanged<String>? onSelected;
  final double fontSize;
  const AppMenuButton(
    this.label, {
    super.key,
    required this.icon,
    this.iconColor = const Color(0xFF0A84FF),
    required this.items,
    this.onSelected,
    this.fontSize = EchTheme.fsTool,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return _NoHover(
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerTheme: DividerThemeData(
            color: EchTheme.cardBorder(t),
            thickness: 1,
            space: 0,
          ),
        ),
        child: PopupMenuButton<String>(
          tooltip: '',
          onSelected: onSelected,
          itemBuilder: (_) => items,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          color: EchTheme.card(t),
          elevation: 8,
          child: Container(
            height: 30,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: EchTheme.inputBg(t),
              border: Border.all(color: EchTheme.cardBorder(t)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: iconColor),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: EchTheme.fwContent,
                      color: EchTheme.text(t),
                      letterSpacing: EchTheme.letterSpacing)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 消除 PopupMenuButton 等项的悬停/点击高亮背景
class _NoHover extends StatelessWidget {
  final Widget child;
  const _NoHover({required this.child});
  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: child,
    );
  }
}