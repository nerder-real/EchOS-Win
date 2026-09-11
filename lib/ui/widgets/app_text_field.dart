// 文本输入框：柔和填充圆角，自带 controller 防丢字。
import 'package:flutter/material.dart';

import '../theme.dart';

class AppTextField extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String>? onChanged;
  final String? hint;
  final double fontSize;
  final bool monospace;
  final bool obscure;
  final TextAlign textAlign;
  final TextInputType keyboardType;
  final FontWeight fontWeight;
  final bool obscureWhenUnfocused; // 保存后星号，聚焦编辑时显示明文
  final bool enabled; // 运行中锁定配置：置灰且不可编辑
  const AppTextField(
    this.initialValue, {
    super.key,
    this.onChanged,
    this.hint,
    this.fontSize = EchTheme.fsInput,
    this.monospace = true,
    this.obscure = false,
    this.textAlign = TextAlign.start,
    this.keyboardType = TextInputType.text,
    this.fontWeight = EchTheme.fwContent,
    this.obscureWhenUnfocused = false,
    this.enabled = true,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(AppTextField old) {
    super.didUpdateWidget(old);
    // 外部值变化（切换服务器 / 从预设列表选择）而输入框不在聚焦时，同步回显。
    if (old.initialValue != widget.initialValue && !_focused) {
      _controller.value = TextEditingValue(
        text: widget.initialValue,
        selection: TextSelection.collapsed(offset: widget.initialValue.length),
      );
    }
  }

  void _onFocus() {
    if (_focused != _focus.hasFocus) {
      setState(() => _focused = _focus.hasFocus);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = const Color(0xFF0A84FF);
    return TextField(
      controller: _controller,
      focusNode: _focus,
      obscureText: widget.obscure ||
          (widget.obscureWhenUnfocused &&
              !_focused &&
              _controller.text.isNotEmpty),
      obscuringCharacter: '*', // 服务器地址/Token 失焦隐私用星号（默认 ●）
      keyboardType: widget.keyboardType,
      textAlign: widget.textAlign,
      // 锁定配置时用 readOnly 而非 enabled:false。
      // enabled:false 有两个副作用：1) 连带禁用文本选择，运行中无法复制
      // 服务器地址/Token；2) Flutter 会回退到默认的直角 disabledBorder，
      // 圆角丢失。readOnly 保留选中/复制能力，边框仍走 enabledBorder。
      enabled: true,
      readOnly: !widget.enabled,
      style: TextStyle(
          fontSize: widget.fontSize,
          fontFamily: widget.monospace ? EchTheme.monoFont : null,
          fontWeight: widget.fontWeight,
          letterSpacing: EchTheme.letterSpacing,
          color: widget.enabled
              ? EchTheme.inputText(t)
              : EchTheme.textMuted(t)),
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: TextStyle(
            color: EchTheme.textMuted(t),
            fontSize: widget.fontSize,
            fontWeight: EchTheme.fwInput,
            letterSpacing: EchTheme.letterSpacing),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        filled: true,
        fillColor: EchTheme.inputBg(t),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: accent, width: 1.3),
        ),
      ),
    );
  }
}
