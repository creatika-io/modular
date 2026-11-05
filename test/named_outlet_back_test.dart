import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

final module = createModule(
  register: (c) {
    c
      ..route('/', child: (ctx, s) => const Text('home'))
      ..route('/detail', child: (ctx, s) => const Text('detail'))
      ..route(
        '/side-host',
        child: (ctx, s) => const Row(
          children: [
            Text('side host'),
            Expanded(child: RouterOutlet(name: 'side')),
          ],
        ),
      );
    c.outlet('sheet')
      ..route('/cards/:id', child: (ctx, s) => Text('card ${s['id']}'))
      ..route(
        '/draft',
        child: (ctx, s) =>
            const PopScope<Object?>(canPop: false, child: Text('draft')),
      )
      ..route(
        '/tabs',
        child: (ctx, s) => const RouterOutlet(),
        children: (sub) => sub
          ..route('/', child: (ctx, s) => const Text('tab a'))
          ..route('/b', child: (ctx, s) => const Text('tab b'))
          ..route(
            '/draft',
            child: (ctx, s) => const PopScope<Object?>(
              canPop: false,
              child: Text('tab draft'),
            ),
          ),
      )
      // Its page holds back until the test lets it go.
      ..route(
        '/slow',
        // The only page-level way to keep a pop request pending.
        // ignore: deprecated_member_use
        child: (ctx, s) => WillPopScope(
          onWillPop: () => slowPageMayPop.future,
          child: const Text('slow'),
        ),
      );
    c.outlet('panel').route('/help', child: (ctx, s) => const Text('help'));
    c.outlet('side').route('/note', child: (ctx, s) => const Text('note'));
    // No RouterOutlet ever shows `ghost`.
    c.outlet('ghost').route('/ghost', child: (ctx, s) => const Text('ghost'));
  },
);

/// Completes when the `/slow` page lets a pending back go on.
Completer<bool> slowPageMayPop = Completer<bool>();

bool? reportedCanHandlePop;

