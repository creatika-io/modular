import 'package:flutter/widgets.dart';

import '../route/modular_route.dart';
import '../route/route_state.dart';

/// Translates between the platform's [RouteInformation] (the URL) and our
/// [RouteState]; route matching happens in the delegate. Uses the modern `uri`
/// API (no deprecated `location`).
class ModularRouteInformationParser extends RouteInformationParser<RouteState> {
  ModularRouteInformationParser({this.routes});

  /// Outlet groups are read once these declare a named-outlet route.
  final RouteCollection? routes;

  @override
  Future<RouteState> parseRouteInformation(
    RouteInformation routeInformation,
  ) async {
    return readLocation(routeInformation.uri, routes);
  }

  @override
  RouteInformation restoreRouteInformation(RouteState configuration) {
    return RouteInformation(uri: configuration.location);
  }
}

/// Apps without named-outlet routes keep `(name:path)` in the primary path.
RouteState readLocation(Uri location, RouteCollection? routes) {
  final declaresNamedOutlets =
      routes != null && routes.routes.any((route) => route.outlet != null);
  return declaresNamedOutlets
      ? RouteState.fromLocation(location)
      : RouteState(uri: location);
}
