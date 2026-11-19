import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

/// Page-scoped state, counting how often it is created and disposed.
class ActState extends ChangeNotifier {
  ActState() {
    created++;
  }

  static int created = 0;
  static int disposed = 0;

  @override
  void dispose() {
    disposed++;
    super.dispose();
  }
}

/// A bind of the acts feature module, counting how often it is created and
/// disposed.
class ActsService implements Disposable {
  ActsService() {
    created++;
  }

  static int created = 0;
  static int disposed = 0;

  @override
  void dispose() => disposed++;
}

class CountingPage extends StatefulWidget {
  const CountingPage(this.label, {super.key});

  final String label;

  static final Map<String, int> inits = {};

  @override
  State<CountingPage> createState() => _CountingPageState();
}

class _CountingPageState extends State<CountingPage> {
  @override
  void initState() {
    super.initState();
    CountingPage.inits.update(widget.label, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

final actsModule = createModule(
  path: '/acts',
  register: (c) {
    c
      ..addSingleton<ActsService>(ActsService.new)
      ..route(
        '/:id',
        provide: (s) => s.addChangeNotifier<ActState>(ActState.new),
        child: (ctx, s) {
          ctx.watch<ActState>();
          return CountingPage('act ${s['id']}');
        },
      );
  },
);

final module = createModule(
  register: (c) {
    c
      ..route('/', child: (ctx, s) => const CountingPage('home'))
      ..module(actsModule)
      ..route(
        '/tabs',
        child: (ctx, s) => const Column(
          children: [
            CountingPage('tabs shell'),
            Expanded(child: RouterOutlet()),
          ],
        ),
        children: (tab) => tab
          ..route('/', child: (ctx, s) => const CountingPage('tab 1'))
          ..route('/2', child: (ctx, s) => const CountingPage('tab 2'))
          ..route(
            '/inner',
            child: (ctx, s) => Router(routerDelegate: _InnerRouterDelegate()),
          ),
      )
      ..route(
        '/none/:id',
        transition: TransitionType.none,
        child: (ctx, s) => CountingPage('none ${s['id']}'),
      )
      ..route(
        '/overlay/:id',
        transition: CustomTransition(
          transitionsBuilder: (c, a, s, child) => child,
          opaque: false,
        ),
        child: (ctx, s) => CountingPage('overlay ${s['id']}'),
      )
      ..route(
        '/list/:id',
        child: (ctx, s) => Material(
          child: ListView.builder(
            key: const PageStorageKey('items'),
            itemExtent: 100,
            itemCount: 100,
            itemBuilder: (ctx, i) => Text('${s['id']} item $i'),
          ),
        ),
      );
    _addTransitionRoutes(c);
    c
        .outlet('sheet')
        .route(
          '/cards/:id',
          child: (ctx, s) => CountingPage('card ${s['id']}'),
        );
    _addTransitionRoutes(c.outlet('sheet'));
  },
);

/// A router of another package inside a Modular page.
class _InnerRouterDelegate extends RouterDelegate<Object> with ChangeNotifier {
  @override
  Widget build(BuildContext context) => const CountingPage('inner');

  @override
  Future<bool> popRoute() async => false;

  @override
  Future<void> setNewRoutePath(Object configuration) async {}
}

/// The route changes a Navigator reports.
class _RouteChanges extends NavigatorObserver {
  final List<String> changes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changes.add('push');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changes.add('pop');

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changes.add('remove');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      changes.add('replace');
}

/// A route for each non-Material transition, with page-scoped state.
void _addTransitionRoutes(ModularContext c) {
  for (final (kind, transition) in [
    ('faded', TransitionType.fade),
    ('custom', CustomTransition(transitionsBuilder: (c, a, s, child) => child)),
  ]) {
    c.route(
      '/$kind/:id',
      transition: transition,
      provide: (s) => s.addChangeNotifier<ActState>(ActState.new),
      child: (ctx, s) {
        ctx.watch<ActState>();
        return CountingPage('$kind ${s['id']}');
      },
    );
  }
}

/// The locations the app reports to the platform, each marked push or replace.
class HistoryReports {
  HistoryReports(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(SystemChannels.navigation, _record);
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.navigation, null),
    );
  }

  final List<String> reports = [];

  Future<Object?> _record(MethodCall call) async {
    if (call.method != 'routeInformationUpdated') return null;
    final arguments = call.arguments as Map<Object?, Object?>;
    final kind = arguments['replace'] == true ? 'replace' : 'push';
    reports.add('$kind ${arguments['uri']}');
    return null;
  }
}

Future<HistoryReports> _pump(
  WidgetTester tester,
  String initialRoute, {
  List<NavigatorObserver> observers = const [],
  PageStorageBucket? shellStorage,
}) async {
  CountingPage.inits.clear();
  ActState.created = 0;
  ActState.disposed = 0;
  ActsService.created = 0;
  ActsService.disposed = 0;
  final history = HistoryReports(tester);
  final boot = bootstrapModule(module);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: modularRouterConfig(
        boot.routes,
        injector: boot.injector,
        manager: boot.manager,
        initialRoute: initialRoute,
        observers: observers,
        shellBuilder: (context, child) => Row(
          children: [
            Expanded(
              child: shellStorage == null
                  ? child
                  : PageStorage(bucket: shellStorage, child: child),
            ),
            const Expanded(child: RouterOutlet(name: 'sheet')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  history.reports.clear();
  return history;
}

BuildContext _contextOf(WidgetTester tester, String text) =>
    tester.element(find.text(text, skipOffstage: false));

ModalRoute<dynamic> _routeOf(WidgetTester tester, String text) =>
    ModalRoute.of(_contextOf(tester, text))!;

void main() {
  testWidgets('replaceInPlace updates the page without a transition and '
      'replaces the history entry', (tester) async {
    final history = await _pump(tester, '/acts/a');
    final route = _routeOf(tester, 'act a');

    unawaited(
      _contextOf(
        tester,
        'act a',
      ).replaceInPlace('/acts/b', arguments: 'switch'),
    );
    await tester.pump();

    expect(find.text('act a', skipOffstage: false), findsNothing);
    expect(_routeOf(tester, 'act b'), same(route));
    expect(route.animation!.status, AnimationStatus.completed);
    final state = _contextOf(tester, 'act b').routeState();
    expect(state.uri.path, '/acts/b');
    expect(state.params, {'id': 'b'});
    expect(state.arguments, 'switch');
    expect(history.reports, ['replace /acts/b']);
  });

  testWidgets('the replaced content is built anew; the shell, its outlets '
      'and a shared feature module stay', (tester) async {
    await _pump(tester, '/acts/a');
    _contextOf(tester, 'act a').navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();

    unawaited(_contextOf(tester, 'act a').replaceInPlace('/acts/b'));
    await tester.pumpAndSettle();

    expect(CountingPage.inits, {'act a': 1, 'act b': 1, 'card 1': 1});
    expect((ActState.created, ActState.disposed), (2, 1));
    expect((ActsService.created, ActsService.disposed), (1, 0));
    expect(
      _contextOf(tester, 'act b').routeState().location.toString(),
      '/acts/b(sheet:cards/1)',
    );
  });

  testWidgets('navigate still pushes a new page with its transition and a '
      'new history entry', (tester) async {
    final history = await _pump(tester, '/acts/a');
    final route = _routeOf(tester, 'act a');

    _contextOf(tester, 'act a').navigate('/acts/b');
    await tester.pump();

    expect(_routeOf(tester, 'act b'), isNot(same(route)));
    expect(
      _routeOf(tester, 'act b').animation!.status,
      AnimationStatus.forward,
    );
    await tester.pumpAndSettle();
    expect(history.reports, ['push /acts/b']);
  });

  testWidgets('a pushed page replaced in place completes its future; back '
      'skips it', (tester) async {
    await _pump(tester, '/');
    final pushed = _contextOf(tester, 'home').pushNamed<String>('/acts/a');
    await tester.pumpAndSettle();

    final replacement = _contextOf(
      tester,
      'act a',
    ).replaceInPlace<String>('/acts/b');
    await tester.pumpAndSettle();
    expect(await pushed, isNull);

    _contextOf(tester, 'act b').pop('done');
    await tester.pumpAndSettle();
    expect(await replacement, 'done');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a route with another transition page replaces with that '
      'transition', (tester) async {
    await _pump(tester, '/acts/a');
    final route = _routeOf(tester, 'act a');

    unawaited(_contextOf(tester, 'act a').replaceInPlace('/faded/b'));
    await tester.pump();

    expect(_routeOf(tester, 'faded b'), isNot(same(route)));
    expect(
      _routeOf(tester, 'faded b').animation!.status,
      AnimationStatus.forward,
    );
    await tester.pumpAndSettle();
    expect(find.text('act a', skipOffstage: false), findsNothing);
    expect(find.text('faded b'), findsOneWidget);
  });

  testWidgets('replacing the base drops the location its nested outlet '
      'reported', (tester) async {
    final history = await _pump(tester, '/tabs');
    _contextOf(tester, 'tab 1').navigate('/tabs/2');
    await tester.pumpAndSettle();
    history.reports.clear();

    unawaited(_contextOf(tester, 'tab 2').replaceInPlace('/acts/a'));
    await tester.pumpAndSettle();

    expect(find.text('act a'), findsOneWidget);
    expect(history.reports, ['replace /acts/a']);
  });

  testWidgets('in a named outlet it replaces the outlet page in place', (
    tester,
  ) async {
    final history = await _pump(tester, '/acts/a');
    _contextOf(tester, 'act a').navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    final route = _routeOf(tester, 'card 1');
    history.reports.clear();

    unawaited(_contextOf(tester, 'card 1').replaceInPlace('../2'));
    await tester.pump();

    expect(_routeOf(tester, 'card 2'), same(route));
    expect(route.animation!.status, AnimationStatus.completed);
    expect(CountingPage.inits['card 2'], 1);
    expect(history.reports, ['replace /acts/a(sheet:cards/2)']);
    expect(find.text('act a'), findsOneWidget);
  });

  for (final kind in ['faded', 'custom']) {
    testWidgets('a $kind page replaced in place by another shows the new '
        'one', (tester) async {
      await _pump(tester, '/$kind/a');
      final route = _routeOf(tester, '$kind a');

      unawaited(_contextOf(tester, '$kind a').replaceInPlace('../b'));
      await tester.pumpAndSettle();

      expect(find.text('$kind a', skipOffstage: false), findsNothing);
      expect(_routeOf(tester, '$kind b'), same(route));
      expect((ActState.created, ActState.disposed), (2, 1));
    });

    testWidgets('a $kind page replaced in place in a named outlet shows the '
        'new one', (tester) async {
      await _pump(tester, '/');
      _contextOf(tester, 'home').navigateOutlets({'sheet': '/$kind/1'});
      await tester.pumpAndSettle();
      final route = _routeOf(tester, '$kind 1');

      unawaited(_contextOf(tester, '$kind 1').replaceInPlace('../2'));
      await tester.pumpAndSettle();

      expect(find.text('$kind 1', skipOffstage: false), findsNothing);
      expect(_routeOf(tester, '$kind 2'), same(route));
      expect((ActState.created, ActState.disposed), (2, 1));
    });
  }

  testWidgets('the replaced content starts with fresh page storage', (
    tester,
  ) async {
    await _pump(tester, '/list/a');
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    final scrolled = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrolled.position.pixels, greaterThan(0));

    unawaited(_contextOf(tester, 'a item 20').replaceInPlace('/list/b'));
    await tester.pumpAndSettle();

    final fresh = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(fresh.position.pixels, 0);
    expect(find.text('b item 0'), findsOneWidget);
  });

  testWidgets('replacing a pushed page keeps the URL, so another navigation '
      'in the same frame adds its history entry', (tester) async {
    final history = await _pump(tester, '/');
    unawaited(_contextOf(tester, 'home').pushNamed('/acts/a'));
    await tester.pumpAndSettle();
    history.reports.clear();

    final context = _contextOf(tester, 'act a');
    unawaited(context.replaceInPlace('/acts/b'));
    context.navigate('/acts/c');
    await tester.pumpAndSettle();

    expect(history.reports, ['push /acts/c']);
  });

  testWidgets('a page with other transition settings gets a route of its '
      'own', (tester) async {
    await _pump(tester, '/');
    unawaited(_contextOf(tester, 'home').pushNamed('/none/1'));
    await tester.pumpAndSettle();
    final route = _routeOf(tester, 'none 1');

    unawaited(_contextOf(tester, 'none 1').replaceInPlace('/faded/2'));
    await tester.pumpAndSettle();
    expect(_routeOf(tester, 'faded 2'), isNot(same(route)));

    _contextOf(tester, 'faded 2').pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('faded 2'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a translucent page replacing an opaque one shows the page '
      'below', (tester) async {
    await _pump(tester, '/');
    unawaited(_contextOf(tester, 'home').pushNamed('/faded/1'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsNothing);

    unawaited(_contextOf(tester, 'faded 1').replaceInPlace('/overlay/2'));
    await tester.pumpAndSettle();

    expect(find.text('overlay 2'), findsOneWidget);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a dialog above the page stays, and observers see no push or '
      'pop', (tester) async {
    final routeChanges = _RouteChanges();
    await _pump(tester, '/acts/a', observers: [routeChanges]);
    final context = _contextOf(tester, 'act a');
    unawaited(
      showDialog<void>(context: context, builder: (_) => const Text('dialog')),
    );
    await tester.pumpAndSettle();
    routeChanges.changes.clear();

    unawaited(context.replaceInPlace('/acts/b'));
    await tester.pumpAndSettle();

    expect(find.text('dialog'), findsOneWidget);
    expect(find.text('act b', skipOffstage: false), findsOneWidget);
    expect(routeChanges.changes, isEmpty);
  });

  testWidgets('in a nested outlet it replaces the outlet page in place; the '
      'shell stays', (tester) async {
    final history = await _pump(tester, '/tabs');
    final route = _routeOf(tester, 'tab 1');

    unawaited(_contextOf(tester, 'tab 1').replaceInPlace('/tabs/2'));
    await tester.pumpAndSettle();

    expect(_routeOf(tester, 'tab 2'), same(route));
    expect(CountingPage.inits, {'tabs shell': 1, 'tab 1': 1, 'tab 2': 1});
    expect(history.reports, ['replace /tabs/2']);
  });

  testWidgets('called inside another router, it replaces the history entry '
      'of the router it navigates', (tester) async {
    final history = await _pump(tester, '/tabs/inner');

    unawaited(_contextOf(tester, 'inner').replaceInPlace('/tabs/2'));
    await tester.pumpAndSettle();

    expect(find.text('tab 2'), findsOneWidget);
    expect(history.reports, ['replace /tabs/2']);
  });

  testWidgets('a page navigated to reads page storage the shell provides', (
    tester,
  ) async {
    await _pump(tester, '/list/a', shellStorage: PageStorageBucket());
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    _contextOf(tester, 'a item 20').navigate('/acts/a');
    await tester.pumpAndSettle();
    _contextOf(tester, 'act a').navigate('/list/a');
    await tester.pumpAndSettle();

    final restored = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(restored.position.pixels, 2000);
  });
}
