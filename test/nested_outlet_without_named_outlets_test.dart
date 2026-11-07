import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
// White-box: the parser is not exported.
import 'package:flutter_modular/src/navigation/modular_route_information_parser.dart';
import 'package:flutter_test/flutter_test.dart';

int adminGuardRuns = 0;

class OuterRepo {}

class TaggedState extends RouteState {
  const TaggedState({required super.uri});

  @override
  TaggedState copyWith({
    Uri? uri,
    Map<String, String>? params,
    Object? arguments,
  }) => TaggedState(uri: uri ?? this.uri);
}

late final Module selfIncludingModule = createModule(
  register: (c) => c
    ..route('/', child: (ctx, s) => const Text('self'))
    ..module(selfIncludingModule, at: 'no-slash'),
);

class SwapRepo implements Disposable {
  SwapRepo() {
    created++;
  }

  static int created = 0;
  static int disposed = 0;

  @override
  void dispose() => disposed++;
}

final swapModule = createModule(
  path: '/swap',
  register: (c) => c
    ..addSingleton<SwapRepo>(SwapRepo.new)
    ..route('/a', child: (ctx, s) => const Text('swap a'))
    ..route('/b', child: (ctx, s) => const Text('swap b')),
);

final swapShellModule = createModule(
  register: (c) => c.route(
    '/s',
    child: (ctx, s) => const RouterOutlet(),
    children: (sub) => sub
      ..route('/', child: (ctx, s) => const Text('index'))
      ..module(swapModule),
  ),
);

final pathlessRoutedModule = createModule(
  register: (c) => c.route('/p', child: (ctx, s) => const Text('p')),
);

final firstIncluder = createModule(
  path: '/first',
  register: (c) => c.module(pathlessRoutedModule),
);

final secondIncluder = createModule(
  path: '/second',
  register: (c) => c.module(pathlessRoutedModule),
);

final leafModule = createModule(
  path: '/d',
  register: (c) => c.route(
    '/x',
    child: (ctx, s) {
      inject<OuterRepo>();
      return const Text('leaf');
    },
  ),
);

final middleModule = createModule(
  path: '/f',
  register: (c) => c.route(
    '/shell',
    child: (ctx, s) => const RouterOutlet(),
    children: (sub) => sub.module(leafModule),
  ),
);

final outerModule = createModule(
  path: '/g',
  register: (c) => c
    ..addSingleton<OuterRepo>(OuterRepo.new)
    ..module(middleModule),
);

final twiceModule = createModule(
  path: '/once',
  register: (c) => c.route('/', child: (ctx, s) => const Text('once')),
);

final module = createModule(
  register: (c) {
    c
      ..route('/login', child: (ctx, s) => const Text('login'))
      ..route('/files/:name', child: (ctx, s) => Text('file ${s['name']}'))
      ..route(
        '/shell',
        child: (ctx, s) => const RouterOutlet(),
        children: (shell) => shell
          ..route(
            '/section',
            child: (ctx, s) => const RouterOutlet(),
            children: (section) =>
                section.route('/a', child: (ctx, s) => const Text('a')),
          )
          ..route('/b', child: (ctx, s) => const Text('b'))
          ..route(
            '/admin',
            guards: [
              (state) {
                adminGuardRuns++;
                return '/login';
              },
            ],
            child: (ctx, s) => const Text('admin'),
          ),
      );
  },
);

