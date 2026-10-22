import 'package:flutter/widgets.dart';

/// Inherited marker inserted by the bottom-navigation shell around its tab
/// contents. Pages that use [DeferredPageInitMixin] check for this in
/// `initState` to skip the "let the route transition finish first" delay —
/// there is no transition when the shell just flips `IndexedStack.index`.
class PrimaryShellMarker extends InheritedWidget {
  const PrimaryShellMarker({super.key, required super.child});

  static bool isInside(BuildContext context) {
    return context.getInheritedWidgetOfExactType<PrimaryShellMarker>() != null;
  }

  @override
  bool updateShouldNotify(PrimaryShellMarker oldWidget) => false;
}
