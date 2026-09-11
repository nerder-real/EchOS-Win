import 'dart:math' as math;

import 'menu.dart';

// Max value for a 16-bit unsigned integer. Chosen because it is the lowest
// common denominator for menu item ids between Linux, Windows, and macOS.
const int _maxMenuItemId = 65535;
// Some parts of the win32 API pass data that is ambiguous about whether it is
// the id of a menu item or its index in the menu. This sets a reasonable floor
// to distinguish between the two by assuming that no menu will have more than
// 1024 items in it.
const int _minMenuItemId = 1024;
int _nextMenuItemId = _minMenuItemId;

int _generateMenuItemId() {
  final newId = _nextMenuItemId;
  _nextMenuItemId = math.max(
    _minMenuItemId,
    (_nextMenuItemId + 1) % _maxMenuItemId,
  );
  return newId;
}

class MenuItem {
  int id = -1;
  String? key;
  String type;
  String? label;
  String? sublabel;
  String? accent;
  String? toolTip;
  String? icon;
  bool? checked;
  bool disabled;
  Menu? submenu;

  void Function(MenuItem menuItem)? onClick;
  void Function(MenuItem menuItem)? onHighlight;
  void Function(MenuItem menuItem)? onLoseHighlight;

  MenuItem.separator()
      : id = _generateMenuItemId(),
        type = 'separator',
        disabled = true;

  MenuItem.submenu({
    this.key,
    this.label,
    this.sublabel,
    this.toolTip,
    this.icon,
    this.accent,
    this.disabled = false,
    this.submenu,
    this.onClick,
    this.onHighlight,
    this.onLoseHighlight,
  })  : id = _generateMenuItemId(),
        type = 'submenu';

  MenuItem.checkbox({
    this.key,
    this.label,
    this.sublabel,
    this.toolTip,
    this.icon,
    this.accent,
    required this.checked,
    this.disabled = false,
    this.onClick,
    this.onHighlight,
    this.onLoseHighlight,
  })  : id = _generateMenuItemId(),
        type = 'checkbox';

  MenuItem({
    this.key,
    this.type = 'normal',
    this.label,
    this.sublabel,
    this.toolTip,
    this.icon,
    this.accent,
    this.checked,
    this.disabled = false,
    this.submenu,
    this.onClick,
    this.onHighlight,
    this.onLoseHighlight,
  }) : id = _generateMenuItemId();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'key': key,
      'type': type,
      'label': label ?? '',
      'toolTip': toolTip,
      'icon': icon,
      'checked': checked,
      'disabled': disabled,
      'accent': accent,
      'submenu': submenu?.toJson(),
    }..removeWhere((key, value) => value == null);
  }
}
