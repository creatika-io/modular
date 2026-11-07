import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

class ItemRepo implements Disposable {
  ItemRepo() {
    created++;
  }

  static int created = 0;
  static int disposed = 0;

  @override
  void dispose() => disposed++;
}

class ItemPage extends StatelessWidget {
  const ItemPage({required this.id, super.key});

  final String id;

  @override
  Widget build(BuildContext context) {
    inject<ItemRepo>();
    return Text('item $id');
  }
}

/// Knows nothing of outlets.
final itemsModule = createModule(
  path: '/items',
  register: (c) => c
    ..addSingleton<ItemRepo>(ItemRepo.new)
    ..route('/:id', child: (ctx, s) => ItemPage(id: s['id']!)),
);

class Resource {
  Resource() {
    constructed++;
  }

  static int constructed = 0;
}

class BareRepo {}

class ARepo {}

class BRepo {}

final detailsModule = createModule(
  path: '/details',
  register: (c) =>
      c.route('/:id', child: (ctx, s) => Text('detail ${s['id']}')),
);

final shelfModule = createModule(
  path: '/shelf',
  register: (c) => c.route(
    '/',
    child: (ctx, s) => const RouterOutlet(),
    children: (sub) => sub.module(detailsModule),
  ),
);

final bareModule = createModule(
  register: (c) => c
    ..addSingleton<BareRepo>(BareRepo.new)
    ..route(
      '/bare',
      child: (ctx, s) {
        inject<BareRepo>();
        return const Text('bare');
      },
    ),
);

final aModule = createModule(
  path: '/x',
  register: (c) => c
    ..addSingleton<ARepo>(ARepo.new)
    ..route(
      '/a',
      child: (ctx, s) {
        inject<ARepo>();
        return const Text('a');
      },
    ),
);

final bModule = createModule(
  path: '/x',
  register: (c) => c
    ..addSingleton<BRepo>(BRepo.new)
    ..route(
      '/b',
      child: (ctx, s) {
        inject<BRepo>();
        return const Text('b');
      },
    ),
);

final resourceModule = createModule(
  path: '/res',
  register: (c) => c
    ..addInstance<Resource>(Resource())
    ..route('/', child: (ctx, s) => const Text('res')),
);

class CycleRepo {}

late final Module cycleA = createModule(
  path: '/a',
  register: (c) => c
    ..addInstance<Resource>(Resource())
    ..module(cycleB)
    ..route('/', child: (ctx, s) => const Text('cycle a')),
);

late final Module cycleB = createModule(
  path: '/b',
  register: (c) => c
    ..module(cycleA)
    ..route('/', child: (ctx, s) => const Text('cycle b')),
);

late final Module sharedA = createModule(
  register: (c) => c
    ..addSingleton<CycleRepo>(CycleRepo.new)
    ..module(sharedB),
);

late final Module sharedB = createModule(register: (c) => c.module(sharedA));

final innerModule = createModule(
  path: '/inner',
  register: (c) => c.route('/', child: (ctx, s) => const Text('inner')),
);

final collidingModule = createModule(
  path: '/x',
  register: (c) => c
    ..addSingleton<BRepo>(BRepo.new)
    ..module(innerModule),
);

final module = createModule(
  register: (c) {
    c
      ..route('/', child: (ctx, s) => const Text('home'))
      ..module(itemsModule);
    c.outlet('sheet').module(itemsModule, at: '/peek');
  },
);

Module _mountedTwice(void Function(ModularContext c) mounts) => createModule(
  register: (c) {
    c.route('/', child: (ctx, s) => const Text('home'));
    mounts(c);
  },
);

