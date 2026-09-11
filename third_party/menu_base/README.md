# menu_base

[![pub version][pub-image]][pub-url]

[pub-image]: https://img.shields.io/pub/v/menu_base.svg
[pub-url]: https://pub.dev/packages/menu_base

Used to create context or tray menus.

---

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [menu_base](#menu_base)
  - [Quick Start](#quick-start)
    - [Installation](#installation)
    - [Usage](#usage)
  - [Related Links](#related-links)
  - [License](#license)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Quick Start

### Installation

Add this to your package's pubspec.yaml file:

```yaml
dependencies:
  menu_base: ^0.1.0
```

Or

```yaml
dependencies:
  window_manager:
    git:
      url: https://github.com/leanflutter/menu_base.git
      ref: main
```

### Usage

```dart
import 'package:flutter/material.dart' hide MenuItem;
import 'package:menu_base/menu_base.dart';

Menu menu = Menu(
  items: [
    MenuItem(
      label: 'Copy',
      onClick: (_) {
        BotToast.showText(text: 'Clicked Copy');
      },
    ),
    MenuItem(
      label: 'Disabled item',
      disabled: true,
    ),
    MenuItem.separator(),
    MenuItem.submenu(
      label: 'Submenu',
      submenu: Menu(
        items: [
          MenuItem.checkbox(
            key: 'checkbox1',
            label: 'Checkbox1',
            checked: true,
            onClick: (menuItem) {
              menuItem.checked = !(menuItem.checked == true);
            },
          ),
          MenuItem.checkbox(
            label: 'Checkbox2',
            checked: false,
          ),
          MenuItem.checkbox(
            label: 'Checkbox3',
            checked: null,
          ),
        ],
      ),
    ),
  ],
);
```

## Related Links

- https://github.com/leanflutter/contextual_menu
- https://github.com/leanflutter/tray_manager

## License

[MIT](./LICENSE)
