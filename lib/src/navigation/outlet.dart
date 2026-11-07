import 'dart:async';

import 'package:auto_injector/auto_injector.dart';
import 'package:flutter/material.dart';

import '../route/modular_route.dart';
import '../route/route_state.dart';
import '../state/scoped.dart';
import 'modular_router_delegate.dart';
import 'route_resolver.dart';
import 'transition.dart';

/// Builds one level of a matched route chain: the route's page (with its
/// page-scoped `provide`), wrapped in an [_OutletScope] that carries the
/// REMAINING chain — and any [arguments] — to any [RouterOutlet] inside it.
Widget buildRouteLevel({
  required List<RouteLevel> chain,
  required int index,
  required AutoInjector injector,
  required Uri uri,
  required Map<String, String> params,
  required RouteCollection routes,
  Object? arguments,
  PageTransition defaultTransition = TransitionType.material,
  String? outlet,
}) {
  final level = chain[index];
  final merged = {...params, ...level.params};
  final state = RouteState(uri: uri, params: merged, arguments: arguments);

  Widget page = Builder(builder: (ctx) => level.route.builder(ctx, state));
  final provide = level.route.provide;
  if (provide != null) {
    page = ScopedHost(provide: provide, parent: injector, child: page);
  }

  return _OutletScope(
    chain: chain,
    index: index + 1,
    injector: injector,
    uri: uri,
    params: merged,
    arguments: arguments,
    routes: routes,
    defaultTransition: defaultTransition,
    outlet: outlet,
    child: page,
  );
}

class _OutletScope extends InheritedWidget {
  const _OutletScope({
    required this.chain,
    required this.index,
    required this.injector,
    required this.uri,
    required this.params,
    required this.routes,
    required this.defaultTransition,
    required super.child,
    this.arguments,
    this.outlet,
  });

  final List<RouteLevel> chain;
  final int index;
  final AutoInjector injector;
  final Uri uri;
  final Map<String, String> params;
  final Object? arguments;
  final RouteCollection routes;

  /// The app-wide fallback transition, carried down so a nested outlet's pages
  /// inherit it for routes that declare none. See [buildRouteLevel].
  final PageTransition defaultTransition;

  /// The named outlet [chain] was matched in, or `null` for the primary routes.
  final String? outlet;

  static _OutletScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_OutletScope>();

  @override
  bool updateShouldNotify(_OutletScope oldWidget) =>
      index != oldWidget.index || !identical(chain, oldWidget.chain);
}

/// The URI of the route subtree [context] sits in — the base for resolving
/// relative navigation (`context.pushNamed('dashboard')`). Reads WITHOUT
/// subscribing (no rebuild on change); `null` above any route. Inside a
/// [RouterOutlet] this is the outlet's current sub-route, so relatives stay
/// scoped to the shell.
Uri? locationOf(BuildContext context) {
  final element = context
      .getElementForInheritedWidgetOfExactType<_OutletScope>();
  return (element?.widget as _OutletScope?)?.uri;
}

/// Renders the child route(s) of the current level in a REAL nested
/// [Navigator] — with its own push/pop sub-stack. Calling `context.pushNamed`
/// from inside an outlet targets THIS outlet, so the parent shell persists, and
/// its returned `Future` completes with the value passed to `pop(result)`.
/// Scope nests through it: a child's `context.watch` reaches the parent's VMs.
///
/// With a [name] it is a named outlet (Angular's `<router-outlet name>`),
/// showing the routes declared in `c.outlet(name)` beside the primary page.
class RouterOutlet extends StatefulWidget {
  const RouterOutlet({super.key, this.name, this.builder});

  /// The outlet's name, or `null` for the enclosing route's children.
  final String? name;

  /// Presents the stack, bottom to top (empty while closed), instead of a
  /// [Navigator]; a `PopScope` inside an entry cannot veto system back.
  final Widget Function(BuildContext context, List<RouterOutletEntry> entries)?
  builder;

