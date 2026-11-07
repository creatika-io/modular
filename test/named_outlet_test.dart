import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  static int inits = 0;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int taps = 0;

  @override
  void initState() {
    super.initState();
    HomePage.inits++;
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('home taps:$taps'),
  );
}

class FeatureRepo implements Disposable {
  FeatureRepo() {
    created++;
  }

  static int created = 0;
  static int disposed = 0;

  @override
  void dispose() => disposed++;
}

final featureModule = createModule(
  path: '/feature',
  register: (c) => c.outlet('sheet')
    ..addSingleton<FeatureRepo>(FeatureRepo.new)
    ..route(
      '/card',
      child: (ctx, s) {
        inject<FeatureRepo>();
        return const Text('feature card');
      },
    )
    ..route(
      '/other',
      child: (ctx, s) {
        inject<FeatureRepo>();
        return const Text('feature other');
      },
    ),
);

int editingGuardRuns = 0;

String? _editingNeedsLogin(RouteState state) {
  editingGuardRuns++;
  return state.arguments == 'edit' ? '/login' : null;
}

final module = createModule(
  register: (c) {
    c
      ..route('/', child: (ctx, s) => const HomePage())
      ..route('/other', child: (ctx, s) => const Text('other'))
      ..route('/detail', child: (ctx, s) => const Text('detail'))
      ..route(
        '/vip',
        guards: [(state) => '/(sheet:cards/1)'],
        child: (ctx, s) => const Text('vip'),
      )
      ..route(
        '/to-needs-sheet',
        guards: [(state) => '/needs-sheet(sheet:cards/1)'],
        child: (ctx, s) => const Text('to needs sheet'),
      )
      ..route(
        '/needs-sheet',
        guards: [(state) => state.outlets.containsKey('sheet') ? null : '/'],
        child: (ctx, s) => const Text('needs sheet'),
      )
      ..module(featureModule);
    c.outlet('sheet')
      ..route('/cards/:id', child: (ctx, s) => Text('card ${s['id']}'))
      ..route('/cards/:id/more', child: (ctx, s) => Text('more ${s['id']}'))
      ..route(
        '/admin',
        guards: [(state) => '/login'],
        child: (ctx, s) => const Text('admin'),
      )
      ..route('/login', child: (ctx, s) => const Text('login'))
      ..route(
        '/secret/:id',
        guards: [(state) => state['id'] == 'mine' ? null : '/login'],
        child: (ctx, s) => Text('secret ${s['id']}'),
      )
      ..route(
        '/loop',
        guards: [(state) => '/loop'],
        child: (ctx, s) => const Text('loop'),
      )
      ..route(
        '/tabs',
        child: (ctx, s) => const RouterOutlet(),
        children: (sub) => sub
          ..route('/', child: (ctx, s) => const Text('tab a'))
          ..route('/b', child: (ctx, s) => const Text('tab b'))
          ..route(
            '/admin',
            guards: [(state) => '/tabs/b'],
            child: (ctx, s) => const Text('tab admin'),
          )
          ..route(
            '/vip',
            guards: [(state) => '/login'],
            child: (ctx, s) => const Text('tab vip'),
          )
          ..route(
            '/form',
            guards: [_editingNeedsLogin],
            child: (ctx, s) => const Text('tab form'),
          ),
      )
      ..route(
        '/locked',
        guards: [(state) => '/detail'], // a primary route, none of the sheet's
        child: (ctx, s) => const Text('locked'),
      )
      ..route(
        '/vault(1)',
        guards: [(state) => '/login'],
        child: (ctx, s) => const Text('vault'),
      )
      ..route('/files/:name', child: (ctx, s) => Text('file ${s['name']}'))
      ..route(
        '/nested-outlet',
        child: (ctx, s) => const RouterOutlet(name: 'panel'),
      );
    c.outlet('panel').route('/help', child: (ctx, s) => const Text('help'));
  },
);

Widget _shell(BuildContext context, Widget child) => Row(
  children: [
    Expanded(child: child),
    const SizedBox(width: 200, child: RouterOutlet(name: 'sheet')),
    const SizedBox(width: 200, child: RouterOutlet(name: 'panel')),
  ],
);

