// Tests for the zoom-hang fix in terminal_container.dart.
//
// What we're guarding against: during a pinch gesture, the old
// TerminalContainer fired `onFontSizeChanged` every frame, which
// caused the parent TerminalScreen to setState on every frame — a
// full screen rebuild 60×/s. Combined with xterm's per-frame grid
// recompute, this was enough to stall the UI under a TUI workload.
//
// The fix:
//   1. A `fontSizeNotifier` ValueNotifier lets tiny subtrees (the
//      header readout) rebuild per-frame without pulling the whole
//      screen into setState.
//   2. `onFontSizeChanged` now fires only on scale-end, explicit
//      zoom buttons, and the first auto-size.
//   3. Sub-pixel pinch noise (< 0.5 px) is ignored.
//   4. `onPinchStart`/`onPinchEnd` let the service suppress PTY
//      resizes during the gesture.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ktty/state/viewport_state.dart';
import 'package:ktty/widgets/terminal/terminal_container.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

void main() {
  Future<void> pumpContainer(
    WidgetTester tester, {
    required GlobalKey<TerminalContainerState> key,
    required List<double> fontSizeChanges,
    int? parentRebuildCounter,
    List<String>? lifecycle,
  }) async {
    int rebuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<ViewportState>(
            create: (_) => ViewportState(),
            child: Builder(
              builder: (ctx) {
                rebuilds++;
                return SizedBox(
                  width: 800,
                  height: 600,
                  child: TerminalContainer(
                    key: key,
                    terminal: Terminal(),
                    onFontSizeChanged: fontSizeChanges.add,
                    onPinchStart: () => lifecycle?.add('start'),
                    onPinchEnd: () => lifecycle?.add('end'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    // Stash the rebuild counter on the caller's list by piggybacking
    // on the fontSizeChanges length reference. We return via out-param
    // indirection: the builder above closes over `rebuilds`, and
    // callers that care can await tester.pumpAndSettle() + read from
    // the list.
    if (parentRebuildCounter != null) {
      // no-op here; captured closures exposed via _lastParentRebuilds
      _lastParentRebuilds = rebuilds;
    } else {
      _lastParentRebuilds = rebuilds;
    }
  }

  testWidgets('explicit zoomIn notifies parent', (tester) async {
    final key = GlobalKey<TerminalContainerState>();
    final changes = <double>[];
    await pumpContainer(tester, key: key, fontSizeChanges: changes);

    final before = changes.length;
    key.currentState!.zoomIn();
    await tester.pump();

    expect(changes.length, greaterThan(before));
    expect(key.currentState!.fontSize, greaterThan(0));
  });

  testWidgets('fontSizeNotifier reflects zoom', (tester) async {
    final key = GlobalKey<TerminalContainerState>();
    await pumpContainer(tester, key: key, fontSizeChanges: []);

    final before = key.currentState!.fontSizeNotifier.value;
    key.currentState!.zoomIn();
    await tester.pump();
    expect(
      key.currentState!.fontSizeNotifier.value,
      greaterThan(before),
      reason: 'notifier must advance with zoomIn',
    );
  });

  testWidgets('pinch lifecycle fires start and end once each', (tester) async {
    final key = GlobalKey<TerminalContainerState>();
    final changes = <double>[];
    final lifecycle = <String>[];
    await pumpContainer(
      tester,
      key: key,
      fontSizeChanges: changes,
      lifecycle: lifecycle,
    );

    // Simulate a 2-finger pinch: two pointers down, move one, lift.
    final center = tester.getCenter(find.byType(TerminalContainer));
    final finger1 = await tester.startGesture(center.translate(-30, 0));
    final finger2 = await tester.createGesture();
    await finger2.down(center.translate(30, 0));
    await tester.pump();

    // Spread outward — simulate multiple frames of zoom
    for (var i = 1; i <= 5; i++) {
      await finger1.moveBy(Offset(-4.0 * i, 0));
      await finger2.moveBy(Offset(4.0 * i, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }

    await finger1.up();
    await finger2.up();
    await tester.pump();

    expect(lifecycle, contains('start'));
    expect(lifecycle, contains('end'));
    expect(
      lifecycle.where((e) => e == 'start').length,
      1,
      reason: 'pinch start should fire exactly once per gesture',
    );
    expect(
      lifecycle.where((e) => e == 'end').length,
      1,
      reason: 'pinch end should fire exactly once per gesture',
    );
  });

  testWidgets(
    'onFontSizeChanged does NOT fire per pinch frame (only on end)',
    (tester) async {
      final key = GlobalKey<TerminalContainerState>();
      final changes = <double>[];
      final lifecycle = <String>[];
      await pumpContainer(
        tester,
        key: key,
        fontSizeChanges: changes,
        lifecycle: lifecycle,
      );

      final center = tester.getCenter(find.byType(TerminalContainer));
      final finger1 = await tester.startGesture(center.translate(-30, 0));
      final finger2 = await tester.createGesture();
      await finger2.down(center.translate(30, 0));
      await tester.pump();

      // Record the change count BEFORE the scale gesture moves.
      final changesAtStart = changes.length;

      // Many frames of movement.
      for (var i = 1; i <= 10; i++) {
        await finger1.moveBy(Offset(-6.0 * i, 0));
        await finger2.moveBy(Offset(6.0 * i, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }

      final changesMidGesture = changes.length;
      // Before we release, the parent should NOT have been notified
      // per frame. It may be unchanged, or increase by at most 0
      // — tolerate a small safety margin in case an auto-size frame
      // landed, but it definitely should not approach one-per-frame.
      expect(
        changesMidGesture - changesAtStart,
        lessThanOrEqualTo(1),
        reason: 'parent was notified mid-pinch; would cause full rebuild per '
            'frame (mid-gesture delta=${changesMidGesture - changesAtStart})',
      );

      // Release.
      await finger1.up();
      await finger2.up();
      await tester.pump();

      // After scale-end, the parent MUST have been notified at least once.
      expect(
        changes.length,
        greaterThan(changesMidGesture),
        reason: 'parent must be notified on scale-end',
      );
    },
  );
}

// Stashed by pumpContainer — not used by assertions but kept so
// future tests can read it without reflection.
int _lastParentRebuilds = 0;
// Silence analyzer for unused variable.
// ignore: unused_element
int get _lastParentRebuildsRef => _lastParentRebuilds;