  /// The nearest enclosing outlet, for navigation targeting.
  static RouterOutletState? of(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<_OutletController>();
    return (element?.widget as _OutletController?)?.state;
  }

  @override
  State<RouterOutlet> createState() => RouterOutletState();
}

/// A page of the stack, as [RouterOutlet.builder] receives it.
@immutable
class RouterOutletEntry {
  const RouterOutletEntry({
    required this.key,
    required this.state,
    required this.child,
  });

  /// Stable while the page is in the stack; key its presentation with it.
  final LocalKey key;

  /// The route the page shows: its `uri`, path `params` and `arguments`.
  final RouteState state;

  /// The page's route, built with its page-scoped `provide`.
  final Widget child;
}

/// The stack of a [RouterOutlet]; unlike the `context` verbs, its own run no
/// guards.
class RouterOutletState extends State<RouterOutlet> {
  final List<_OutletEntry> _stack = [];
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late _OutletSource _source;
  ModularRouterDelegate? _delegate;
  int _seq = 0;

  Uri? _seedUri;
  int? _followedNavigation;
  int? _followedOpening;

  /// Whether this outlet has a sub-route above its seed to pop — or, when
  /// named, a last page to close.
  bool get canPop => switch (_stack.length) {
    0 => false,
    1 => widget.name != null,
    _ => true,
  };

