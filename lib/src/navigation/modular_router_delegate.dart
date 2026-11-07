import 'dart:async';

import 'package:auto_injector/auto_injector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../module/module.dart';
import '../route/modular_route.dart';
import '../route/route_state.dart';
import 'modular_route_information_parser.dart';
import 'outlet.dart';
import 'route_resolver.dart';
import 'transition.dart';

/// Drives the Navigator 2.0 page STACK. Each page renders a matched route
/// CHAIN (parent shells + nested children via `RouterOutlet`), applies route
/// [ModularRoute.guards] (redirects), and uses each route's transition.
///
/// `pushNamed` returns a `Future` that completes with the value passed to the
/// matching `pop(result)`. It also reports each entry to the [ModuleManager],
/// which binds a feature module on its first active route and disposes it when
/// its last route leaves. It also keeps the top of each open named outlet.
class ModularRouterDelegate extends RouterDelegate<RouteState>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<RouteState> {
  ModularRouterDelegate(
    this.routes,
    this.injector, {
    this.manager,
    GlobalKey<NavigatorState>? navigatorKey,
    this.observers = const [],
    this.defaultTransition = TransitionType.material,
    ShellBuilder? shellBuilder,
  }) : navigatorKey = navigatorKey ?? GlobalKey<NavigatorState>(),
       _shellBuilder = shellBuilder;

  final RouteCollection routes;
  final AutoInjector injector;
  final ModuleManager? manager;

  /// The app-wide fallback transition, applied to any route that declares none
  /// (`ModularRoute.transition == null`). Set via `ModularApp.transition`.
  final PageTransition defaultTransition;

  /// Observers attached to the root [Navigator] (analytics, a `RouteObserver`
  /// for route-aware widgets, etc.).
  final List<NavigatorObserver> observers;

  /// See `ModularApp.shellBuilder`.
  ShellBuilder? get shellBuilder => _shellBuilder;
  ShellBuilder? _shellBuilder;
  set shellBuilder(ShellBuilder? shellBuilder) {
    if (identical(shellBuilder, _shellBuilder)) return;
    _shellBuilder = shellBuilder;
    notifyListeners();
  }

  /// The root [Navigator]'s key — caller-supplied (for imperative access from
  /// outside the tree) or a fresh one. `PopNavigatorRouterDelegateMixin` uses
  /// it to route system back through this delegate.
  @override
  final GlobalKey<NavigatorState> navigatorKey;

  final List<_StackEntry> _stack = [];
  int _seq = 0;

  /// The active nested [RouterOutlet]'s current sub-route (its tab base),
  /// reported on a tab switch. When set, the URL shows THIS instead of just the
  /// root base — so an outlet is reflected in the URL. Reset when the root base
  /// is replaced. See [reportNestedLocation].
  Uri? _nestedLocation;

  /// Each open outlet's top page, in opening order, which is the URL's.
  final Map<String, Uri> _outletTops = {};
  final List<String> _outletsByLastChange = [];
  final Map<String, OutletNavigation> _outletNavigations = {};
  final Map<String, VoidCallback> _backOffers = {};

  /// The latest navigation into [outlet] from outside it; its version moves
  /// each time. An explicit one (`navigateOutlets`) shows that page as the
  /// base; a URL change is reconciled with the outlet's stack. Its opening
  /// moves each time the outlet opens, which starts a new stack.
  OutletNavigation outletNavigation(String outlet) =>
      _outletNavigations[outlet] ?? (version: 0, opening: 0, explicit: false);

  /// Collects the offers of the outlets on the route being popped; the most
  /// recently changed one handles system back.
  void offerBack(String outlet, VoidCallback handleBack) {
    if (_backOffers.isEmpty) scheduleMicrotask(_handBackToMostRecentOffer);
    _backOffers[outlet] = handleBack;
  }

  void _handBackToMostRecentOffer() {
    final mostRecent = _backOffers.keys.reduce(
      (a, b) =>
          _outletsByLastChange.indexOf(b) > _outletsByLastChange.indexOf(a)
          ? b
          : a,
    );
    final handleBack = _backOffers[mostRecent]!;
    _backOffers.clear();
    handleBack();
  }

  /// Whether there is a route above the root to pop.
  bool get canPop => _stack.length > 1;