Future<void> _pump(WidgetTester tester) async {
  reportedCanHandlePop = null;
  final boot = bootstrapModule(module);
  await tester.pumpWidget(
    MaterialApp.router(
      onNavigationNotification: (notification) {
        reportedCanHandlePop = notification.canHandlePop;
        return true;
      },
      routerConfig: modularRouterConfig(
        boot.routes,
        injector: boot.injector,
        manager: boot.manager,
        shellBuilder: (context, child) => Row(
          children: [
            Expanded(child: child),
            const Expanded(child: RouterOutlet(name: 'sheet')),
            const Expanded(child: RouterOutlet(name: 'panel')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String? _reportedUrl(WidgetTester tester) {
  final router =
      tester.widget(find.byWidgetPredicate((w) => w is Router)) as Router;
  return router.routeInformationProvider?.value.uri.toString();
}

Future<bool> _systemBack(WidgetTester tester) async {
  final handled = await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  return handled;
}

void main() {
  testWidgets(
    'back pops dialogs and pages above, then the outlet, then exits',
    (tester) async {
      await _pump(tester);
      tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/1'});
      await tester.pumpAndSettle();
      unawaited(tester.element(find.text('card 1')).pushNamed('/cards/2'));
      await tester.pumpAndSettle();
      unawaited(tester.element(find.text('home')).pushNamed('/detail'));
      await tester.pumpAndSettle();
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('detail')),
          builder: (context) => const Text('dialog'),
        ),
      );
      await tester.pumpAndSettle();

      expect(await _systemBack(tester), isTrue);
      expect(find.text('dialog'), findsNothing);
      expect(find.text('detail'), findsOneWidget);

      expect(await _systemBack(tester), isTrue);
      expect(find.text('detail'), findsNothing);
      expect(find.text('card 2'), findsOneWidget);

      expect(await _systemBack(tester), isTrue);
      expect(find.text('card 2'), findsNothing);
      expect(find.text('card 1'), findsOneWidget);
      expect(_reportedUrl(tester), '/(sheet:cards/1)');

      expect(await _systemBack(tester), isTrue);
      expect(find.text('card 1'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(_reportedUrl(tester), '/');

      expect(await _systemBack(tester), isFalse); // the platform takes over
    },
  );

  testWidgets('an open outlet tells the platform that Flutter handles back', (
    tester,
  ) async {
    await _pump(tester);
    expect(reportedCanHandlePop, isNot(isTrue));

    tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    expect(reportedCanHandlePop, isTrue);

    await _systemBack(tester);
    expect(find.text('card 1'), findsNothing);
    expect(reportedCanHandlePop, isFalse);
  });

  testWidgets("back respects a PopScope on the outlet's top page", (
    tester,
  ) async {
    await _pump(tester);
    tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    unawaited(tester.element(find.text('card 1')).pushNamed('/draft'));
    await tester.pumpAndSettle();

    expect(await _systemBack(tester), isTrue); // handled, but vetoed
    expect(find.text('draft'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:draft)');
  });

  testWidgets('with two outlets open, one back press reaches only the one '
      'changed most recently', (tester) async {
    await _pump(tester);
    tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    tester.element(find.text('home')).navigateOutlets({'panel': '/help'});
    await tester.pumpAndSettle();

    expect(await _systemBack(tester), isTrue);
    expect(find.text('help'), findsNothing);
    expect(find.text('card 1'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/1)');

    // Activity inside an outlet changes back priority.
    tester.element(find.text('home')).navigateOutlets({'panel': '/help'});
    await tester.pumpAndSettle();
    unawaited(tester.element(find.text('card 1')).pushNamed('/cards/2'));
    await tester.pumpAndSettle();

    expect(await _systemBack(tester), isTrue);
    expect(find.text('card 1'), findsOneWidget);
    expect(find.text('help'), findsOneWidget);

    expect(await _systemBack(tester), isTrue);
    expect(find.text('card 1'), findsNothing);
    expect(find.text('help'), findsOneWidget);

    expect(await _systemBack(tester), isTrue);
    expect(find.text('help'), findsNothing);
    expect(_reportedUrl(tester), '/');
  });

  testWidgets('back goes to an outlet on the page being popped', (
    tester,
  ) async {
    await _pump(tester);
    unawaited(tester.element(find.text('home')).pushNamed('/side-host'));
    await tester.pumpAndSettle();
    tester.element(find.text('side host')).navigateOutlets({'side': '/note'});
    await tester.pumpAndSettle();
    // The sheet changes last, but it sits on the page below.
    tester.element(find.text('side host')).navigateOutlets({
      'sheet': '/cards/1',
    });
    await tester.pumpAndSettle();

    expect(await _systemBack(tester), isTrue);
    expect(find.text('note'), findsNothing);
    expect(find.text('side host'), findsOneWidget);

    expect(await _systemBack(tester), isTrue);
    expect(find.text('side host'), findsNothing);
    expect(find.text('card 1'), findsOneWidget);

    // An outlet nobody shows never takes back.
    tester.element(find.text('home')).navigateOutlets({'ghost': '/ghost'});
    await tester.pumpAndSettle();
    expect(await _systemBack(tester), isTrue);
    expect(find.text('card 1'), findsNothing);
  });

  testWidgets('back enters a nested outlet in the sheet before closing it', (
    tester,
  ) async {
    await _pump(tester);
    tester.element(find.text('home')).navigateOutlets({'sheet': '/tabs'});
    await tester.pumpAndSettle();
    tester.element(find.text('home')).navigateOutlets({'panel': '/help'});
    await tester.pumpAndSettle();
    unawaited(tester.element(find.text('tab a')).pushNamed('/tabs/b'));
    await tester.pumpAndSettle();

    expect(await _systemBack(tester), isTrue);
    expect(find.text('tab b'), findsNothing);
    expect(find.text('tab a'), findsOneWidget);
    expect(find.text('help'), findsOneWidget);

    unawaited(tester.element(find.text('tab a')).pushNamed('/tabs/draft'));
    await tester.pumpAndSettle();
    expect(await _systemBack(tester), isTrue);
    expect(find.text('tab draft'), findsOneWidget);
  });

  testWidgets('back respects a single nested page veto and a nested dialog', (
    tester,
  ) async {
    await _pump(tester);
    tester.element(find.text('home')).navigateOutlets({'sheet': '/tabs/draft'});
    await tester.pumpAndSettle();

    expect(await _systemBack(tester), isTrue);
    expect(find.text('tab draft'), findsOneWidget); // vetoed, sheet open

    tester.element(find.text('home')).navigateOutlets({'sheet': '/tabs'});
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(
        context: tester.element(find.text('tab a')),
        useRootNavigator: false,
        builder: (context) => const Text('nested dialog'),
      ),
    );
    await tester.pumpAndSettle();
    expect(await _systemBack(tester), isTrue);
    expect(find.text('nested dialog'), findsNothing);
    expect(find.text('tab a'), findsOneWidget);
  });

  testWidgets('a back still pending never pops the page that replaced it', (
    tester,
  ) async {
    slowPageMayPop = Completer<bool>();
    await _pump(tester);
    tester.element(find.text('home')).navigateOutlets({'sheet': '/slow'});
    await tester.pumpAndSettle();

    unawaited(tester.binding.handlePopRoute());
    await tester.pump(); // back now waits on the slow page
    tester.element(find.text('slow')).navigate('/cards/9');
    slowPageMayPop.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('card 9'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/9)');
  });

  testWidgets('a back still pending never cancels an outside navigation', (
    tester,
  ) async {
    slowPageMayPop = Completer<bool>();
    await _pump(tester);
    tester.element(find.text('home')).navigateOutlets({'sheet': '/slow'});
    await tester.pumpAndSettle();

    unawaited(tester.binding.handlePopRoute());
    await tester.pump(); // back now waits on the slow page
    tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/9'});
    slowPageMayPop.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('card 9'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/9)');
  });

  testWidgets('a back pending above another card never cancels an outside '
      'navigation', (tester) async {
    slowPageMayPop = Completer<bool>();
    await _pump(tester);
    tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    unawaited(tester.element(find.text('card 1')).pushNamed('/slow'));
    await tester.pumpAndSettle();

    unawaited(tester.binding.handlePopRoute());
    await tester.pump(); // back now waits on the slow page
    tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/9'});
    slowPageMayPop.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('card 9'), findsOneWidget);
    expect(find.text('card 1', skipOffstage: false), findsNothing);
    expect(_reportedUrl(tester), '/(sheet:cards/9)');
  });
}
