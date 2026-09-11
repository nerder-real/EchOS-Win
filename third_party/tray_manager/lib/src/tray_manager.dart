import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:menu_base/menu_base.dart';
import 'package:path/path.dart' as path;
import 'package:shortid/shortid.dart';
import 'package:tray_manager/src/tray_listener.dart';

const kEventOnTrayIconMouseDown = 'onTrayIconMouseDown';
const kEventOnTrayIconMouseUp = 'onTrayIconMouseUp';
const kEventOnTrayIconRightMouseDown = 'onTrayIconRightMouseDown';
const kEventOnTrayIconRightMouseUp = 'onTrayIconRightMouseUp';
const kEventOnTrayMenuItemClick = 'onTrayMenuItemClick';

class TrayManager {
  TrayManager._() {
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  /// The shared instance of [TrayManager].
  static final TrayManager instance = TrayManager._();

  final MethodChannel _channel = const MethodChannel('tray_manager');

  final ObserverList<TrayListener> _listeners = ObserverList<TrayListener>();

  double get _devicePixelRatio {
    final flutterView = WidgetsBinding.instance.platformDispatcher.views.single;
    return MediaQueryData.fromView(flutterView).devicePixelRatio;
  }

  Menu? _menu;

  Future<void> _methodCallHandler(MethodCall call) async {
    for (final TrayListener listener in _listeners) {
      switch (call.method) {
        case kEventOnTrayIconMouseDown:
          listener.onTrayIconMouseDown();
          break;
        case kEventOnTrayIconMouseUp:
          listener.onTrayIconMouseUp();
          break;
        case kEventOnTrayIconRightMouseDown:
          listener.onTrayIconRightMouseDown();
          break;
        case kEventOnTrayIconRightMouseUp:
          listener.onTrayIconRightMouseUp();
          break;
        case kEventOnTrayMenuItemClick:
          int id = call.arguments['id'];
          MenuItem? menuItem = _menu?.getMenuItemById(id);
          if (menuItem != null) {
            bool? oldChecked = menuItem.checked;
            if (menuItem.onClick != null) {
              menuItem.onClick?.call(menuItem);
            }
            listener.onTrayMenuItemClick(menuItem);

            bool? newChecked = menuItem.checked;
            if (oldChecked != newChecked) {
              await setContextMenu(_menu!);
            }
          }
          break;
      }
    }
  }

  /// Whether any listeners are currently registered.
  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  /// Register a closure to be called when the tray events.
  void addListener(TrayListener listener) {
    _listeners.add(listener);
  }

  /// Remove a previously registered closure from the list of closures that are
  /// notified when the tray events.
  void removeListener(TrayListener listener) {
    _listeners.remove(listener);
  }

  // Destroys the tray icon immediately.
  Future<void> destroy() async {
    await _channel.invokeMethod('destroy');
  }

  /// Sets the image associated with this tray icon.
  ///
  /// [iconPath] is the path to the image file, relative to
  /// `data/flutter_assets` (i.e. the asset path declared in pubspec.yaml).
  Future<void> setIcon(String iconPath) async {
    final Map<String, dynamic> arguments = {
      'id': shortid.generate(),
      'iconPath': path.joinAll([
        path.dirname(Platform.resolvedExecutable),
        'data/flutter_assets',
        iconPath,
      ]),
    };

    await _channel.invokeMethod('setIcon', arguments);
  }

  /// Sets the hover text for this tray icon.
  ///
  /// Must be called after the icon is set.
  /// ```dart
  /// await trayManager.setIcon(...);
  /// await trayManager.setToolTip(...);
  /// ```
  Future<void> setToolTip(String toolTip) async {
    final Map<String, dynamic> arguments = {
      'toolTip': toolTip,
    };
    await _channel.invokeMethod('setToolTip', arguments);
  }

  /// Sets the context menu for this icon.
  Future<void> setContextMenu(Menu menu) async {
    _menu = menu;
    final Map<String, dynamic> arguments = {
      'menu': menu.toJson(),
    };
    await _channel.invokeMethod('setContextMenu', arguments);
  }

  /// Pops up the context menu of the tray icon.
  Future<void> popUpContextMenu() async {
    await _channel.invokeMethod('popUpContextMenu');
  }

  /// The bounds of this tray icon.
  Future<Rect?> getBounds() async {
    final Map<String, dynamic> arguments = {
      'devicePixelRatio': _devicePixelRatio,
    };
    final Map<dynamic, dynamic>? resultData = await _channel.invokeMethod(
      'getBounds',
      arguments,
    );
    if (resultData == null) {
      return null;
    }
    return Rect.fromLTWH(
      resultData['x'],
      resultData['y'],
      resultData['width'],
      resultData['height'],
    );
  }

  /// Windows only: shows or hides the app's icon on the taskbar.
  Future<void> setDockIconVisible(bool visible) async {
    final Map<String, dynamic> arguments = {
      'visible': visible,
    };
    await _channel.invokeMethod('setDockIconVisible', arguments);
  }
}

final trayManager = TrayManager.instance;