  /// The browser URL mirrors the stack's BASE (`_stack.first`), NOT its top:
  /// `navigate` (which resets the base) owns the URL, while `pushNamed` layers
  /// pages that stay OUT of the URL — modal-like, lost on refresh by design.
  /// A nested [RouterOutlet] refines it with its current sub-route, so a tab
  /// switch shows in the URL too (see [reportNestedLocation]).
  @override
  RouteState? get currentConfiguration {
    if (_stack.isEmpty) return null;
    final base = _stack.first.state;
    final config = _nestedLocation == null
        ? base
        : base.copyWith(uri: _nestedLocation);
    if (_outletTops.isEmpty) return config;
    return _withOutlets(config, Map.unmodifiable(_outletTops));
  }

  /// The effective current route as a FULL [RouteState] — what reactive
  /// consumers read via `context.routeState()`.
  ///
  /// Same `uri` as [currentConfiguration] (the stack base, refined by the
  /// active outlet), but with path `params` RESOLVED: the stored stack entry
  /// only carries the raw uri + arguments — params are merged at render time —
  /// so this re-matches the URI against the route tree and merges every level's
  /// params. `arguments` is the URL-base route's: nested-outlet sub-routes and
  /// pushed (modal-like) pages stay OUT of the URL by design, so their args are
  /// reached through their own builder's `(ctx, state)`, not here.
  RouteState? currentRouteState() {
    final config = currentConfiguration;
    if (config == null) return null;
    final chain = routes.match(config.uri);
    if (chain == null) return config;
    final params = <String, String>{};
    for (final level in chain) {
      params.addAll(level.params);
    }
    return config.copyWith(params: params);
  }

  /// Called by a [RouterOutlet] when its base sub-route changes (a tab switch),
  /// so the URL reflects the outlet — not just the root stack's base. A push
  /// INSIDE the outlet leaves the tab base unchanged, so it reports the same
  /// value and stays out of the URL, consistent with root pushes.
  void reportNestedLocation(Uri uri) {
    if (_nestedLocation == uri) return;
    _nestedLocation = uri;
    notifyListeners();
  }

  /// Called by a named [RouterOutlet] when its top page changes from inside;
  /// `null` when its last page closed it. Each change is a history entry.
  void reportOutletLocation(String outlet, Uri? top) {
    reportOutletActivity(outlet);
    final outlets = Map.of(_outletTops);
    if (top == null) {
      outlets.remove(outlet);
    } else {
      outlets[outlet] = top;
    }
    _setOutlets(outlets);
  }

  /// Called by an outlet whose stack changed among the named [outlet]'s routes.
  void reportOutletActivity(String outlet) {
    if (_outletsByLastChange.remove(outlet)) _outletsByLastChange.add(outlet);
  }

  @override
  Future<void> setNewRoutePath(RouteState configuration) async {
    // Already here: compare the EFFECTIVE location (including a nested outlet),
    // so the platform echoing back an outlet-driven URL doesn't rebuild and
    // remount the shell. Empty stack → null → falls through to build the first.
    if (currentConfiguration?.uri == configuration.uri) {
      if (!mapEquals(configuration.outlets, _outletTops)) {
        // Primary guards see the outlets, so they decide again.
        final destination = applyGuards(configuration);
        if (destination.location != configuration.location) {
          return _resetTo(destination);
        }
        // The URL holds no pages pushed above the base.
        while (_stack.length > 1) {
          _detach(_stack.removeLast(), null);
        }
        _installOutlets(configuration.outlets);
        notifyListeners();
      }
      return;
    }
    _resetTo(configuration);
  }

  /// Pushes [path] onto the stack; completes when its `pop(result)` is called.
  /// Always stacks (push is unbounded) — even a guard redirect just pushes the
  /// resolved route. Deduping/replacing is `navigate`'s and `replace`'s job.
  Future<T?> pushNamed<T extends Object?>(String path, {Object? arguments}) {
    final entry = _guardedEntry(path, arguments);
    _push(entry);
    notifyListeners();
    return entry.completer.future.then((value) => value as T?);
  }

  /// Pops the top route, completing its `pushNamed` future with [result].
  /// DECLARATIVE: removes the entry from the page list — the Navigator animates
  /// the exit. (The AppBar arrow / system back reach the same `_remove` through
  /// `onDidRemovePage`.)
  void pop<T extends Object?>([T? result]) {
    if (!canPop) return;
    _remove(_stack.last.key, result);
  }

