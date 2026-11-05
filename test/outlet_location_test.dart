import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

RouteState _read(String location) =>
    RouteState.fromLocation(Uri.parse(location));

void main() {
  group('RouteState.fromLocation', () {
    test('a location without a group is the primary route alone', () {
      final state = _read('/map-view/12?zoom=3');
      expect(state.uri, Uri.parse('/map-view/12?zoom=3'));
      expect(state.outlets, isEmpty);
    });

    test('a group opens named outlets beside the primary route', () {
      final state = _read('/map-view(sheet:profiles/alice)');
      expect(state.uri, Uri.parse('/map-view'));
      expect(state.outlets, {'sheet': Uri.parse('/profiles/alice')});
    });

    test('several outlets, in the order the URL lists them', () {
      final state = _read('/(sheet:card//panel:help/faq)');
      expect(state.uri, Uri.parse('/'));
      expect(state.outlets.keys, ['sheet', 'panel']);
      expect(state.outlets['panel'], Uri.parse('/help/faq'));
    });

    test('query and fragment belong to the primary route', () {
      final state = _read('/home(sheet:card)?tab=2#top');
      expect(state.uri, Uri.parse('/home?tab=2#top'));
      expect(state.outlets, {'sheet': Uri.parse('/card')});
    });

    test('a trailing group that is not `name:path` stays in the primary', () {
      expect(_read('/docs(intro)').uri.path, '/docs(intro)');
      expect(_read('/docs(intro)').outlets, isEmpty);
    });
  });

  group('RouteState.location', () {
    test('without outlets it is the primary uri, unchanged', () {
      final uri = Uri.parse('/home?tab=2');
      expect(RouteState(uri: uri).location, uri);
    });

    test('outlets are serialized in insertion order, not sorted', () {
      final state = RouteState(
        uri: Uri.parse('/home'),
        outlets: {'sheet': Uri.parse('/b'), 'panel': Uri.parse('/a')},
      );
      expect(state.location.toString(), '/home(sheet:b//panel:a)');
    });

    test('a primary route at the root still carries its group', () {
      final state = RouteState(
        uri: Uri.parse('/?q=1'),
        outlets: {'sheet': Uri.parse('/profiles/alice')},
      );
      expect(state.location.toString(), '/(sheet:profiles/alice)?q=1');
    });

    test('parentheses inside an outlet path are percent-encoded', () {
      final state = RouteState(
        uri: Uri.parse('/files'),
        outlets: {'sheet': Uri.parse('/files/report(1)')},
      );
      expect(state.location.toString(), '/files(sheet:files/report%281%29)');
    });
  });

  group('round trip', () {
    for (final location in [
      '/home',
      '/map-view(sheet:profiles/alice)',
      '/(sheet:card//panel:help)',
      '/home(sheet:card)?tab=2#top',
      '/a(b)(sheet:x)',
      '/files(sheet:files/report%281%29)',
      '/(sheet:time/12:30//panel:a%20b)',
      '/(sheet:)',
    ]) {
      test(location, () {
        final state = _read(location);
        expect(state.location.toString(), location);
        final again = RouteState.fromLocation(state.location);
        expect(again.uri, state.uri);
        expect(again.outlets, state.outlets);
      });
    }

    test('an outlet path with delimiters reads back exactly', () {
      final outlets = {
        'sheet': Uri.parse('/files/report(1)'),
        'panel': Uri.parse('/time/12:30'),
      };
      final state = RouteState(uri: Uri.parse('/'), outlets: outlets);
      expect(RouteState.fromLocation(state.location).outlets, outlets);
    });

    test('empty segments of an outlet path are dropped', () {
      final state = RouteState(
        uri: Uri.parse('/'),
        outlets: {'sheet': Uri.parse('/cards//1/')},
      );
      expect(state.location.toString(), '/(sheet:cards/1)');
      expect(RouteState.fromLocation(state.location).outlets, {
        'sheet': Uri.parse('/cards/1'),
      });
    });
  });

  group('canonical outlet locations', () {
    test('written without query, fragment, empty segments or encoding '
        'variants', () {
      final state = RouteState(
        uri: Uri.parse('/'),
        outlets: {'sheet': Uri.parse('/files//report%281%29/?v=2#top')},
      );
      expect(state.location.toString(), '/(sheet:files/report%281%29)');
      expect(RouteState.fromLocation(state.location).outlets, {
        'sheet': Uri.parse('/files/report(1)'),
      });
    });

    test('a literal percent sign is not mistaken for an escape', () {
      final outlets = {
        'sheet': Uri(pathSegments: ['', 'files', '%28x%29']),
      };
      final state = RouteState(uri: Uri.parse('/'), outlets: outlets);
      final readBack = RouteState.fromLocation(state.location).outlets;
      expect(readBack, outlets);
      expect(readBack['sheet']!.pathSegments.last, '%28x%29');
    });

    test('what is read back writes and reads back identically', () {
      for (final outletUri in [
        Uri.parse('/profiles/alice'),
        Uri.parse('/files/report(1)'),
        Uri.parse('/files/report%281%29/'),
        Uri.parse('/a%20b//c?x=1'),
        Uri.parse('/time/12:30'),
        Uri(pathSegments: ['', '(', ')', '%', '%28']),
        Uri.parse('/'),
      ]) {
        final first = RouteState.fromLocation(
          RouteState(uri: Uri.parse('/'), outlets: {'o': outletUri}).location,
        );
        final second = RouteState.fromLocation(first.location);
        expect(second.outlets, first.outlets, reason: '$outletUri');
        expect(second.location, first.location, reason: '$outletUri');
      }
    });
  });
}
