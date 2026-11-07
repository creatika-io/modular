import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingPage extends StatefulWidget {
  const CountingPage(this.label, {super.key});

  final String label;

  static final Map<String, int> inits = {};

  @override
  State<CountingPage> createState() => _CountingPageState();
}

class _CountingPageState extends State<CountingPage> {
  int taps = 0;

  @override
  void initState() {
    super.initState();
    CountingPage.inits.update(widget.label, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('${widget.label} taps:$taps'),
  );
}

final module = createModule(
  register: (c) {
    c.route('/', child: (ctx, s) => const CountingPage('home'));
    c
        .outlet('sheet')
        .route(
          '/cards/:id',
          child: (ctx, s) => CountingPage('card ${s['id']}'),
        );
  },
);

/// Keeps the entries the app reports, as a browser does.
class BrowserHistory {
  BrowserHistory(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      _record,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        null,
      ),
    );
  }

  final WidgetTester tester;
  final List<String> entries = [];
  int _index = -1;

  String get current => entries[_index];

  Future<Object?> _record(MethodCall call) async {
    if (call.method != 'routeInformationUpdated') return null;
    final arguments = call.arguments as Map<Object?, Object?>;
    final uri = arguments['uri']! as String;
    if (arguments['replace'] == true && _index >= 0) {
      entries[_index] = uri;
    } else {
      entries
        ..removeRange(_index + 1, entries.length)
        ..add(uri);
      _index++;
    }
    return null;
  }

  Future<void> back() => _go(-1);

  Future<void> forward() => _go(1);

  Future<void> _go(int delta) async {
    _index += delta;
    await tester.binding.handlePushRoute(current);
    await tester.pumpAndSettle();
  }
}

Future<BrowserHistory> _pump(WidgetTester tester) async {
  CountingPage.inits.clear();
  final history = BrowserHistory(tester);
  final boot = bootstrapModule(module);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: modularRouterConfig(
        boot.routes,
        injector: boot.injector,
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
  return history;
}

BuildContext _contextOf(WidgetTester tester, String text) =>
    tester.element(find.text(text));

Future<void> _openCards(WidgetTester tester) async {
  _contextOf(tester, 'home taps:0').navigateOutlets({'sheet': '/cards/1'});
  await tester.pumpAndSettle();
  await tester.tap(find.text('card 1 taps:0'));
  await tester.pump();
}

void main() {
  testWidgets('every change of the top page is a new history entry', (
    tester,
  ) async {
    final history = await _pump(tester);
    await _openCards(tester);
    final result = _contextOf(tester, 'card 1 taps:1').pushNamed('/cards/2');
    await tester.pumpAndSettle();
    expect(history.entries, ['/', '/(sheet:cards/1)', '/(sheet:cards/2)']);

    _contextOf(tester, 'card 2 taps:0').pop('done');
    await tester.pumpAndSettle();
    expect(await result, 'done');
    _contextOf(tester, 'card 1 taps:1').closeOutlet();
    await tester.pumpAndSettle();
    expect(history.entries, [
      '/',
      '/(sheet:cards/1)',
      '/(sheet:cards/2)',
      '/(sheet:cards/1)',
      '/',
    ]);
  });

  testWidgets('back pops to the lower page, keeping it and the primary page; '
      'forward pushes the page again', (tester) async {
    final history = await _pump(tester);
    await tester.tap(find.text('home taps:0'));
    await _openCards(tester);
    final result = _contextOf(tester, 'card 1 taps:1').pushNamed('/cards/2');
    await tester.pumpAndSettle();

    await history.back();
    expect(history.current, '/(sheet:cards/1)');
    expect(await result, isNull);
    expect(find.text('card 2 taps:0', skipOffstage: false), findsNothing);
    expect(find.text('card 1 taps:1'), findsOneWidget);
    expect(find.text('home taps:1'), findsOneWidget);

    await history.forward();
    expect(history.current, '/(sheet:cards/2)');
    expect(find.text('card 2 taps:0'), findsOneWidget);
    expect(find.text('card 1 taps:1', skipOffstage: false), findsOneWidget);

    await history.back();
    await history.back();
    expect(history.current, '/');
    expect(find.textContaining('card'), findsNothing);
    expect(find.text('home taps:1'), findsOneWidget);
    expect(history.entries, ['/', '/(sheet:cards/1)', '/(sheet:cards/2)']);
    expect(CountingPage.inits, {'home': 1, 'card 1': 1, 'card 2': 2});
  });

  testWidgets('a URL page not in the stack is pushed on it; a closed outlet '
      'opens with that page alone', (tester) async {
    final history = await _pump(tester);
    await tester.binding.handlePushRoute('/(sheet:cards/3)');
    await tester.pumpAndSettle();
    expect(find.text('card 3 taps:0'), findsOneWidget);

    await tester.binding.handlePushRoute('/(sheet:cards/4)');
    await tester.pumpAndSettle();
    expect(find.text('card 4 taps:0'), findsOneWidget);
    expect(find.text('card 3 taps:0', skipOffstage: false), findsOneWidget);

    _contextOf(tester, 'card 4 taps:0').pop();
    await tester.pumpAndSettle();
    _contextOf(tester, 'card 3 taps:0').pop();
    await tester.pumpAndSettle();
    expect(history.current, '/');
    expect(CountingPage.inits, {'home': 1, 'card 3': 1, 'card 4': 1});
  });

  testWidgets('closing and reopening in one frame starts the outlet afresh', (
    tester,
  ) async {
    await _pump(tester);
    await _openCards(tester);
    var card2Completed = false;
    unawaited(
      _contextOf(
        tester,
        'card 1 taps:1',
      ).pushNamed('/cards/2').whenComplete(() => card2Completed = true),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePushRoute('/');
    await tester.binding.handlePushRoute('/(sheet:cards/2)');
    await tester.pumpAndSettle();
    expect(card2Completed, isTrue);
    expect(find.text('card 1 taps:1', skipOffstage: false), findsNothing);
    expect(find.text('card 2 taps:0'), findsOneWidget);
    expect(CountingPage.inits, {'home': 1, 'card 1': 1, 'card 2': 2});
  });

  testWidgets('the platform echoing the top page changes nothing', (
    tester,
  ) async {
    final history = await _pump(tester);
    await _openCards(tester);
    final result = _contextOf(tester, 'card 1 taps:1').pushNamed('/cards/2');
    await tester.pumpAndSettle();
    final entries = [...history.entries];

    await tester.binding.handlePushRoute(history.current);
    await tester.pumpAndSettle();
    expect(find.text('card 2 taps:0'), findsOneWidget);
    expect(find.text('card 1 taps:1', skipOffstage: false), findsOneWidget);
    expect(history.entries, entries);
    expect(CountingPage.inits, {'home': 1, 'card 1': 1, 'card 2': 1});

    _contextOf(tester, 'card 2 taps:0').pop();
    await result;
  });
}
