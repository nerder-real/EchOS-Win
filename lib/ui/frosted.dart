// 现代视觉：柔和渐变背景 + 玻璃质感卡片（大圆角、柔和阴影、内描边）。
import 'package:flutter/material.dart';

import 'theme.dart';

/// 卡片：大圆角 + 柔和阴影 + 顶部 1px 高光描边（现代 macOS 玻璃卡片）
class CardBox extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? tint; // 可选：卡片左上角的彩色渐变光斑
  final Gradient? gradient;
  final bool expandChild; // true：child 撑满卡片（用于底部弹性区）
  const CardBox({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding = const EdgeInsets.all(16),
    this.tint,
    this.gradient,
    this.expandChild = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = EchTheme.isDark(t);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: gradient ??
            LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [const Color(0xFF252529), const Color(0xFF1E1E22)]
                  : [Colors.white, const Color(0xFFFCFCFD)],
            ),
        border: Border.all(color: EchTheme.cardBorder(t)),
        boxShadow: EchTheme.cardShadow(t),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (tint != null)
            Positioned(
              top: -40,
              right: -40,
              child: IgnorePointer(
                child: Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        tint!.withValues(alpha: dark ? 0.18 : 0.14),
                        tint!.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (expandChild)
            Positioned.fill(
              child: Padding(padding: padding, child: child),
            )
          else
            Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// 主背景：顶部一抹淡蓝 + 底部淡橙的柔和渐变（现代液态感，极低对比）
/// 背景始终铺满整个窗口（Positioned.fill），内容不足时也不露黑。
class LiquidBackground extends StatelessWidget {
  final Widget child;
  const LiquidBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = EchTheme.isDark(t);
    return Stack(
      fit: StackFit.expand,
      children: [
        // 铺满窗口的渐变背景
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? [
                      const Color(0xFF202024),
                      const Color(0xFF19191D),
                      const Color(0xFF1C1C21)
                    ]
                  : [
                      const Color(0xFFF5F6F8),
                      const Color(0xFFF0F1F4),
                      const Color(0xFFF4F5F8)
                    ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}