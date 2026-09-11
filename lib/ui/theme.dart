// 现代主题：渐变、高层卡片、玻璃质感。亮/暗两套。
import 'package:flutter/material.dart';

class EchTheme {
  // 品牌色（含渐变端点）
  static const Color blue = Color(0xFF0A84FF);
  static const Color indigo = Color(0xFF5856D6);
  static const Color orange = Color(0xFFFF9F0A);
  static const Color green = Color(0xFF30D158);
  static const Color red = Color(0xFFFF3B30);
  static const Color yellow = Color(0xFFFFD60A);
  static const Color cloud = Color(0xFFF6821F);

  static bool isDark(ThemeData t) => t.brightness == Brightness.dark;

  // 系统级 UI 字体：内置 HarmonyOS Sans SC（华为开源免费商用、真字重 400/500/700、
  // 观感精致，比系统字体雅黑/等线更好）。
  static String get systemCJKFont => 'HarmonyOS Sans SC';

  // 数据类内容（输入框的值、日志、服务器列表副标题）也用同一套比例字体，
      // 不再混排 Consolas——Consolas 数字笔画比汉字粗是"字母比汉字粗"的根因。
      // 0/O、1/l 的区分靠字体本身已足够，追求的是中西文观感一致。
      // 等宽/数据字体：与全站比例字体统一，消除中西文混排导致的笔画粗细差。
  static String get monoFont => 'HarmonyOS Sans SC';

  // ---------------------------------------------------------------------------
  // 字号标准（对齐用户确定的 7 组规范，改字号只动这里，别在页面里硬编码）：
  //   ① 分组标题：服务器管理 / 核心配置 / 高级选项        → fsGroupTitle(14)
  //   ② 行标签/下拉：行标签(选择服务器…自检记录)与下拉(服务器名/日志级别/菜单项)
  //      → fsLabel(13.5)/w700，色用 inputText（颜色-1、比纯黑弱一档更耐看）
  //   ③ 分流段：绕过中国大陆 / 黑名单模式 / 全局模式      → fsSegment(14.5)/w700
  //   ④ 勾选项：开机启动 / 自动设置系统代理              → fsBody(13)，色用 textSoft（颜色+0.5）
  //   ⑤ 文本框内容（输入值）                             → fsInput(14)
  //   ⑥ 工具按钮（新增/重命名/保存/删除/分享/备份/自检/日志文件/清空/添加规则）→ fsTool(13.5)
  //      主按钮（启动代理/停止代理）→ fsAction(14)，按钮高 36
  //   ⑦ 次要/辅助文字 → fsSmall(12)/fsCaption(11)；日志行 → fsLog(12)/w500，色用 textSoft（颜色+0.5）
  //   ⑧ 全局字间距 letterSpacing(0.25)：「适当增加所有字体字间距」（HarmonyOS 原生偏宽）
  // 颜色一律走语义色（text/titleText/textMuted/textSoft/card/inputBg…），亮暗自适应。
  // ---------------------------------------------------------------------------