  /// Pops if possible; returns whether it did.
  bool maybePop<T extends Object?>([T? result]) {
    if (!canPop) return false;
    _remove(_stack.last.key, result);
    return true;
  }

  /// Replaces the WHOLE stack with [path], resetting history — the URL-changing
  /// "navigate" verb (`pushNamed` stacks instead). [path] is a full location:
  /// named outlets it does not list close.
  void navigate(String path, {Object? arguments}) {
    _resetTo(
      readLocation(Uri.parse(path), routes).copyWith(arguments: arguments),
    );
  }

  /// See `context.navigateOutlets`.
  void navigateOutlets(Map<String, String?> outlets) {
    final next = Map.of(_outletTops);
    outlets.forEach((outlet, path) {
      if (path == null) {
        next.remove(outlet);
      } else {
        final location = resolveRoute(path, Uri(path: '/'));
        next[outlet] = applyOutletGuards(outlet, RouteState(uri: location)).uri;
      }
    });
    _setOutlets(next, navigated: outlets.keys.toSet(), explicit: true);
  }

  /// Replaces the TOP route with [path] (no back to the replaced one).
  Future<T?> replace<T extends Object?>(String path, {Object? arguments}) {
    if (_stack.isNotEmpty) _detach(_stack.removeLast(), null);
    final entry = _guardedEntry(path, arguments);
    _push(entry);
    notifyListeners();
    return entry.completer.future.then((value) => value as T?);
  }