Future<void> _pumpModule(
  WidgetTester tester,
  Module module,
  String initialRoute,
) async {
  final boot = bootstrapModule(module);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: modularRouterConfig(
        boot.routes,
        injector: boot.injector,
        manager: boot.manager,
        initialRoute: initialRoute,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, String initialRoute) async {
  final boot = bootstrapModule(module);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: modularRouterConfig(
        boot.routes,
        injector: boot.injector,
        manager: boot.manager,
        initialRoute: initialRoute,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a guarded route beyond the nearest outlet goes through the '
      'root and its guard', (tester) async {
    adminGuardRuns = 0;
    await _pump(tester, '/shell/section/a');

    unawaited(tester.element(find.text('a')).pushNamed('/shell/admin'));
    await tester.pumpAndSettle();
    expect(find.text('admin'), findsNothing);
    expect(find.text('login'), findsOneWidget);
    expect(adminGuardRuns, 1);
  });

  testWidgets('popping asks only the nearest outlet and the root', (
    tester,
  ) async {
    await _pump(tester, '/shell/b');
    unawaited(tester.element(find.text('b')).pushNamed('/shell/section/a'));
    await tester.pumpAndSettle();
    expect(find.text('a'), findsOneWidget);

    // Only the nearest outlet takes part in primary pops.
    expect(tester.element(find.text('a')).canPop(), isFalse);
  });

  testWidgets('a path ending in `(name:path)` stays a primary path', (
    tester,
  ) async {
    await _pump(tester, '/files/report(sheet:2026)');
    expect(find.text('file report(sheet:2026)'), findsOneWidget);
  });

  test('a parser built without routes passes the location through', () async {
    final state = await ModularRouteInformationParser().parseRouteInformation(
      RouteInformation(uri: Uri.parse('myapp:///files/report(sheet:2026)')),
    );
    expect(state.uri, Uri.parse('myapp:///files/report(sheet:2026)'));
    expect(state.outlets, isEmpty);
  });

  test('locations read and write back byte for byte', () async {
    final parser = ModularRouteInformationParser(
      routes: bootstrapModule(module).routes,
    );
    for (final location in [
      '/home(sheet:card)',
      '/home%28sheet%3Acard%29?x=a%2Fb#frag',
      'myapp://host/home(sheet:card)?q=1#x',
      '/home()',
      '/home(sheet:)',
    ]) {
      final uri = Uri.parse(location);
      final state = await parser.parseRouteInformation(
        RouteInformation(uri: uri),
      );
      expect(state.uri, uri);
      expect(parser.restoreRouteInformation(state).uri, uri);
    }
  });

  test('a RouteState without outlets prints as before', () {
    expect(
      RouteState(uri: Uri.parse('/a')).toString(),
      'RouteState(/a, params: {}, arguments: null)',
    );
  });

  test('an outlet state that was never mounted pops nothing', () {
    final outlet = RouterOutletState();
    expect(outlet.canPop, isFalse);
    expect(outlet.maybePop(), isFalse);
    outlet
      ..pop()
      ..popUntil((state) => true);
  });

  testWidgets('a deep link into a nested feature binds every feature above', (
    tester,
  ) async {
    final boot = bootstrapModule(
      createModule(register: (c) => c.module(outerModule)),
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: modularRouterConfig(
          boot.routes,
          injector: boot.injector,
          manager: boot.manager,
          initialRoute: '/g/f/shell/d/x',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('leaf'), findsOneWidget);
  });

  test('a module included twice by one module mounts once', () {
    final boot = bootstrapModule(
      createModule(
        register: (c) => c
          ..module(twiceModule)
          ..module(twiceModule, at: '/other'),
      ),
    );
    expect(boot.routes.match(Uri.parse('/once')), isNotNull);
    expect(boot.routes.match(Uri.parse('/other')), isNull);
  });

  test('a mounted route without children keeps an unmodifiable list', () {
    final boot = bootstrapModule(
      createModule(register: (c) => c.module(twiceModule)),
    );
    expect(
      () => boot.routes.routes.single.children.add(boot.routes.routes.single),
      throwsUnsupportedError,
    );
  });

  testWidgets('replacing inside an outlet releases a feature before binding '
      'it again', (tester) async {
    SwapRepo.created = 0;
    SwapRepo.disposed = 0;
    await _pumpModule(tester, swapShellModule, '/s/');
    unawaited(tester.element(find.text('index')).pushNamed('/s/swap/a'));
    await tester.pumpAndSettle();
    expect(SwapRepo.created, 1);

    unawaited(tester.element(find.text('swap a')).replace('/s/swap/b'));
    await tester.pumpAndSettle();
    expect(SwapRepo.disposed, 1);
    expect(SwapRepo.created, 2);

    unawaited(tester.element(find.text('swap b')).popAndPushNamed('/s/swap/a'));
    await tester.pumpAndSettle();
    expect(SwapRepo.disposed, 2);
    expect(SwapRepo.created, 3);
  });

  test('root-owned routes keep unmodifiable owner tags', () {
    final boot = bootstrapModule(
      createModule(register: (c) => c.module(pathlessRoutedModule)),
    );
    expect(
      () => boot.routes.routes.single.ownerTags.add('x'),
      throwsUnsupportedError,
    );
  });

  test('a module included twice mounts only at its first include', () {
    final boot = bootstrapModule(
      createModule(
        register: (c) => c
          ..module(firstIncluder)
          ..module(secondIncluder),
      ),
    );
    expect(boot.routes.match(Uri.parse('/first/p')), isNotNull);
    expect(boot.routes.match(Uri.parse('/second/p')), isNull);
  });

  testWidgets('a RouteState subclass keeps its type through a tab switch', (
    tester,
  ) async {
    final boot = bootstrapModule(module);
    final config = modularRouterConfig(boot.routes, injector: boot.injector);
    await tester.pumpWidget(MaterialApp.router(routerConfig: config));
    await config.routerDelegate.setNewRoutePath(
      TaggedState(uri: Uri.parse('/shell/b')),
    );
    await tester.pumpAndSettle();

    tester.element(find.text('b')).navigate('/shell/section/a');
    await tester.pumpAndSettle();
    expect(config.routerDelegate.currentConfiguration, isA<TaggedState>());
  });

  test('an included module included again is skipped before its path is '
      'checked', () {
    expect(() => bootstrapModule(selfIncludingModule), returnsNormally);
    expect(
      () => bootstrapModule(
        createModule(
          register: (c) => c
            ..module(twiceModule)
            ..module(twiceModule, at: 'no-slash'),
        ),
      ),
      returnsNormally,
    );
  });

  testWidgets('replacing with an unparsable path still releases the top '
      'entry', (tester) async {
    SwapRepo.created = 0;
    SwapRepo.disposed = 0;
    await _pumpModule(tester, swapShellModule, '/s/');
    unawaited(tester.element(find.text('index')).pushNamed('/s/swap/a'));
    await tester.pumpAndSettle();

    final outlet = RouterOutlet.of(tester.element(find.text('swap a')))!;
    expect(() => outlet.replace('http://['), throwsFormatException);
    expect(outlet.canPop, isFalse);
    expect(SwapRepo.disposed, 1);
  });
}
