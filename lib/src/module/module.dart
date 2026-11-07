import 'package:auto_injector/auto_injector.dart';
import 'package:flutter/foundation.dart';

import '../navigation/transition.dart';
import '../route/modular_route.dart';
import '../state/scoped.dart';

/// A module SPEC: declares DI + Routes via [register]. Build it functionally
/// with [createModule] (a `final` value, deduped by identity) or by extending.
abstract class Module {
  /// Where this module mounts. A module WITH a path is a FEATURE: including it
  /// flattens its routes under the path and feature-scopes its binds — disposed
  /// when its last route leaves (the full mounted path is its lifecycle tag). A
  /// module WITHOUT a path is a shared DI dependency: root-owned, never
  /// disposed. Override at the include site with `module(m, at: ...)`.
  String? get path => null;

  void register(ModularContext c);
}

/// Creates a functional module. Store it in a `final` and reference the SAME
/// value everywhere — composition dedups by IDENTITY.
///
/// Give a [path] to make it a FEATURE (mounted there, with bind lifecycle);
/// omit it for a shared DI module (root-owned).
Module createModule({
  String? path,
  required void Function(ModularContext c) register,
}) {
  assert(_isValidMountPath(path), _mountPathError(path));
  return _FunctionalModule(path, register);
}

/// A module mount path is a STATIC prefix: it must start with `/` and carry no
/// dynamic segment (`:param`). Dynamic params belong to the routes INSIDE a
/// module, not to where the module mounts (which is also its lifecycle tag).
bool _isValidMountPath(String? path) =>
    path == null || (path.startsWith('/') && !path.contains(':'));

String _mountPathError(String? path) =>
    'Invalid module path "$path": it must start with "/" and contain no '
    'dynamic segment (":"). Put `:params` on the routes inside the module.';

/// Outlet names are URL group keys (`/home(sheet:card)`).
bool _isValidOutletName(String? outlet) =>
    outlet == null || RegExp(r'^[\w-]+$').hasMatch(outlet);

class _FunctionalModule extends Module {
  _FunctionalModule(this.path, this._register);

  @override
  final String? path;
  final void Function(ModularContext) _register;

  @override
  void register(ModularContext c) => _register(c);
}

/// The single surface a module declares itself through: DI registration
/// (`add*`), routes (`route`, with `guards`/`transition`/nested `children`),
/// and the unified [module] include verb.
abstract class ModularContext {
  void route(
    String path, {
    required ModularWidgetBuilder child,
    void Function(Scoped scoped)? provide,
    void Function(ModularContext c)? children,
    List<ModularGuard>? guards,
    PageTransition? transition,
  });

  /// Include another module. The mount path is [at] ?? `module.path`:
  ///  - none → a shared DI dependency (binds root-owned, never disposed);
  ///  - a path → a NAMESPACE feature: routes flattened under it, binds
  ///    feature-scoped (disposed when the module's LAST route leaves).
  /// [at] is the rare override of a module's own [Module.path]. Dedup by
  /// identity.
  void module(Module module, {String? at});

  void add<T>(Function constructor);
  void addSingleton<T>(Function constructor);
  void addLazySingleton<T>(Function constructor);
  void addInstance<T>(T instance);
}

/// Implemented by a [ModularContext] that can declare routes in named outlets,
/// which `c.outlet(name)` needs. A custom registrar (a decorator, a test
/// double) implements it to support named outlets.
abstract interface class NamedOutletRegistrar {
  /// A registrar whose routes and module includes go into the named outlet
  /// [name]; its binds are the parent's.
  ModularContext namedOutlet(String name);
}

/// Named outlets on any registrar that supports them.
extension NamedOutletX on ModularContext {
  /// Declares routes in the named outlet [name], shown by
  /// `RouterOutlet(name: name)` beside the primary page:
  /// `c.outlet('sheet')..route('/card', ...)..module(productsModule)`.
  ModularContext outlet(String name) {
    if (this case final NamedOutletRegistrar registrar) {
      return registrar.namedOutlet(name);
    }
    throw UnsupportedError(
      '$runtimeType does not implement NamedOutletRegistrar, which '
      'c.outlet("$name") needs.',
    );
  }
}

/// The active resolution injector, set by [bootstrapModule]. Backs [inject].
AutoInjector? _activeInjector;

/// Resolves [T] from the active module graph — Angular-style service access
/// that keeps the injector object PRIVATE. Works anywhere a constructor can't
/// inject for you (route guards, callbacks, widgets) after a Modular app has
/// bootstrapped. It reads the LIVE graph, so a feature module's binds are
/// reachable only while that module is active.
///
/// ```dart
/// guards: [(state) => inject<AppSession>().unlocked ? null : '/login'],
/// ```
T inject<T>() {
  final injector = _activeInjector;
  if (injector == null) {
    throw StateError('inject<$T>(): no Modular app has been bootstrapped yet.');
  }
  return injector.get<T>();
}

