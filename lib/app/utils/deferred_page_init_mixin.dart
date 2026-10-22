import 'dart:async';

import 'package:flutter/widgets.dart';

import 'primary_shell_scope.dart';

mixin DeferredPageInitMixin<T extends StatefulWidget> on State<T> {
  Timer? _deferredInitTimer;

  /// Delay used when the page was pushed on top of another route — gives the
  /// route transition a frame or two of headroom before we hit the DB.
  Duration get deferredInitDelay => const Duration(milliseconds: 120);

  Future<void> runDeferredInit();

  @protected
  void scheduleDeferredInit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Inside the bottom-nav shell we're just flipping IndexedStack.index —
      // no push transition to protect, so kick off immediately.
      final skipDelay = PrimaryShellMarker.isInside(context);
      if (skipDelay) {
        unawaited(runDeferredInit());
        return;
      }
      _deferredInitTimer = Timer(deferredInitDelay, () {
        if (!mounted) return;
        unawaited(runDeferredInit());
      });
    });
  }

  @override
  void dispose() {
    _deferredInitTimer?.cancel();
    super.dispose();
  }
}