Future<void> _pump(WidgetTester tester) async {
  HomePage.inits = 0;
  final boot = bootstrapModule(module);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: modularRouterConfig(
        boot.routes,
        injector: boot.injector,
        manager: boot.manager,
        shellBuilder: _shell,
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

BuildContext _contextOf(WidgetTester tester, String text) =>
    tester.element(find.text(text));

BuildContext _home(WidgetTester tester) =>
    tester.element(find.byType(HomePage));

void main() {
  testWidgets('navigateOutlets opens, reseeds and closes a named outlet', (
    tester,
  ) async {
    await _pump(tester);
    expect(_reportedUrl(tester), '/');

    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/1)');

    unawaited(_contextOf(tester, 'card 1').pushNamed('more'));
    await tester.pumpAndSettle();
    _home(tester).navigateOutlets({'sheet': '/cards/2'});
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsOneWidget);
    expect(find.text('more 1', skipOffstage: false), findsNothing);
    expect(_reportedUrl(tester), '/(sheet:cards/2)');

    _home(tester).navigateOutlets({'panel': '/help'});
    await tester.pumpAndSettle();
    expect(find.text('help'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/2//panel:help)');

    _home(tester).navigateOutlets({'sheet': null});
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsNothing);
    expect(find.text('help'), findsOneWidget);
    expect(_reportedUrl(tester), '/(panel:help)');
  });

  testWidgets('a URL change of the outlets alone keeps the primary page', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('home taps:0'));
    await tester.pumpAndSettle();

    await tester.binding.handlePushRoute('/(sheet:cards/1)');
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);
    expect(find.text('home taps:1'), findsOneWidget);
    expect(HomePage.inits, 1);

    await tester.binding.handlePushRoute('/');
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsNothing);
    expect(find.text('home taps:1'), findsOneWidget);
    expect(HomePage.inits, 1);

    await tester.binding.handlePushRoute('myapp:///(sheet:cards/2)');
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsOneWidget);
    expect(find.text('home taps:1'), findsOneWidget);
    expect(HomePage.inits, 1);
    expect(_reportedUrl(tester), '/(sheet:cards/2)');
  });

  testWidgets('a URL change of the outlets drops the pages pushed above the '
      'base', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('home taps:0'));
    await tester.pumpAndSettle();
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    final detailResult = _home(tester).pushNamed<String>('/detail');
    await tester.pumpAndSettle();

    await tester.binding.handlePushRoute('/');
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsNothing);
    expect(find.text('card 1'), findsNothing);
    expect(find.text('home taps:1'), findsOneWidget);
    expect(HomePage.inits, 1);
    expect(await detailResult, isNull);
  });

  testWidgets('pops beyond an emptied outlet never reach the page beneath', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();

    _contextOf(tester, 'card 1')
      ..pop()
      ..pop()
      ..pop();
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    expect(_reportedUrl(tester), '/');
  });

  testWidgets('a deep link opens the primary route and its outlets', (
    tester,
  ) async {
    tester.platformDispatcher.defaultRouteNameTestValue =
        '/other(sheet:cards/7)';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    await _pump(tester);

    expect(find.text('other'), findsOneWidget);
    expect(find.text('card 7'), findsOneWidget);
    expect(_reportedUrl(tester), '/other(sheet:cards/7)');
  });

  testWidgets('the URL shows the top page of the outlet; pop returns', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();

    final card = _contextOf(tester, 'card 1');
    expect(card.canPop(), isTrue);
    final result = card.pushNamed<String>('/cards/2');
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/2)');

    _contextOf(tester, 'card 2').pop('done');
    await tester.pumpAndSettle();
    expect(await result, 'done');
    expect(find.text('card 1'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/1)');

    _contextOf(tester, 'card 1').pop();
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsNothing);
    expect(_reportedUrl(tester), '/');
  });

  testWidgets('popAndPushNamed in an outlet delivers the result it pops with', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    final popped = _contextOf(tester, 'card 1').pushNamed<String>('/cards/2');
    await tester.pumpAndSettle();

    final pushed = _contextOf(
      tester,
      'card 2',
    ).popAndPushNamed<String>('/cards/3', result: 'saved');
    await tester.pumpAndSettle();
    expect(await popped, 'saved');
    _contextOf(tester, 'card 3').pop('closed');
    expect(await pushed, 'closed');
  });

  testWidgets('outlet routes are not primary routes', (tester) async {
    await _pump(tester);
    _home(tester).navigate('/cards/1');
    await tester.pumpAndSettle();
    expect(find.text('Route not found'), findsOneWidget);
    expect(find.text('card 1'), findsNothing);
  });

  test('an outlet scope cannot be opened inside children', () {
    final nested = createModule(
      register: (c) => c.route(
        '/shell',
        child: (ctx, s) => const RouterOutlet(),
        children: (sub) => sub
            .outlet('sheet')
            .route('/card', child: (ctx, s) => const Text('card')),
      ),
    );
    expect(() => bootstrapModule(nested), throwsAssertionError);
  });

  testWidgets('an outlet route renders its children in a nested outlet', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/tabs'});
    await tester.pumpAndSettle();
    expect(find.text('tab a'), findsOneWidget);

    _contextOf(tester, 'tab a').navigate('/tabs/b');
    await tester.pumpAndSettle();
    expect(find.text('tab b'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:tabs)');
  });

  testWidgets('relative paths resolve inside the outlet; others bubble up', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();

    unawaited(_contextOf(tester, 'card 1').pushNamed('more'));
    await tester.pumpAndSettle();
    expect(find.text('more 1'), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);

    unawaited(_contextOf(tester, 'more 1').pushNamed('/detail'));
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(find.text('more 1'), findsNothing);
    expect(_reportedUrl(tester), '/(sheet:cards/1/more)');

    _contextOf(tester, 'detail').pop();
    await tester.pumpAndSettle();
    expect(find.text('more 1'), findsOneWidget);
  });

  testWidgets('navigate drops the outlets it does not list', (tester) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();

    unawaited(_home(tester).pushNamed('/detail'));
    await tester.pumpAndSettle();
    expect(_reportedUrl(tester), '/(sheet:cards/1)');

    _contextOf(tester, 'detail').navigate('/other');
    await tester.pumpAndSettle();
    expect(find.text('other'), findsOneWidget);
    expect(find.text('card 1'), findsNothing);
    expect(_reportedUrl(tester), '/other');

    _contextOf(tester, 'other').navigate('/(sheet:cards/3)');
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.text('card 3'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/3)');

    // A new primary page resets the outlet even when its base is unchanged.
    unawaited(_contextOf(tester, 'card 3').pushNamed('/cards/4'));
    await tester.pumpAndSettle();
    _contextOf(tester, 'card 4').navigate('/(sheet:cards/3)');
    await tester.pumpAndSettle();
    expect(find.text('card 3'), findsOneWidget);
    expect(find.text('card 4', skipOffstage: false), findsNothing);
  });

  testWidgets('guards run for outlet routes and redirect inside the outlet', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/admin'});
    await tester.pumpAndSettle();
    expect(find.text('admin'), findsNothing);
    expect(find.text('login'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:login)');

    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    unawaited(_contextOf(tester, 'card 1').pushNamed('/admin'));
    await tester.pumpAndSettle();
    expect(find.text('login'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:login)');
  });

  testWidgets('guards run for the children of an outlet route', (tester) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/tabs'});
    await tester.pumpAndSettle();

    unawaited(_contextOf(tester, 'tab a').pushNamed('/tabs/admin'));
    await tester.pumpAndSettle();
    expect(find.text('tab admin'), findsNothing);
    expect(find.text('tab b'), findsOneWidget);

    unawaited(_contextOf(tester, 'tab b').pushNamed('/tabs/vip'));
    await tester.pumpAndSettle();
    expect(find.text('tab vip'), findsNothing);
    expect(find.text('login'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:login)');
  });

  testWidgets('outlet guards see the path params', (tester) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/secret/mine'});
    await tester.pumpAndSettle();
    expect(find.text('secret mine'), findsOneWidget);

    unawaited(_contextOf(tester, 'secret mine').pushNamed('/secret/yours'));
    await tester.pumpAndSettle();
    expect(find.text('secret yours'), findsNothing);
    expect(find.text('login'), findsOneWidget);
  });

  testWidgets('an outlet redirect cycle never shows its page', (tester) async {
    await _pump(tester);
    expect(
      () => _home(tester).navigateOutlets({'sheet': '/loop'}),
      throwsFlutterError,
    );
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    expect(
      () => _contextOf(tester, 'card 1').pushNamed('/loop'),
      throwsFlutterError,
    );

    await tester.binding.handlePushRoute('/(sheet:loop//panel:help)');
    await tester.pumpAndSettle();
    expect(find.text('loop'), findsNothing);
    expect(find.text('card 1'), findsNothing);
    expect(_reportedUrl(tester), '/(panel:help)');
  });

  testWidgets('an outlet-only URL change runs the primary guards again', (
    tester,
  ) async {
    tester.platformDispatcher.defaultRouteNameTestValue =
        '/needs-sheet(sheet:cards/1)';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    await _pump(tester);
    expect(find.text('needs sheet'), findsOneWidget);

    await tester.binding.handlePushRoute('/needs-sheet');
    await tester.pumpAndSettle();
    expect(find.text('needs sheet'), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    expect(_reportedUrl(tester), '/');
  });

  testWidgets('a guard runs once, with the arguments, to pick the outlet', (
    tester,
  ) async {
    editingGuardRuns = 0;
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/tabs'});
    await tester.pumpAndSettle();

    unawaited(_contextOf(tester, 'tab a').pushNamed('/tabs/form'));
    await tester.pumpAndSettle();
    expect(find.text('tab form'), findsOneWidget);
    expect(editingGuardRuns, 1);

    unawaited(
      _contextOf(tester, 'tab form').pushNamed('/tabs/form', arguments: 'edit'),
    );
    await tester.pumpAndSettle();
    expect(find.text('login'), findsOneWidget);
    expect(editingGuardRuns, 2);
  });

  testWidgets('a redirect matching none of the outlet routes stays in it', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();

    unawaited(_contextOf(tester, 'card 1').pushNamed('/locked'));
    await tester.pumpAndSettle();
    expect(find.text('locked'), findsNothing);
    expect(find.text('detail'), findsNothing);
    expect(find.text('Route not found'), findsNothing);
    expect(find.text('card 1'), findsNothing); // covered by an empty page
    expect(_home(tester).canPop(), isFalse);
    expect(_reportedUrl(tester), '/(sheet:detail)');
  });

  testWidgets('primary guards see the outlets and may redirect to them', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigate('/vip');
    await tester.pumpAndSettle();
    expect(find.text('vip'), findsNothing);
    expect(find.text('card 1'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/1)');

    _home(tester).navigate('/needs-sheet(sheet:cards/2)');
    await tester.pumpAndSettle();
    expect(find.text('needs sheet'), findsOneWidget);
    expect(find.text('card 2'), findsOneWidget);

    _contextOf(tester, 'needs sheet').navigate('/needs-sheet');
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(_reportedUrl(tester), '/');
  });

  testWidgets('a redirect while pushing opens the outlets it lists', (
    tester,
  ) async {
    await _pump(tester);
    unawaited(_home(tester).pushNamed('/to-needs-sheet'));
    await tester.pumpAndSettle();
    expect(find.text('needs sheet'), findsOneWidget);
    expect(find.text('card 1', skipOffstage: false), findsOneWidget);
    expect(
      _reportedUrl(tester),
      '/(sheet:cards/1)',
    ); // the push stays out of it

    _contextOf(tester, 'needs sheet').navigateOutlets({'sheet': null});
    await tester.pumpAndSettle();
    unawaited(_contextOf(tester, 'needs sheet').replace('/to-needs-sheet'));
    await tester.pumpAndSettle();
    expect(find.text('needs sheet'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:cards/1)');
  });

  testWidgets('the reported URL carries outlets, query and fragment', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigate('/other(sheet:cards/1)?tab=2#top');
    await tester.pumpAndSettle();
    expect(find.text('other'), findsOneWidget);
    expect(find.text('card 1'), findsOneWidget);
    expect(_reportedUrl(tester), '/other(sheet:cards/1)?tab=2#top');
  });

  testWidgets('a guard sees the canonical path, whatever its encoding', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/vault%281%29/?x=1'});
    await tester.pumpAndSettle();
    expect(find.text('vault'), findsNothing);
    expect(find.text('login'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:login)');

    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    unawaited(_contextOf(tester, 'card 1').pushNamed('/vault%281%29'));
    await tester.pumpAndSettle();
    expect(find.text('vault'), findsNothing);
    expect(find.text('login'), findsOneWidget);
  });

  testWidgets('navigateOutlets to the same base resets the outlet; the URL '
      'echo does not', (tester) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    unawaited(_contextOf(tester, 'card 1').pushNamed('/cards/2'));
    await tester.pumpAndSettle();

    await tester.binding.handlePushRoute('/(sheet:cards/2)');
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsOneWidget);
    expect(find.text('card 1', skipOffstage: false), findsOneWidget);

    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);
    expect(find.text('card 2', skipOffstage: false), findsNothing);
    expect(_reportedUrl(tester), '/(sheet:cards/1)');
  });

  testWidgets('a nested outlet in an outlet page reaches the named outlet', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/tabs'});
    await tester.pumpAndSettle();

    // `/cards/1` is no child of `/tabs`: the named outlet around takes it.
    final tab = _contextOf(tester, 'tab a');
    unawaited(tab.pushNamed('/cards/1'));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);
    expect(find.text('Route not found'), findsNothing);

    _contextOf(tester, 'card 1').pop();
    await tester.pumpAndSettle();

    // The nested outlet has one page; the named one can still close.
    expect(_contextOf(tester, 'tab a').canPop(), isTrue);
    _contextOf(tester, 'tab a').pop();
    await tester.pumpAndSettle();
    expect(find.text('tab a'), findsNothing);
    expect(_reportedUrl(tester), '/');
  });

  testWidgets('a named outlet inside another outlet page is rejected', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/nested-outlet'});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isAssertionError);
  });

  testWidgets('outlet locations are canonical, so the URL echo keeps state', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/files/report%281%29/?v=2#top'});
    await tester.pumpAndSettle();
    expect(find.text('file report(1)'), findsOneWidget);
    expect(_reportedUrl(tester), '/(sheet:files/report%281%29)');

    unawaited(_contextOf(tester, 'file report(1)').pushNamed('/cards/2'));
    await tester.pumpAndSettle();

    await tester.binding.handlePushRoute(_reportedUrl(tester)!);
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsOneWidget);

    _contextOf(tester, 'card 2').navigate('/cards/3?mode=edit');
    await tester.pumpAndSettle();
    expect(_reportedUrl(tester), '/(sheet:cards/3)');
    unawaited(_contextOf(tester, 'card 3').pushNamed('/cards/4'));
    await tester.pumpAndSettle();
    await tester.binding.handlePushRoute(_reportedUrl(tester)!);
    await tester.pumpAndSettle();
    expect(find.text('card 4'), findsOneWidget);
  });

  testWidgets('an outlet route of a feature module gets its binds', (
    tester,
  ) async {
    FeatureRepo.created = 0;
    FeatureRepo.disposed = 0;
    await _pump(tester);
    expect(FeatureRepo.created, 0);

    _home(tester).navigateOutlets({'sheet': '/feature/card'});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('feature card'), findsOneWidget);
    expect(FeatureRepo.created, 1);

    _home(tester).navigateOutlets({'sheet': '/feature/other'});
    await tester.pumpAndSettle();
    expect(find.text('feature other'), findsOneWidget);
    unawaited(_contextOf(tester, 'feature other').pushNamed('/feature/card'));
    await tester.pumpAndSettle();
    _home(tester).navigateOutlets({'sheet': '/feature/other'});
    await tester.pumpAndSettle();
    expect(find.text('feature card', skipOffstage: false), findsNothing);
    unawaited(_contextOf(tester, 'feature other').replace('/feature/card'));
    await tester.pumpAndSettle();
    expect(find.text('feature card'), findsOneWidget);
    unawaited(
      _contextOf(tester, 'feature card').popAndPushNamed('/feature/other'),
    );
    await tester.pumpAndSettle();
    expect(find.text('feature other'), findsOneWidget);
    expect(FeatureRepo.created, 1);
    expect(FeatureRepo.disposed, 0);

    _home(tester).navigateOutlets({'sheet': null});
    await tester.pumpAndSettle();
    expect(FeatureRepo.disposed, 1);
  });

  testWidgets('a custom builder presents the stack, bottom to top', (
    tester,
  ) async {
    final presented = <List<RouteState>>[];
    final boot = bootstrapModule(module);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: modularRouterConfig(
          boot.routes,
          injector: boot.injector,
          manager: boot.manager,
          shellBuilder: (context, child) => Row(
            children: [
              Expanded(child: child),
              Expanded(
                child: RouterOutlet(
                  name: 'sheet',
                  builder: (context, entries) {
                    presented.add([for (final e in entries) e.state]);
                    return Column(
                      children: [
                        for (final entry in entries)
                          KeyedSubtree(key: entry.key, child: entry.child),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(presented.last, isEmpty);
    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    unawaited(_contextOf(tester, 'card 1').pushNamed('/cards/2'));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget); // no Navigator: both shown
    expect(find.text('card 2'), findsOneWidget);
    expect(
      [for (final s in presented.last) s.uri.path],
      ['/cards/1', '/cards/2'],
    );
    expect(presented.last.last.params, {'id': '2'});

    _contextOf(tester, 'card 2').pop();
    await tester.pumpAndSettle();
    expect([for (final s in presented.last) s.uri.path], ['/cards/1']);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(presented.last, isEmpty);
    expect(_reportedUrl(tester), '/');

    _home(tester).navigateOutlets({'sheet': '/cards/1'});
    await tester.pumpAndSettle();
    _contextOf(tester, 'card 1')
      ..pop()
      ..pop()
      ..pop();
    await tester.pumpAndSettle();
    expect(presented.last, isEmpty);
    expect(find.byType(HomePage), findsOneWidget);
    expect(_reportedUrl(tester), '/');
  });

  testWidgets('closeOutlet closes a named outlet, by name or from inside', (
    tester,
  ) async {
    await _pump(tester);
    _home(tester).navigateOutlets({'sheet': '/cards/1', 'panel': '/help'});
    await tester.pumpAndSettle();

    _home(tester).closeOutlet('panel');
    await tester.pumpAndSettle();
    expect(find.text('help'), findsNothing);
    expect(_reportedUrl(tester), '/(sheet:cards/1)');

    unawaited(_contextOf(tester, 'card 1').pushNamed('/cards/2'));
    await tester.pumpAndSettle();
    _contextOf(tester, 'card 2').closeOutlet();
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsNothing);
    expect(_reportedUrl(tester), '/');

    expect(() => _home(tester).closeOutlet(), throwsFlutterError);
  });

  testWidgets('a location with outlets goes to the root from any outlet', (
    tester,
  ) async {
    final shellModule = createModule(
      register: (c) {
        c.route(
          '/',
          child: (ctx, s) => const RouterOutlet(),
          children: (sub) =>
              sub.route('/:id', child: (ctx, s) => Text('item ${s['id']}')),
        );
        c.outlet('sheet').route('/card', child: (ctx, s) => const Text('card'));
      },
    );
    final boot = bootstrapModule(shellModule);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: modularRouterConfig(
          boot.routes,
          injector: boot.injector,
          initialRoute: '/x',
          shellBuilder: (context, child) => Row(
            children: [
              Expanded(child: child),
              const Expanded(child: RouterOutlet(name: 'sheet')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    _contextOf(tester, 'item x').navigate('/home(sheet:card)');
    await tester.pumpAndSettle();
    expect(find.text('item home'), findsOneWidget);
    expect(find.text('card'), findsOneWidget);
    expect(_reportedUrl(tester), '/home(sheet:card)');
  });

  testWidgets('ModularApp applies a new shellBuilder, keeping page state', (
    tester,
  ) async {
    HomePage.inits = 0;
    final revision = ValueNotifier(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<int>(
        valueListenable: revision,
        builder: (context, value, _) => ModularApp(
          module: module,
          shellBuilder: (context, child) => Column(
            children: [
              Text('shell $value'),
              Expanded(child: child),
            ],
          ),
          child: Builder(
            builder: (context) => MaterialApp.router(
              routerConfig: ModularApp.routerConfigOf(context),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('home taps:0'));
    revision.value++;
    await tester.pumpAndSettle();
    expect(find.text('shell 1'), findsOneWidget);
    expect(find.text('home taps:1'), findsOneWidget);
    expect(HomePage.inits, 1);
  });
}
