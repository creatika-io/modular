import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

/// A registrar written against `ModularContext` alone, as before outlets.
class LegacyContext implements ModularContext {
  @override
  void route(
    String path, {
    required ModularWidgetBuilder child,
    void Function(Scoped scoped)? provide,
    void Function(ModularContext c)? children,
    List<ModularGuard>? guards,
    PageTransition? transition,
  }) {}

  @override
  void module(Module module, {String? at}) {}

  @override
  void add<T>(Function constructor) {}

  @override
  void addSingleton<T>(Function constructor) {}

  @override
  void addLazySingleton<T>(Function constructor) {}

  @override
  void addInstance<T>(T instance) {}
}

/// Records every route path, then declares it through [inner].
class RecordingContext implements ModularContext, NamedOutletRegistrar {
  RecordingContext(this.inner, this.paths);

  final ModularContext inner;
  final List<String> paths;

  @override
  ModularContext namedOutlet(String name) =>
      RecordingContext(inner.outlet(name), paths);

  @override
  void route(
    String path, {
    required ModularWidgetBuilder child,
    void Function(Scoped scoped)? provide,
    void Function(ModularContext c)? children,
    List<ModularGuard>? guards,
    PageTransition? transition,
  }) {
    paths.add(path);
    inner.route(
      path,
      child: child,
      provide: provide,
      children: children,
      guards: guards,
      transition: transition,
    );
  }

  @override
  void module(Module module, {String? at}) => inner.module(module, at: at);

  @override
  void add<T>(Function constructor) => inner.add<T>(constructor);

  @override
  void addSingleton<T>(Function constructor) =>
      inner.addSingleton<T>(constructor);

  @override
  void addLazySingleton<T>(Function constructor) =>
      inner.addLazySingleton<T>(constructor);

  @override
  void addInstance<T>(T instance) => inner.addInstance<T>(instance);
}

final cardsModule = createModule(
  path: '/cards',
  register: (c) => c.route('/:id', child: (ctx, s) => const Text('card')),
);

void main() {
  test('a registrar without NamedOutletRegistrar cannot open an outlet', () {
    expect(() => LegacyContext().outlet('sheet'), throwsUnsupportedError);
  });

  test('a decorating registrar forwards its outlet routes', () {
    final paths = <String>[];
    final boot = bootstrapModule(
      createModule(
        register: (c) {
          final recorder = RecordingContext(c, paths)
            ..route('/', child: (ctx, s) => const Text('home'));
          recorder
              .outlet('sheet')
              .route('/note', child: (ctx, s) => const Text('note'));
        },
      ),
    );
    expect(paths, ['/', '/note']);
    expect(boot.routes.match(Uri.parse('/')), isNotNull);
    expect(boot.routes.matchOutlet('sheet', Uri.parse('/note')), isNotNull);
    expect(boot.routes.match(Uri.parse('/note')), isNull);
  });

  test('a module included twice into one outlet mounts once there', () {
    final boot = bootstrapModule(
      createModule(
        register: (c) => c.outlet('sheet')
          ..module(cardsModule)
          ..module(cardsModule, at: '/again'),
      ),
    );
    expect(boot.routes.matchOutlet('sheet', Uri.parse('/cards/1')), isNotNull);
    expect(boot.routes.matchOutlet('sheet', Uri.parse('/again/1')), isNull);
  });
}