  /// Whether [path] resolves WITHIN this outlet's subtree — i.e. its matched
  /// chain shares this outlet's ancestor prefix and has a level at this
  /// outlet's depth. If not (e.g. a sibling top-level route pushed from a
  /// module mounted at `/`), the push must bubble up to the root delegate.
  bool handles(String path) => _source.handles(Uri.parse(path));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final delegate = Router.maybeOf(context)?.routerDelegate;
    _delegate = delegate is ModularRouterDelegate ? delegate : null;
    final name = widget.name;
    if (name == null) {
      _followEnclosingRoute();
    } else {
      _followNamedOutlet(name);
    }
  }

  @override
  void didUpdateWidget(RouterOutlet oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      oldWidget.name == widget.name,
      'A RouterOutlet cannot change its name; give it a new key instead.',
    );
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _followEnclosingRoute() {
    final scope = _OutletScope.of(context)!;
    _source = _OutletSource.children(scope);
    if (_seedUri == scope.uri) return;
    _seedUri = scope.uri;
    _clear();
    _add(_entry(scope.uri, scope.arguments));
  }

  void _followNamedOutlet(String name) {
    final delegate = _delegate;
    if (delegate == null) {
      throw FlutterError(
        'RouterOutlet(name: "$name") must be placed below the Modular router '
        '(e.g. in ModularApp.shellBuilder).',
      );
    }
    assert(
      RouterOutlet.of(context) == null,
      'RouterOutlet(name: "$name") sits inside another outlet\'s page, where '
      'system back cannot reach it. Place it in ModularApp.shellBuilder or '
      'in a page of the root stack.',
    );
    _source = _OutletSource.named(name, delegate);
    final navigation = delegate.outletNavigation(name);
    if (_followedNavigation == navigation.version) return;
    _followedNavigation = navigation.version;
    final top = RouteStateScope.of(context)?.outlets[name];
    if (_followedOpening != navigation.opening) {
      _followedOpening = navigation.opening;
      _openWith(top);
    } else if (navigation.explicit) {
      _showAsBase(top);
    } else {
      _reconcileTop(top);
    }
  }

  void _showAsBase(Uri? base) {
    if (base != null && base == _stack.firstOrNull?.uri) {
      _popDownTo(0);
    } else {
      _openWith(base);
    }
  }

  void _openWith(Uri? base) {
    // A new Navigator shows the new base as its first page: no push transition.
    _navigatorKey = GlobalKey<NavigatorState>();
    _replaceEntriesFrom(0, base == null ? null : _entry(base, null));
  }

  /// Follows a URL change: back to a page below the top pops down to it, and
  /// any other page is pushed (a closed outlet opens with it alone).
  void _reconcileTop(Uri? top) {
    if (top == null) {
      _replaceEntriesFrom(0, null);
      return;
    }
    final index = _stack.lastIndexWhere((entry) => entry.uri == top);
    if (index == -1) {
      _add(_entry(top, null));
    } else {
      _popDownTo(index);
    }
  }

  void _popDownTo(int index) {
    while (_stack.length > index + 1) {
      _detach(_stack.removeLast(), null);
    }
  }

  /// [entry] enters before the replaced entries leave, so a feature module
  /// they share stays bound.
  void _replaceEntriesFrom(int start, _OutletEntry? entry, {Object? result}) {
    final leaving = _stack.sublist(start);
    _stack.removeRange(start, _stack.length);
    if (entry != null) _add(entry);
    for (final old in leaving) {
      _detach(old, result);
    }
  }

  /// Replaces the top entry with [path]. Outside named outlets the old entry
  /// leaves before [path] is even parsed, as upstream.
  _OutletEntry _replaceTop(String path, Object? arguments, {Object? result}) {
    if (widget.name == null) {
      if (_stack.isNotEmpty) _detach(_stack.removeLast(), result);
      final entry = _entryFor(path, arguments);
      _add(entry);
      return entry;
    }
    final entry = _entryFor(path, arguments);
    _replaceEntriesFrom(
      _stack.isEmpty ? 0 : _stack.length - 1,
      entry,
      result: result,
    );
    return entry;
  }

  _OutletEntry _entry(Uri uri, Object? arguments) {
    final location = _source.outlet == null
        ? uri
        : canonicalOutletLocation(uri);
    final id = 'outlet-${identityHashCode(this)}-${_seq++}';
    final tags = _source.match(location)?.last.route.ownerTags ?? const [];
    return _OutletEntry(
      location,
      ValueKey(id),
      id,
      Completer<Object?>(),
      arguments,
      tags,
    );
  }

  _OutletEntry _entryFor(String path, Object? arguments) =>
      _entry(Uri.parse(path), arguments);

  void _add(_OutletEntry entry) {
    _delegate?.manager?.enter(entry.id, entry.ownerTags);
    _stack.add(entry);
  }

  /// Completes [entry]'s future and releases its feature module(s).
  void _detach(_OutletEntry entry, Object? result) {
    if (!entry.completer.isCompleted) entry.completer.complete(result);
    _delegate?.manager?.leave(entry.id, entry.ownerTags);
  }

  void _clear() {
    for (final e in _stack) {
      _detach(e, null);
    }
    _stack.clear();
  }

  /// Pushes [path] onto THIS outlet's sub-stack (the parent shell persists);
  /// the returned future completes with the value passed to `pop(result)`.
  Future<T?> push<T extends Object?>(String path, {Object? arguments}) {
    final entry = _entryFor(path, arguments);
    setState(() => _add(entry));
    _reportLocation();
    return entry.completer.future.then((value) => value as T?);
  }

  /// Pops this outlet's top sub-route, completing its `push` future.
  void pop<T extends Object?>([T? result]) {
    if (!canPop) return;
    _remove(_stack.last.key, result);
  }

  /// Pops this outlet's top sub-route if possible; returns whether it did.
  bool maybePop<T extends Object?>([T? result]) {
    if (!canPop) return false;
    _remove(_stack.last.key, result);
    return true;
  }

  /// Replaces this outlet's WHOLE sub-stack with [path] — the shell "navigate"
  /// (a bottom-bar tab switch swaps the body without stacking history).
  void navigate(String path, {Object? arguments}) {
    final entry = _entryFor(path, arguments);
    setState(() => _replaceEntriesFrom(0, entry));
    _reportLocation();
  }

  /// Replaces this outlet's TOP sub-route with [path].
  Future<T?> replace<T extends Object?>(String path, {Object? arguments}) {
    final entry = _replaceTop(path, arguments);
    setState(() {});
    _reportLocation();
    return entry.completer.future.then((value) => value as T?);
  }

  /// Pops this outlet's sub-stack until [predicate] holds (or one remains).
  void popUntil(bool Function(RouteState state) predicate) {
    var changed = false;
    while (_stack.length > 1 &&
        !predicate(
          RouteState(uri: _stack.last.uri, arguments: _stack.last.arguments),
        )) {
      _detach(_stack.removeLast(), null);
      changed = true;
    }
    if (changed && mounted) setState(() {});
    _reportLocation();
  }

  /// Pops this outlet's top sub-route delivering [result], then pushes [path].
  Future<T?> popAndPushNamed<T extends Object?>(
    String path, {
    Object? result,
    Object? arguments,
  }) {
    final entry = _replaceTop(path, arguments, result: result);
    setState(() {});
    _reportLocation();
    return entry.completer.future.then((value) => value as T?);
  }

  /// Pushes [path] onto this outlet, then removes the sub-routes BENEATH it
  /// until [predicate] holds (or only the new one remains).
  Future<T?> pushNamedAndRemoveUntil<T extends Object?>(
    String path,
    bool Function(RouteState state) predicate, {
    Object? arguments,
  }) {
    final entry = _entryFor(path, arguments);
    _add(entry);
    while (_stack.length > 1 &&
        !predicate(
          RouteState(
            uri: _stack[_stack.length - 2].uri,
            arguments: _stack[_stack.length - 2].arguments,
          ),
        )) {
      _detach(_stack.removeAt(_stack.length - 2), null);
    }
    setState(() {});
    _reportLocation();
    return entry.completer.future.then((value) => value as T?);
  }

  /// Reports this outlet's current base sub-route to the root delegate so the
  /// URL reflects the outlet (a tab switch shows up). A push/pop leaves the
  /// base unchanged, so it reports the same value and stays out of the URL.
  /// A named outlet reports its top instead: each of its pages is in history.
  void _reportLocation() {
    if (!mounted) return;
    final name = widget.name;
    final namedOutlet = _source.outlet;
    if (name != null) {
      // A stack awaiting a reset (a late back) must not undo that navigation.
      if (_awaitsReset) return;
      _delegate?.reportOutletLocation(name, _stack.lastOrNull?.uri);
    } else if (namedOutlet != null) {
      _delegate?.reportOutletActivity(namedOutlet);
    } else if (_stack.isNotEmpty) {
      _delegate?.reportNestedLocation(_stack.first.uri);
    }
  }

  void _remove(Key? key, Object? result) {
    final index = _stack.indexWhere((e) => e.key == key);
    if (index == -1) return;
    _detach(_stack.removeAt(index), result);
    if (mounted) setState(() {});
    _reportLocation();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    if (name != null) {
      // Blocks its route's pop while open, so system back reaches it.
      return PopScope<Object?>(
        canPop: !canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _delegate?.offerBack(name, () => unawaited(_popOnSystemBack()));
        },
        child: _buildStack(),
      );
    }
    if (!_source.hasLevelBelow) return const SizedBox.shrink();
    if (!_forwardsSystemBack) return _buildStack();
    return NavigatorPopHandler<Object?>(
      onPopWithResult: (result) =>
          unawaited(_navigatorKey.currentState?.maybePop(result)),
      child: _buildStack(),
    );
  }

  bool get _forwardsSystemBack =>
      _source.outlet != null &&
      RouterOutlet.of(context)?.widget.builder == null;

  Future<void> _popOnSystemBack() async {
    final pageBackArrivedOn = _stack.lastOrNull;
    if (pageBackArrivedOn == null) return;
    final poppedInside = await _navigatorKey.currentState?.maybePop() ?? false;
    if (!poppedInside && mounted) _remove(pageBackArrivedOn.key, null);
  }

  bool get _awaitsReset =>
      _delegate?.outletNavigation(widget.name!).version != _followedNavigation;

  Widget _buildStack() {
    final builder = widget.builder;
    final Widget presentation;
    if (builder != null) {
      presentation = Builder(
        builder: (context) => builder(context, [
          for (final entry in _stack) _presentedEntry(entry),
        ]),
      );
    } else if (_stack.isEmpty) {
      return const SizedBox.shrink();
    } else {
      presentation = Navigator(
        key: _navigatorKey,
        // ignore: deprecated_member_use
        onPopPage: (route, result) {
          if (!route.didPop(result)) return false;
          final settings = route.settings;
          if (settings is Page) _remove(settings.key, result);
          return true;
        },
        pages: [for (final entry in _stack) _page(entry)],
      );
    }
    return _OutletController(state: this, child: presentation);
  }

  Page<void> _page(_OutletEntry entry) {
    final chain = _chainAtThisLevel(entry.uri);
    if (chain == null) {
      return MaterialPage<void>(key: entry.key, child: const SizedBox.shrink());
    }
    final transition =
        chain[_source.depth].route.transition ?? _source.defaultTransition;
    return transition.buildPage(entry.key, _buildRoute(chain, entry));
  }

  RouterOutletEntry _presentedEntry(_OutletEntry entry) {
    final chain = _chainAtThisLevel(entry.uri);
    return RouterOutletEntry(
      key: entry.key,
      state: RouteState(
        uri: entry.uri,
        params: {..._source.params, ...?chain?[_source.depth].params},
        arguments: entry.arguments,
      ),
      child: chain == null
          ? const SizedBox.shrink()
          : _buildRoute(chain, entry),
    );
  }

  List<RouteLevel>? _chainAtThisLevel(Uri uri) {
    final chain = _source.match(uri);
    return chain != null && chain.length > _source.depth ? chain : null;
  }

  Widget _buildRoute(List<RouteLevel> chain, _OutletEntry entry) {
    return buildRouteLevel(
      chain: chain,
      index: _source.depth,
      injector: _source.injector,
      uri: entry.uri,
      params: _source.params,
      arguments: entry.arguments,
      routes: _source.routes,
      defaultTransition: _source.defaultTransition,
      outlet: _source.outlet,
    );
  }
}