Future<void> _pump(WidgetTester tester, Module module) async {
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
            const Expanded(child: RouterOutlet(name: 'sheet')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a module mounted twice shows its page in the outlet and as a '
      'page, sharing one set of binds', (tester) async {
    ItemRepo.created = 0;
    ItemRepo.disposed = 0;
    await _pump(tester, module);

    tester.element(find.text('home')).navigateOutlets({'sheet': '/peek/1'});
    await tester.pumpAndSettle();
    expect(find.byType(ItemPage), findsOneWidget);
    expect(find.text('home'), findsOneWidget);
    expect(ItemRepo.created, 1);

    final page = tester.element(find.text('home')).pushNamed('/items/2');
    await tester.pumpAndSettle();
    expect(find.text('item 2'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(ItemRepo.created, 1);

    tester.element(find.text('item 2')).pop();
    await page;
    await tester.pumpAndSettle();
    expect(ItemRepo.disposed, 0); // the sheet still uses it

    tester.element(find.text('home')).closeOutlet('sheet');
    await tester.pumpAndSettle();
    expect(ItemRepo.disposed, 1);

    unawaited(tester.element(find.text('home')).pushNamed('/items/3'));
    await tester.pumpAndSettle();
    expect(ItemRepo.created, 2);
  });

  test('a module mounted into an outlet declares no outlet itself', () {
    final declaresOutlet = createModule(
      path: '/x',
      register: (c) =>
          c.outlet('panel').route('/', child: (ctx, s) => const Text('x')),
    );
    expect(
      () => bootstrapModule(
        createModule(register: (c) => c.outlet('sheet').module(declaresOutlet)),
      ),
      throwsAssertionError,
    );
  });

  test('a module is mounted into an outlet outside children', () {
    expect(
      () => bootstrapModule(
        createModule(
          register: (c) => c.route(
            '/shell',
            child: (ctx, s) => const RouterOutlet(),
            children: (sub) => sub.outlet('sheet').module(itemsModule),
          ),
        ),
      ),
      throwsAssertionError,
    );
  });

  testWidgets('child modules of a module come along into the outlet', (
    tester,
  ) async {
    await _pump(
      tester,
      _mountedTwice((c) {
        c.module(shelfModule);
        c.outlet('sheet').module(shelfModule);
      }),
    );
    tester.element(find.text('home')).navigateOutlets({
      'sheet': '/shelf/details/7',
    });
    await tester.pumpAndSettle();
    expect(find.text('detail 7'), findsOneWidget);
  });

  testWidgets('a pathless module keeps its binds in a later outlet mount', (
    tester,
  ) async {
    await _pump(
      tester,
      _mountedTwice((c) {
        c.module(bareModule, at: '/full');
        c.outlet('sheet').module(bareModule);
      }),
    );
    tester.element(find.text('home')).navigateOutlets({'sheet': '/bare'});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('bare'), findsOneWidget);
  });

  testWidgets('different modules at one path keep their own binds', (
    tester,
  ) async {
    await _pump(
      tester,
      _mountedTwice((c) {
        c.module(aModule);
        c.outlet('sheet').module(bModule);
      }),
    );
    tester.element(find.text('home')).navigateOutlets({'sheet': '/x/b'});
    await tester.pumpAndSettle();
    unawaited(tester.element(find.text('home')).pushNamed('/x/a'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('a'), findsOneWidget);
  });

  test('a module mounted twice registers once', () {
    Resource.constructed = 0;
    bootstrapModule(
      _mountedTwice((c) {
        c.module(resourceModule);
        c.outlet('sheet').module(resourceModule);
      }),
    );
    expect(Resource.constructed, 1);
  });

  test('a module is included once; an outlet mount reuses that inclusion', () {
    final boot = bootstrapModule(
      _mountedTwice((c) {
        c.module(detailsModule);
        c.outlet('sheet').module(shelfModule);
      }),
    );
    expect(boot.routes.match(Uri.parse('/details/8')), isNotNull);
    expect(
      boot.routes.matchOutlet('sheet', Uri.parse('/shelf/details/7')),
      isNull,
    );
  });

  test('modules that include each other register once', () {
    Resource.constructed = 0;
    bootstrapModule(_mountedTwice((c) => c.outlet('sheet').module(cycleA)));
    expect(Resource.constructed, 1);
    bootstrapModule(_mountedTwice((c) => c.outlet('sheet').module(sharedA)));
  });

  test('an outlet mount qualifies its lifecycle tags with the outlet', () {
    final boot = bootstrapModule(
      _mountedTwice((c) {
        c.module(aModule);
        c.outlet('sheet').module(collidingModule);
      }),
    );
    expect(boot.routes.match(Uri.parse('/x/a'))!.last.route.ownerTags, ['/x']);
    expect(
      boot.routes
          .matchOutlet('sheet', Uri.parse('/x/inner'))!
          .last
          .route
          .ownerTags,
      ['sheet:/x', 'sheet:/x/inner'],
    );
  });

  test('distinct modules at one path in one outlet keep separate tags', () {
    final boot = bootstrapModule(
      _mountedTwice(
        (c) => c.outlet('sheet')
          ..module(aModule)
          ..module(bModule),
      ),
    );
    expect(
      boot.routes.matchOutlet('sheet', Uri.parse('/x/a'))!.last.route.ownerTags,
      ['sheet:/x'],
    );
    expect(
      boot.routes.matchOutlet('sheet', Uri.parse('/x/b'))!.last.route.ownerTags,
      ['sheet:/x#2'],
    );
  });
}