  // 语义
  static Color text(ThemeData t) =>
      isDark(t) ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E);
  static Color textMuted(ThemeData t) =>
      isDark(t) ? const Color(0xFF98989D) : const Color(0xFF8E8E93);
  // 软化文字（比正文轻一档，用于勾选项标签、输入值、状态文字）
  static Color textSoft(ThemeData t) =>
      isDark(t) ? const Color(0xFFC7C7CC) : const Color(0xFF3C3C40);
  // 标题文字：日间比正文更黑（对话框标题等浅底标题）
  static Color titleText(ThemeData t) =>
      isDark(t) ? const Color(0xFFF5F5F7) : const Color(0xFF000000);
  // 输入框文字：日间加深为近黑（参数值易读，不再发灰）
  static Color inputText(ThemeData t) =>
      isDark(t) ? const Color(0xFFC7C7CC) : const Color(0xFF303034);

  // 统一字号（对齐 EchOS-Win / DOH服务器 那组）
  static const double fsLabel = 13.5; // 行标签/下拉/菜单项（13.5）
  static const double fsBody = 13; // 泛用正文（对话框、勾选…）
  static const double fsInput = 14; // 文本框实际输入
  static const double fsSmall = 12; // 次要文字
  static const double fsCaption = 11; // 提示/辅助文字
  static const double fsGroupTitle = 14; // 卡片渐变标题（对齐 EchOS-Win 14/semibold）
  static const double fsSegment = 14.5; // 路由模式段（加大加粗）
  static const double fsTool = 13.5; // 工具按钮统一字号
  static const double fsLog = 12; // 日志/自检行
  static const double fsAction = 14; // 启动/停止代理主按钮

  // 全局字间距（用户要求"适当增加所有字体字间距"；HarmonyOS Sans 自身字距偏宽，0.25 恰当）
  static const double letterSpacing = 0.25;

  // 统一字重 —— 只取 Noto Sans SC 的真实字重，杜绝假加粗糊字：
  //   700 Bold    标题 + 行标签/分段（配置名醒目）
  //   500 Medium  内容：按钮/下拉/勾选/输入值
  //   400 Regular 弱化数据：日志行/状态文字/提示
  static const FontWeight fwTitle = FontWeight.w700;
  static const FontWeight fwContent = FontWeight.w500;
  static const FontWeight fwInput = FontWeight.w400; // 数据弱化层

  // 行标签：加黑（w700）；字间距随全局 letterSpacing（显式带上，避免被显式样式覆盖为 0）
  static TextStyle labelStyle(Color color) => TextStyle(
      fontSize: fsLabel,
      fontWeight: fwTitle,
      letterSpacing: letterSpacing,
      color: color);
  static TextStyle bodyStyle(Color color) => TextStyle(
      fontSize: fsBody,
      fontWeight: fwContent,
      letterSpacing: letterSpacing,
      color: color);
  static TextStyle smallStyle(Color color) => TextStyle(
      fontSize: fsSmall,
      fontWeight: fwContent,
      letterSpacing: letterSpacing,
      color: color);

  // 表面：玻璃多层
  static Color bg(ThemeData t) =>
      isDark(t) ? const Color(0xFF17171A) : const Color(0xFFF2F3F7);
  static Color bgTop(ThemeData t) =>
      isDark(t) ? const Color(0xFF1D1D22) : const Color(0xFFFAFBFD);
  static Color card(ThemeData t) =>
      isDark(t) ? const Color(0xFF232327) : const Color(0xFFFFFFFF);
  static Color cardBorder(ThemeData t) => isDark(t)
      ? Colors.white.withValues(alpha: 0.09)
      : Colors.black.withValues(alpha: 0.06);
  static Color inputBg(ThemeData t) => isDark(t)
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.black.withValues(alpha: 0.03);
  static Color hover(ThemeData t) =>
      isDark(t) ? Colors.white.withValues(alpha: 0.07) : Colors.black.withValues(alpha: 0.04);

  // 品牌渐变
  static LinearGradient blueGradient() => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF4DA6FF), Color(0xFF0A84FF)],
      );
  static LinearGradient indigoGradient() => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF7A77FF), Color(0xFF5856D6)],
      );
  static LinearGradient orangeGradient() => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFC759), Color(0xFFFF9F0A)],
      );
  static LinearGradient greenGradient() => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF5BEC8A), Color(0xFF30D158)],
      );
  static LinearGradient redGradient() => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFF6B62), Color(0xFFFF3B30)],
      );

  // 卡片阴影
  static List<BoxShadow> cardShadow(ThemeData t) => isDark(t)
      ? const [
          BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 22,
              offset: Offset(0, 8)),
          BoxShadow(color: Color(0x19000000), blurRadius: 4, offset: Offset(0, 1)),
        ]
      : const [
          BoxShadow(
              color: Color(0x12000000),
              blurRadius: 20,
              offset: Offset(0, 6)),
          BoxShadow(
              color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1)),
        ];

  static ThemeData light() => _build(brightness: Brightness.light);
  static ThemeData dark() => _build(brightness: Brightness.dark);

  static ThemeData _build({required Brightness brightness}) {
    final isDark = brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      // 全局字体：Noto Sans SC / 苹方，Avoid 字体回退造成中西文差异
      fontFamily: systemCJKFont,
      fontFamilyFallback:
          const ['HarmonyOS Sans SC', 'Microsoft YaHei', 'PingFang SC'],
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF17171A) : const Color(0xFFF2F3F7),
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: const Color(0xFF0A84FF),
        onPrimary: Colors.white,
        primaryContainer: isDark ? const Color(0xFF12314F) : const Color(0xFFD8EBFF),
        secondary: const Color(0xFF5856D6),
        onSecondary: Colors.white,
        error: isDark ? const Color(0xFFFF5A4F) : const Color(0xFFFF3B30),
        onError: Colors.white,
        surface: isDark ? const Color(0xFF1E1E22) : const Color(0xFFFFFFFF),
        onSurface: isDark ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E),
        surfaceContainerHighest:
            isDark ? const Color(0xFF2A2A2E) : const Color(0xFFE9EAEF),
        outline: isDark ? const Color(0xFF3A3A3E) : const Color(0xFFD2D4DA),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: const Color(0xFF0A84FF),
        selectionColor: const Color(0xFF0A84FF).withValues(alpha: 0.28),
      ),
      // 对话框动作按钮统一走⑥规范：fsBody(13)/fwContent，取消、确定、保存、删除等全部一致。
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontSize: fsBody, fontWeight: fwContent),
        ),
      ),
    );
    return base.copyWith(
      // 全局提升字间距：页面里 Text 的显式 style 是 inherit+merge，自动继承此默认值；
      // TextField 不合并 DefaultTextStyle，已在 AppTextField 显式补上 letterSpacing。
      textTheme:
          base.textTheme.apply(letterSpacingDelta: EchTheme.letterSpacing),
    );
  }
}
