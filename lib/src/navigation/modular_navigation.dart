import 'package:flutter/widgets.dart';

import '../route/route_state.dart';
import 'modular_route_information_parser.dart';
import 'modular_router_delegate.dart';
import 'outlet.dart';
import 'route_resolver.dart';

/// Navigation from any widget.
///
/// `pushNamed` targets the nearest enclosing [RouterOutlet] (so the parent
/// shell persists); if there is none, it pushes the root delegate's stack. It
/// returns a `Future` that completes with the value passed to the matching
/// `pop(result)`. Pass an arbitrary object with `arguments:` and read it back
/// from `RouteState.arguments`.
///
/// Paths may be RELATIVE to the route this context sits on: `dashboard` or
/// `./dashboard` from `/home` both target `/home/dashboard`, and `../x` climbs
/// a level. A leading `/` makes it absolute. See [resolveRoute].
///
/// In a named outlet's page the verbs reach the named outlet through its nested
/// outlets, and a pop never goes past it.
extension ModularNavigationX on BuildContext {
  /// Resolves a relative [path] against the route this context is on; absolute
  /// paths (leading `/`) pass through unchanged.
  String _resolve(String path) =>
      resolveRoute(path, locationOf(this) ?? Uri.parse('/')).toString();

  Iterable<RouterOutletState> _enclosingOutlets() sync* {
    for (
      var outlet = RouterOutlet.of(this);
      outlet != null;
      outlet = RouterOutlet.of(outlet.context)
    ) {
      yield outlet;
    }
  }

  /// Beyond the nearest outlet, primary navigation must reach the root guards.
  List<RouterOutletState> _outletsInReach() {
    final outlets = _enclosingOutlets().toList();
    return _insideNamedOutlet ? outlets : outlets.take(1).toList();
  }

  bool get _insideNamedOutlet =>
      _enclosingOutlets().lastOrNull?.widget.name != null;

  /// The outlet [target] lands in and where, or `null` for the root delegate.
  /// A named outlet's guards run here once; their redirects stay in it.
  (RouterOutletState, RouteState)? _outletNavigation(
    String target,
    Object? arguments,
  ) {
    final outlets = _outletsInReach();
    final requested = RouteState(uri: Uri.parse(target), arguments: arguments);
    final namedOutlet = outlets.lastOrNull?.widget.name;
    final delegate = Router.maybeOf(this)?.routerDelegate;
    if (namedOutlet == null || delegate is! ModularRouterDelegate) {
      final nearest = outlets.firstOrNull;
      if (nearest == null || !nearest.handles(target)) return null;
      return (nearest, requested);
    }
    final location = canonicalOutletLocation(requested.uri).toString();
    if (!outlets.any((outlet) => outlet.handles(location))) return null;
    final destination = delegate.applyOutletGuards(namedOutlet, requested);
    final path = destination.uri.toString();
    final outlet = outlets.where((outlet) => outlet.handles(path)).firstOrNull;
    return (outlet ?? outlets.last, destination);
  }

  RouterOutletState? _outletThatCanPop() =>
      _outletsInReach().where((outlet) => outlet.canPop).firstOrNull;

  /// The app's current route as a full [RouteState] — `uri` (the stack base,
  /// refined by the active [RouterOutlet]), resolved path `params`, and the
  /// URL-base route's `arguments`.
  ///
  /// Reactive by default: a widget that reads this rebuilds when the app
  /// navigates, so route-aware chrome (a shell's active-tab highlight,
  /// breadcrumbs) DERIVES from the route instead of mirroring it in local
  /// state. Pass `listen: false` to read without subscribing (e.g. in a
  /// callback). Throws if there is no `ModularApp` / router above this context.
  ///
  /// Note: a widget INSIDE the active route subtree sees the same state as its
  /// `builder`'s `(ctx, state)`; this also reaches chrome OUTSIDE that subtree
  /// (beside an outlet), which the builder arg cannot. `arguments` here is the
  /// URL-base route's — nested-outlet / pushed (modal-like) args stay out of
  /// the URL by design and are read from their own builder's state.
  RouteState routeState({bool listen = true}) {
    final state = RouteStateScope.of(this, listen: listen);
    if (state == null) {
      throw FlutterError(
        'context.routeState: no ModularRouterDelegate found in the tree.',
      );
    }
    return state;
  }

