# Research: Polish & Code Quality

## System Tray

**Decision**: Use `tray_manager` package for Windows system tray icon.
**Rationale**: Works on Windows, actively maintained. Supports icon, tooltip, and menu.

## Reorderable List

**Decision**: Use built-in `ReorderableListView` widget.
**Rationale**: Part of Flutter's Material library. No package needed.

## Right-Click Context Menu

**Decision**: Use `GestureDetector.onSecondaryTapDown` + `showMenu()`.
**Rationale**: Built-in Flutter pattern for desktop context menus.

## Keyboard Shortcuts

**Decision**: Use built-in `Shortcuts` + `Actions` widgets.
**Rationale**: Core Flutter widgets, work on all desktop platforms.

## Debounce

**Decision**: Use `Timer` from `dart:async` for 500ms debounce.
**Rationale**: No package needed — standard Dart timer pattern.

## Theme Extensions

**Decision**: Use `ThemeExtension<T>` to define semantic status colors.
**Rationale**: Official Flutter pattern for custom theme tokens. Type-safe, accessible via `Theme.of(context).extension<StatusColors>()`.
