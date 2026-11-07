import '../navigation/route_resolver.dart';

/// Immutable snapshot of the route the app is currently resolving.
///
/// Passed to every route `builder` as `(context, state)` — à la go_router.
/// Holds the full [uri], the matched path [params] (e.g. `:id`), exposes the
/// query string via [query], and carries any [arguments] passed to
/// `context.pushNamed(path, arguments: ...)`. At app level it also holds the
/// open named [outlets].
class RouteState {
  const RouteState({
    required this.uri,
    this.params = const {},
    this.arguments,
    this.outlets = const {},
  });

  /// Reads a URL with a trailing outlet group, `/home(sheet:a//panel:b)?q=1`:
  /// query and fragment stay on [uri]; scheme and authority are dropped.
  factory RouteState.fromLocation(Uri location) {
    final path = location.path;
    final groupStart = path.lastIndexOf('(');
    final outlets = groupStart == -1 || !path.endsWith(')')
        ? null
        : _parseOutletGroup(path.substring(groupStart + 1, path.length - 1));
    final primaryPath = outlets == null ? path : path.substring(0, groupStart);
    return RouteState(
      uri: Uri(
        path: primaryPath.isEmpty ? '/' : primaryPath,
        query: location.hasQuery ? location.query : null,
        fragment: location.hasFragment ? location.fragment : null,
      ),
      outlets: outlets ?? const {},
    );
  }

  /// The full resolved URI (path + query).
  final Uri uri;

  /// Path parameters extracted from the matched route (e.g. `{'id': '42'}`).
  final Map<String, String> params;

  /// An arbitrary object passed at navigation time via
  /// `context.pushNamed(path, arguments: ...)`. NOT part of the URL, so it is
  /// `null` after a deep link / refresh — read it defensively.
  final Object? arguments;

  /// The open named outlets and their top paths (no query or fragment).
  final Map<String, Uri> outlets;

  /// Query parameters (`?a=1&b=2`).
  Map<String, String> get query => uri.queryParameters;

  /// Convenience accessor for a path [params] entry.
  String? operator [](String key) => params[key];

  /// [uri] with the [outlets] group, as [RouteState.fromLocation] reads it.
  Uri get location {
    if (outlets.isEmpty) return uri;
    final group = [
      for (final MapEntry(key: name, value: outletUri) in outlets.entries)
        '$name:${_encodeOutletPath(outletUri)}',
    ].join('//');
    final primaryPath = uri.path.isEmpty ? '/' : uri.path;
    return uri.replace(path: '$primaryPath($group)');
  }

  RouteState copyWith({
    Uri? uri,
    Map<String, String>? params,
    Object? arguments,
  }) {
    return RouteState(
      uri: uri ?? this.uri,
      params: params ?? this.params,
      arguments: arguments ?? this.arguments,
      outlets: outlets,
    );
  }

  @override
  String toString() =>
      'RouteState($uri, params: $params, arguments: $arguments'
      '${outlets.isEmpty ? '' : ', outlets: $outlets'})';
}

Map<String, Uri>? _parseOutletGroup(String group) {
  final outlets = <String, Uri>{};
  for (final entry in group.split('//')) {
    final separator = entry.indexOf(':');
    if (separator <= 0) return null;
    final name = entry.substring(0, separator);
    final path = _decodeOutletPath(entry.substring(separator + 1));
    outlets[name] = canonicalOutletLocation(Uri(path: '/$path'));
  }
  return outlets;
}

// A canonical path keeps parentheses literal (a literal `%` is `%25`), so in
// a group `%28` and `%29` can only be this escape.
String _encodeOutletPath(Uri outletUri) {
  final canonicalPath = canonicalOutletLocation(outletUri).path.substring(1);
  return canonicalPath.replaceAll('(', '%28').replaceAll(')', '%29');
}

String _decodeOutletPath(String path) =>
    path.replaceAll('%28', '(').replaceAll('%29', ')');