/// Result of bootstrapping a root module: the route tree, the resolution
/// [injector], and the [manager] that drives per-module bind lifecycle.
class ModularBootstrap {
  ModularBootstrap(this.routes, this.manager);

  final RouteCollection routes;
  final ModuleManager manager;

  /// The resolution entry point (sees every module's binds via the graph).
  AutoInjector get injector => manager.root;
}

/// Walks a root [Module], collecting its routes (tagged with their owning
/// feature modules) and binds. Root-owned binds (path-less modules) are
/// committed eagerly; feature binds (a module with a `path`) are bound lazily
/// on entry and disposed on exit.
ModularBootstrap bootstrapModule(Module root) {
  final manager = ModuleManager();
  final topLevel = <ModularRoute>[];
  final ctx = _ContextImpl(
    routes: topLevel,
    manager: manager,
    mounts: _Mounts(root),
    ownerTags: const [],
    collect: null, // root-owned: binds applied to root
  );
  root.register(ctx);
  manager.commitRoot();
  _activeInjector = manager.root; // backs `inject<T>()`

  final collection = RouteCollection();
  for (final route in topLevel) {
    collection.add(route);
  }
  return ModularBootstrap(collection, manager);
}

/// Owns the resolution [root] injector and drives per-FEATURE-module bind
/// lifecycle: a feature module's binds are bound (its tagged injector created
/// and composed in) when its first route enters the stack, and disposed (via
/// `disposeInjectorByTag`) when its last route leaves — mirroring how the
/// "active path list" worked in flutter_modular 6.x.
class ModuleManager {
  ModuleManager() : root = AutoInjector(tag: 'modular-root');

  /// The resolution entry point. Every module (root-owned or feature) composes
  /// into this graph, so `get<T>()` from here sees them all.
  final AutoInjector root;

  final Map<String, List<void Function(AutoInjector)>> _featureBinds = {};
  final Map<String, Set<String>> _active = {};

  void registerFeature(String tag, List<void Function(AutoInjector)> binds) {
    _featureBinds[tag] = binds;
    _active.putIfAbsent(tag, () => <String>{});
  }

  void commitRoot() => root.commit();

  /// A route instance ([id]) owned by [tags] entered the stack.
  void enter(String id, List<String> tags) {
    for (final tag in tags) {
      final active = _active[tag];
      if (active == null) continue; // root-owned, not tracked
      if (active.isEmpty) _bind(tag);
      active.add(id);
    }
  }

  /// A route instance ([id]) owned by [tags] left the stack.
  void leave(String id, List<String> tags) {
    for (final tag in tags) {
      final active = _active[tag];
      if (active == null) continue;
      active.remove(id);
      if (active.isEmpty) _unbind(tag);
    }
  }

  void _bind(String tag) {
    final binds = _featureBinds[tag];
    if (binds == null || binds.isEmpty) return;
    final injector = AutoInjector(tag: tag);
    for (final apply in binds) {
      apply(injector);
    }
    root
      ..uncommit()
      ..addInjector(injector, resolveUpward: true)
      ..commit();
  }

  void _unbind(String tag) => root.disposeInjectorByTag(tag, _disposeInstance);

  void _disposeInstance(dynamic instance) {
    if (instance is ChangeNotifier) {
      instance.dispose();
    } else if (instance is Disposable) {
      instance.dispose();
    }
  }
}

/// The module registrations of one bootstrap.
class _Mounts {
  _Mounts(Module root)
    : registeredRoutes = {root: const []},
      _included = {(root, null)};

  final Set<(Module, String?)> _included;
  final Set<String> _tags = {};

  /// Whether [module] is new to [outlet] (`null`: the primary routes).
  bool include(Module module, String? outlet) =>
      _included.add((module, outlet));

  /// Each module's routes, registered once, owned relative to it; empty while
  /// it registers, so a module including itself mounts nothing.
  final Map<Module, List<ModularRoute>> registeredRoutes;

  /// Two features never share a lifecycle.
  String uniqueTag(String path) {
    var tag = path;
    for (var copy = 2; !_tags.add(tag); copy++) {
      tag = '$path#$copy';
    }
    return tag;
  }
}

class _ContextImpl implements ModularContext, NamedOutletRegistrar {
  _ContextImpl({
    required List<ModularRoute> routes,
    required ModuleManager manager,
    required _Mounts mounts,
    required List<String> ownerTags,
    required List<void Function(AutoInjector)>? collect,
    String prefix = '',
    bool declaresChildren = false,
    String? outlet,
    String? tagOutlet,
  }) : _routes = routes,
       _manager = manager,
       _mounts = mounts,
       _ownerTags = ownerTags,
       _collect = collect,
       _prefix = prefix,
       _declaresChildren = declaresChildren,
       _outlet = outlet,
       _tagOutlet = tagOutlet;

  final List<ModularRoute> _routes;
  final ModuleManager _manager;
  final _Mounts _mounts;
  final List<String> _ownerTags;