  Future<T?> pushNamed<T extends Object?>(String path, {Object? arguments}) {
    final target = _resolve(path);
    if (_outletNavigation(target, arguments)
        case (final outlet, final destination)?) {
      return outlet.push<T>(
        destination.uri.toString(),
        arguments: destination.arguments,
      );
    }
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) {
      return delegate.pushNamed<T>(target, arguments: arguments);
    }
    throw FlutterError(
      'context.pushNamed: no outlet or ModularRouterDelegate found.',
    );
  }

  /// Whether [pop] would do something — the nearest [RouterOutlet] or the root
  /// delegate has a route to pop. Use it to show a back button on a mounted
  /// module's INDEX page: that page is the sole entry of its outlet's nested
  /// Navigator, so `AppBar(automaticallyImplyLeading:)` can't see the root
  /// stack underneath and shows no arrow on its own.
  bool canPop() {
    if (_outletThatCanPop() != null) return true;
    if (_insideNamedOutlet) return false;
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate && delegate.canPop) return true;
    return Navigator.of(this).canPop();
  }

  /// Pops the current route with an optional [result] delivered to the
  /// `pushNamed` future. Targets the nearest poppable [RouterOutlet], else the
  /// root delegate, else the nearest [Navigator].
  void pop<T extends Object?>([T? result]) {
    final outlet = _outletThatCanPop();
    if (outlet != null) {
      outlet.pop<T>(result);
      return;
    }
    if (_insideNamedOutlet) return;
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate && delegate.canPop) {
      delegate.pop<T>(result);
      return;
    }
    Navigator.of(this).pop<T>(result);
  }

  /// Pops the current route only if possible; returns whether it did.
  bool maybePop<T extends Object?>([T? result]) {
    final outlet = _outletThatCanPop();
    if (outlet != null) return outlet.maybePop<T>(result);
    if (_insideNamedOutlet) return false;
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) return delegate.maybePop<T>(result);
    return false;
  }

  /// REPLACES the target's whole stack with [path] (resets history). Targets
  /// the nearest [RouterOutlet] whose subtree owns [path] — so in a shell it
  /// swaps the body (tab switch) — otherwise the root delegate (reset the app).
  /// This is the v7 unification of 6.x's `navigate` + `pushNavigate`.
  /// A location with outlets (`/home(sheet:card)`) always goes to the root.
  void navigate(String path, {Object? arguments}) {
    final target = _resolve(path);
    final outletNavigation = _opensNamedOutlets(target)
        ? null
        : _outletNavigation(target, arguments);
    if (outletNavigation case (final outlet, final destination)?) {
      outlet.navigate(
        destination.uri.toString(),
        arguments: destination.arguments,
      );
      return;
    }
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) {
      delegate.navigate(target, arguments: arguments);
      return;
    }
    throw FlutterError(
      'context.navigate: no outlet or ModularRouterDelegate found.',
    );
  }

  /// Opens or resets each listed named outlet at its path; `null` closes it.
  /// Other outlets and the primary stack stay. Paths drop query and fragment.
  void navigateOutlets(Map<String, String?> outlets) {
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) {
      delegate.navigateOutlets(outlets);
      return;
    }
    throw FlutterError(
      'context.navigateOutlets: no ModularRouterDelegate found.',
    );
  }

  /// Closes the named outlet [name], or the one this context is in.
  void closeOutlet([String? name]) {
    final outlet = name ?? _enclosingOutlets().lastOrNull?.widget.name;
    if (outlet == null) {
      throw FlutterError(
        'context.closeOutlet: no name given and no named outlet around.',
      );
    }
    navigateOutlets({outlet: null});
  }

  bool _opensNamedOutlets(String target) {
    final delegate = Router.maybeOf(this)?.routerDelegate;
    return delegate is ModularRouterDelegate &&
        readLocation(Uri.parse(target), delegate.routes).outlets.isNotEmpty;
  }

  /// Replaces the TOP route with [path] (no back to the replaced one); the
  /// returned `Future` completes with the new route's pop result.
  Future<T?> replace<T extends Object?>(String path, {Object? arguments}) {
    final target = _resolve(path);
    if (_outletNavigation(target, arguments)
        case (final outlet, final destination)?) {
      return outlet.replace<T>(
        destination.uri.toString(),
        arguments: destination.arguments,
      );
    }
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) {
      return delegate.replace<T>(target, arguments: arguments);
    }
    throw FlutterError(
      'context.replace: no outlet or ModularRouterDelegate found.',
    );
  }

  /// Pops repeatedly until [predicate] holds for the top route. Targets the
  /// nearest poppable [RouterOutlet], else the root delegate.
  void popUntil(bool Function(RouteState state) predicate) {
    final outlet = _outletThatCanPop();
    if (outlet != null) {
      outlet.popUntil(predicate);
      return;
    }
    if (_insideNamedOutlet) return;
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) delegate.popUntil(predicate);
  }

  /// Pops the current route delivering [result] to its `pushNamed` future, then
  /// pushes [path]. Dispatches like [pushNamed].
  Future<T?> popAndPushNamed<T extends Object?>(
    String path, {
    Object? result,
    Object? arguments,
  }) {
    final target = _resolve(path);
    if (_outletNavigation(target, arguments)
        case (final outlet, final destination)?) {
      return outlet.popAndPushNamed<T>(
        destination.uri.toString(),
        result: result,
        arguments: destination.arguments,
      );
    }
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) {
      return delegate.popAndPushNamed<T>(
        target,
        result: result,
        arguments: arguments,
      );
    }
    throw FlutterError(
      'context.popAndPushNamed: no outlet or ModularRouterDelegate found.',
    );
  }

  /// Pushes [path], then removes the routes beneath it until [predicate] holds.
  /// Dispatches like [pushNamed].
  Future<T?> pushNamedAndRemoveUntil<T extends Object?>(
    String path,
    bool Function(RouteState state) predicate, {
    Object? arguments,
  }) {
    final target = _resolve(path);
    if (_outletNavigation(target, arguments)
        case (final outlet, final destination)?) {
      return outlet.pushNamedAndRemoveUntil<T>(
        destination.uri.toString(),
        predicate,
        arguments: destination.arguments,
      );
    }
    final delegate = Router.of(this).routerDelegate;
    if (delegate is ModularRouterDelegate) {
      return delegate.pushNamedAndRemoveUntil<T>(
        target,
        predicate,
        arguments: arguments,
      );
    }
    throw FlutterError(
      'context.pushNamedAndRemoveUntil: no outlet or ModularRouterDelegate '
      'found.',
    );
  }
}