  /// Pops until [predicate] holds for the top route (or one route remains).
  void popUntil(bool Function(RouteState state) predicate) {
    var changed = false;
    while (_stack.length > 1 && !predicate(_stack.last.state)) {
      _detach(_stack.removeLast(), null);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Pops the top route delivering [result] to its `pushNamed` future, then
  /// pushes [path].
  Future<T?> popAndPushNamed<T extends Object?>(
    String path, {
    Object? result,
    Object? arguments,
  }) {
    if (_stack.isNotEmpty) _detach(_stack.removeLast(), result);
    final entry = _guardedEntry(path, arguments);
    _push(entry);
    notifyListeners();
    return entry.completer.future.then((value) => value as T?);
  }

  /// Pushes [path], then removes the routes BENEATH it until [predicate] holds
  /// (or only the new route remains).
  Future<T?> pushNamedAndRemoveUntil<T extends Object?>(
    String path,
    bool Function(RouteState state) predicate, {
    Object? arguments,
  }) {
    final entry = _guardedEntry(path, arguments);
    _push(entry);
    while (_stack.length > 1 && !predicate(_stack[_stack.length - 2].state)) {
      _detach(_stack.removeAt(_stack.length - 2), null);
    }
    notifyListeners();
    return entry.completer.future.then((value) => value as T?);
  }

  void _resetTo(RouteState target) {
    _nestedLocation = null; // base is being replaced → drop stale outlet loc
    for (final entry in _stack) {
      _detach(entry, null);
    }
    _stack.clear();
    final destination = applyGuards(target);
    _push(_entry(destination));
    _installOutlets(destination.outlets);
    notifyListeners();
  }

  /// A guard redirect is a full location even for a push: its outlets replace
  /// the open ones.
  _StackEntry _guardedEntry(String path, Object? arguments) {
    final destination = applyGuards(_requested(path, arguments));
    _installOutlets(destination.outlets);
    return _entry(destination);
  }

  void _installOutlets(Map<String, Uri> outlets) {
    if (mapEquals(outlets, _outletTops)) return;
    final guarded = _guardOutlets(outlets);
    _updateOutlets(guarded, navigated: _changedOutletNames(guarded));
  }

  void _setOutlets(
    Map<String, Uri> outlets, {
    Set<String> navigated = const {},
    bool explicit = false,
  }) {
    final changed = _updateOutlets(
      outlets,
      navigated: navigated,
      explicit: explicit,
    );
    if (changed) notifyListeners();
  }

  /// Outlets in [navigated] were navigated to from outside (see
  /// [outletNavigation]). Returns whether anything changed.
  bool _updateOutlets(
    Map<String, Uri> outlets, {
    required Set<String> navigated,
    bool explicit = false,
  }) {
    if (navigated.isEmpty && mapEquals(outlets, _outletTops)) return false;
    final opened = {
      for (final outlet in outlets.keys)
        if (!_outletTops.containsKey(outlet)) outlet,
    };
    for (final outlet in navigated) {
      final previous = outletNavigation(outlet);
      _outletNavigations[outlet] = (
        version: previous.version + 1,
        opening: previous.opening + (opened.contains(outlet) ? 1 : 0),
        explicit: explicit,
      );
    }
    _outletsByLastChange
      ..removeWhere((outlet) => !outlets.containsKey(outlet))
      ..removeWhere(navigated.contains)
      ..addAll([
        for (final outlet in {...navigated, ...opened})
          if (outlets.containsKey(outlet)) outlet,
      ]);
    _outletTops
      ..clear()
      ..addAll(outlets);
    return true;
  }

  Set<String> _changedOutletNames(Map<String, Uri> outlets) => {
    for (final outlet in {...outlets.keys, ..._outletTops.keys})
      if (outlets[outlet] != _outletTops[outlet]) outlet,
  };

  /// A location's outlet whose guards keep redirecting stays closed.
  Map<String, Uri> _guardOutlets(Map<String, Uri> outlets) => {
    for (final MapEntry(key: outlet, value: location) in outlets.entries)
      if (_settleOutletGuards(outlet, RouteState(uri: location))
          case final destination?)
        outlet: destination.uri,
  };

  void _push(_StackEntry entry) {
    _stack.add(entry);
    manager?.enter(entry.id, entry.ownerTags);
  }

  void _remove(Key? key, Object? result) {
    final index = _stack.indexWhere((e) => e.key == key);
    if (index == -1) return;
    _detach(_stack.removeAt(index), result);
    notifyListeners();
  }

  void _detach(_StackEntry entry, Object? result) {
    manager?.leave(entry.id, entry.ownerTags);
    if (!entry.completer.isCompleted) entry.completer.complete(result);
  }

  /// Runs guards along the matched chain; follows redirects (bounded loop).
  RouteState applyGuards(RouteState state) {
    var current = state;
    for (var hop = 0; hop < 8; hop++) {
      final chain = routes.match(current.uri);
      if (chain == null) return current;
      final redirect = _redirectOf(chain, current);
      if (redirect == null) return current;
      current = readLocation(Uri.parse(redirect), routes);
    }
    return current;
  }

  /// [applyGuards] in the named [outlet]; throws if its guards keep
  /// redirecting.
  RouteState applyOutletGuards(String outlet, RouteState state) =>
      _settleOutletGuards(outlet, state) ??
      (throw FlutterError(
        'The guards of "${state.uri}" in outlet "$outlet" keep redirecting.',
      ));

  /// Redirects stay in [outlet], matched on canonical paths so no encoding
  /// slips past a guard, and guards see the path params. `null` when the
  /// redirects never settle, so the guarded page is never admitted.
  RouteState? _settleOutletGuards(String outlet, RouteState state) {
    var current = state.copyWith(uri: canonicalOutletLocation(state.uri));
    for (var hop = 0; hop < 8; hop++) {
      final chain = routes.matchOutlet(outlet, current.uri);
      if (chain == null) return current;
      final params = {for (final level in chain) ...level.params};
      final redirect = _redirectOf(chain, current.copyWith(params: params));
      if (redirect == null) return current;
      current = RouteState(uri: canonicalOutletLocation(Uri.parse(redirect)));
    }
    return null;
  }

  String? _redirectOf(List<RouteLevel> chain, RouteState state) {
    for (final level in chain) {
      for (final guard in level.route.guards) {
        final redirect = guard(state);
        if (redirect != null) return redirect;
      }
    }
    return null;
  }

  _StackEntry _entry(RouteState state) {
    final id = 'route-${_seq++}';
    final tags = routes.match(state.uri)?.last.route.ownerTags ?? const [];
    return _StackEntry(
      state.outlets.isEmpty ? state : _withOutlets(state, const {}),
      ValueKey(id),
      id,
      Completer<Object?>(),
      tags,
    );
  }

  RouteState _requested(String path, Object? arguments) => RouteState(
    uri: Uri.parse(path),
    arguments: arguments,
    outlets: Map.unmodifiable(_outletTops),
  );

  @override
  Widget build(BuildContext context) {
    if (_stack.isEmpty) return const SizedBox.shrink();

    // Wrap the root Navigator so any descendant — INCLUDING chrome that sits
    // beside an outlet (a shell's bottom bar) — can read the current route via
    // `context.routeState()` and rebuild when the app navigates. The delegate
    // IS the notifier: it already `notifyListeners()`es on every nav change.
    return RouteStateScope(
      delegate: this,
      child: Navigator(
        key: navigatorKey,
        observers: observers,
        // `onPopPage` (v6-style, SYNCHRONOUS) instead of `onDidRemovePage`: it
        // fires at the pop REQUEST, so the page list updates immediately rather
        // than via the deferred did-remove callback — the suspect for the
        // fast-multi-pop flicker. Imperative routes (dialogs/sheets) are left to
        // the Navigator: only our Page-backed routes touch `_stack`.
        // ignore: deprecated_member_use
        onPopPage: (route, result) {
          if (!route.didPop(result)) return false;
          final settings = route.settings;
          if (settings is Page) _remove(settings.key, result);
          return true;
        },
        pages: [for (final entry in _stack) _buildPage(entry)],
      ),
    );
  }

  Page<void> _buildPage(_StackEntry entry) {
    final chain = routes.match(entry.state.uri);
    if (chain == null || chain.isEmpty) {
      return MaterialPage<void>(
        key: entry.key,
        child: _withShell(entry, const _RouteNotFound()),
      );
    }

    final child = buildRouteLevel(
      chain: chain,
      index: 0,
      injector: injector,
      uri: entry.state.uri,
      params: const {},
      arguments: entry.state.arguments,
      routes: routes,
      defaultTransition: defaultTransition,
    );
    final transition = chain.first.route.transition ?? defaultTransition;
    return transition.buildPage(entry.key, _withShell(entry, child));
  }

  Widget _withShell(_StackEntry entry, Widget content) {
    final shellBuilder = this.shellBuilder;
    if (shellBuilder == null || !identical(entry, _stack.first)) return content;
    return Builder(builder: (context) => shellBuilder(context, content));
  }
}

class _StackEntry {
  _StackEntry(this.state, this.key, this.id, this.completer, this.ownerTags);
  final RouteState state;
  final LocalKey key;
  final String id;
  final Completer<Object?> completer;
  final List<String> ownerTags;
}

class _RouteNotFound extends StatelessWidget {
  const _RouteNotFound();

  @override
  Widget build(BuildContext context) {
    return const Material(child: Center(child: Text('Route not found')));
  }
}

/// Exposes the [ModularRouterDelegate] (a [ChangeNotifier]) to the subtree so a
/// widget can read the current [RouteState] reactively via
/// `context.routeState()` — rebuilding when the app navigates. Installed once
/// around the root Navigator in [ModularRouterDelegate.build]; not exported
/// (the public surface is the `context.routeState()` extension).
class RouteStateScope extends InheritedNotifier<ModularRouterDelegate> {
  const RouteStateScope({
    required ModularRouterDelegate delegate,
    required super.child,
    super.key,
  }) : super(notifier: delegate);

  /// The effective current [RouteState], or `null` above any
  /// [ModularRouterDelegate]. Subscribes (rebuilds on navigation) unless
  /// [listen] is false.
  static RouteState? of(BuildContext context, {bool listen = true}) {
    final RouteStateScope? scope;
    if (listen) {
      scope = context.dependOnInheritedWidgetOfExactType<RouteStateScope>();
    } else {
      final element = context
          .getElementForInheritedWidgetOfExactType<RouteStateScope>();
      scope = element?.widget as RouteStateScope?;
    }
    return scope?.notifier?.currentRouteState();
  }
}

/// See `ModularApp.shellBuilder`.
typedef ShellBuilder = Widget Function(BuildContext context, Widget child);

/// See [ModularRouterDelegate.outletNavigation].
typedef OutletNavigation = ({int version, int opening, bool explicit});

RouteState _withOutlets(RouteState state, Map<String, Uri> outlets) =>
    RouteState(
      uri: state.uri,
      params: state.params,
      arguments: state.arguments,
      outlets: outlets,
    );