  /// The full path prefix at which this context's routes will live — the base
  /// for a mounted feature's lifecycle tag.
  final String _prefix;

  /// When non-null, `add*` calls are COLLECTED here (a feature module, bound
  /// lazily) instead of applied to the root injector (root-owned).
  final List<void Function(AutoInjector)>? _collect;

  final bool _declaresChildren;

  /// The named outlet this registrar declares routes in.
  final String? _outlet;

  /// The named outlet this registration's lifecycle tags are qualified with.
  final String? _tagOutlet;

  @override
  ModularContext namedOutlet(String name) {
    assert(_isValidOutletName(name), 'Invalid outlet name "$name".');
    assert(
      !_declaresChildren,
      'c.outlet("$name") must be called at the top level of the route tree, '
      'not inside `children`.',
    );
    return _ContextImpl(
      routes: _routes,
      manager: _manager,
      mounts: _mounts,
      ownerTags: _ownerTags,
      collect: _collect,
      prefix: _prefix,
      outlet: name,
      tagOutlet: _tagOutlet,
    );
  }

  @override
  void route(
    String path, {
    required ModularWidgetBuilder child,
    void Function(Scoped scoped)? provide,
    void Function(ModularContext c)? children,
    List<ModularGuard>? guards,
    PageTransition? transition,
  }) {
    var nested = const <ModularRoute>[];
    if (children != null) {
      final sub = _sub([]);
      children(sub);
      nested = sub._routes;
    }
    _routes.add(
      ModularRoute(
        path,
        child,
        provide: provide,
        children: nested,
        guards: guards ?? const [],
        transition: transition,
        ownerTags: _ownerTags,
        outlet: _outlet,
      ),
    );
  }

  @override
  void module(Module module, {String? at}) {
    final outlet = _outlet;
    if (!_mounts.include(module, outlet)) return; // dedup by IDENTITY
    final path = at ?? module.path;
    assert(_isValidMountPath(path), _mountPathError(path));
    final routes =
        _mounts.registeredRoutes[module] ?? _registerOnce(module, path);
    for (final route in routes) {
      assert(
        outlet == null || route.outlet == null,
        'The route "${route.path}" declares the outlet "${route.outlet}"; a '
        'module mounted into the outlet "$outlet" declares none.',
      );
      _routes.add(_mounted(route, at: path, outlet: outlet));
    }
  }

  List<ModularRoute> _registerOnce(Module module, String? path) {
    _mounts.registeredRoutes[module] = const [];
    final mountedPath = path == null ? _prefix : _joinPath(_prefix, path);
    final tagOutlet = _outlet ?? _tagOutlet;
    final tag = path == null
        ? null
        : _mounts.uniqueTag(
            tagOutlet == null ? mountedPath : '$tagOutlet:$mountedPath',
          );
    final featureBinds = tag == null ? null : <void Function(AutoInjector)>[];
    final registration = _ContextImpl(
      routes: [],
      manager: _manager,
      mounts: _mounts,
      ownerTags: [?tag],
      collect: featureBinds,
      prefix: mountedPath,
      declaresChildren: _declaresChildren,
      tagOutlet: tagOutlet,
    );
    module.register(registration);
    if (tag != null) _manager.registerFeature(tag, featureBinds!);
    return _mounts.registeredRoutes[module] = registration._routes;
  }

  _ContextImpl _sub(List<ModularRoute> routes) => _ContextImpl(
    routes: routes,
    manager: _manager,
    mounts: _mounts,
    ownerTags: _ownerTags,
    collect: _collect,
    prefix: _prefix,
    declaresChildren: true,
    tagOutlet: _tagOutlet,
  );

  ModularRoute _mounted(ModularRoute route, {String? at, String? outlet}) =>
      ModularRoute(
        at == null ? route.path : _joinPath(at, route.path),
        route.builder,
        provide: route.provide,
        children: route.children.isEmpty
            ? route.children
            : [for (final child in route.children) _mounted(child)],
        guards: route.guards,
        transition: route.transition,
        ownerTags: route.ownerTags.isEmpty
            ? _ownerTags
            : [..._ownerTags, ...route.ownerTags],
        outlet: outlet ?? route.outlet,
      );

  String _joinPath(String at, String path) {
    final segments = [
      ...at.split('/').where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ];
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  @override
  void add<T>(Function constructor) => _register((i) => i.add<T>(constructor));

  @override
  void addSingleton<T>(Function constructor) =>
      _register((i) => i.addSingleton<T>(constructor));

  @override
  void addLazySingleton<T>(Function constructor) =>
      _register((i) => i.addLazySingleton<T>(constructor));

  @override
  void addInstance<T>(T instance) =>
      _register((i) => i.addInstance<T>(instance));

  void _register(void Function(AutoInjector) apply) {
    final collect = _collect;
    if (collect != null) {
      collect.add(apply); // feature: applied lazily at bind time
    } else {
      apply(_manager.root); // root-owned: applied now
    }
  }
}