/// What an outlet renders: an enclosing route's children or a named outlet.
class _OutletSource {
  _OutletSource.children(_OutletScope scope)
    : routes = scope.routes,
      outlet = scope.outlet,
      ancestors = scope.chain.sublist(0, scope.index),
      hasLevelBelow = scope.index < scope.chain.length,
      params = scope.params,
      injector = scope.injector,
      defaultTransition = scope.defaultTransition;

  _OutletSource.named(String this.outlet, ModularRouterDelegate delegate)
    : routes = delegate.routes,
      ancestors = const [],
      hasLevelBelow = true,
      params = const {},
      injector = delegate.injector,
      defaultTransition = delegate.defaultTransition;

  final RouteCollection routes;
  final String? outlet;
  final List<RouteLevel> ancestors;
  final bool hasLevelBelow;
  final Map<String, String> params;
  final AutoInjector injector;
  final PageTransition defaultTransition;

  int get depth => ancestors.length;

  List<RouteLevel>? match(Uri uri) {
    final outlet = this.outlet;
    return outlet == null ? routes.match(uri) : routes.matchOutlet(outlet, uri);
  }

  bool handles(Uri uri) {
    final chain = match(uri);
    if (chain == null || chain.length <= depth) return false;
    for (var i = 0; i < depth; i++) {
      if (!identical(chain[i].route, ancestors[i].route)) return false;
    }
    return true;
  }
}

class _OutletEntry {
  _OutletEntry(
    this.uri,
    this.key,
    this.id,
    this.completer,
    this.arguments,
    this.ownerTags,
  );
  final Uri uri;
  final LocalKey key;
  final String id;
  final List<String> ownerTags;
  final Completer<Object?> completer;
  final Object? arguments;
}

/// Exposes the nearest [RouterOutletState] to the navigation extension.
class _OutletController extends InheritedWidget {
  const _OutletController({required this.state, required super.child});

  final RouterOutletState state;

  @override
  bool updateShouldNotify(_OutletController oldWidget) =>
      state != oldWidget.state;
}
