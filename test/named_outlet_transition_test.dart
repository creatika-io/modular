import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';

class StatefulCard extends StatefulWidget {
  const StatefulCard({super.key});

  static int inits = 0;

  @override
  State<StatefulCard> createState() => _StatefulCardState();
}

class _StatefulCardState extends State<StatefulCard> {
  @override
  void initState() {
    super.initState();
    StatefulCard.inits++;
  }

  @override
  Widget build(BuildContext context) => const Text('stateful');
}

final module = createModule(
  register: (c) {
    c.route('/', child: (ctx, s) => const Text('home'));
    c.outlet('sheet')
      ..route('/cards/:id', child: (ctx, s) => Text('card ${s['id']}'))
      ..route('/stateful', child: (ctx, s) => const StatefulCard());
  },
);

Future<void> _pump(
  WidgetTester tester, {
  required bool mountedWhileClosed,
}) async {
  final boot = bootstrapModule(module);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: modularRouterConfig(
        boot.routes,
        injector: boot.injector,
        shellBuilder: (context, child) => Row(
          children: [
            Expanded(child: child),
            if (mountedWhileClosed ||
                context.routeState().outlets.containsKey('sheet'))
              const Expanded(child: RouterOutlet(name: 'sheet')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _transition(WidgetTester tester, String text) =>
    ModalRoute.of(tester.element(find.text(text)))!.animation!.value;

void main() {
  for (final mountedWhileClosed in [false, true]) {
    testWidgets('an outlet opened or reseeded from outside shows its base page '
        'without a page transition (mounted while closed: '
        '$mountedWhileClosed)', (tester) async {
      await _pump(tester, mountedWhileClosed: mountedWhileClosed);
      tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/1'});
      await tester.pump();
      expect(_transition(tester, 'card 1'), 1);

      tester.element(find.text('home')).navigateOutlets({'sheet': '/cards/2'});
      await tester.pump();
      expect(_transition(tester, 'card 2'), 1);
      await tester.pumpAndSettle();

      // A page pushed inside the outlet keeps its transition.
      final pushed = tester.element(find.text('card 2')).pushNamed('/cards/3');
      await tester.pump();
      expect(_transition(tester, 'card 3'), lessThan(1));
      await tester.pumpAndSettle();
      tester.element(find.text('card 3')).pop();
      await pushed;
    });
  }

  testWidgets('a page the URL pushes or pops animates like one pushed or '
      'popped in the app', (tester) async {
    await _pump(tester, mountedWhileClosed: false);
    await tester.binding.handlePushRoute('/(sheet:cards/1)');
    await tester.pump();
    expect(_transition(tester, 'card 1'), 1);

    await tester.binding.handlePushRoute('/(sheet:cards/2)');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_transition(tester, 'card 2'), lessThan(1)); // entering
    await tester.pumpAndSettle();

    await tester.binding.handlePushRoute('/(sheet:cards/1)');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_transition(tester, 'card 2'), lessThan(1)); // leaving
    await tester.pumpAndSettle();
    expect(find.text('card 2'), findsNothing);
  });

  testWidgets('navigating an outlet to the base it shows keeps that page and '
      'pops what was pushed above it', (tester) async {
    StatefulCard.inits = 0;
    await _pump(tester, mountedWhileClosed: false);
    for (var tap = 0; tap < 3; tap++) {
      tester.element(find.text('home')).navigateOutlets({'sheet': '/stateful'});
      await tester.pump();
      expect(_transition(tester, 'stateful'), 1);
    }
    expect(StatefulCard.inits, 1);

    final pushed = tester.element(find.text('stateful')).pushNamed('/cards/3');
    await tester.pumpAndSettle();
    tester.element(find.text('home')).navigateOutlets({'sheet': '/stateful'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_transition(tester, 'card 3'), lessThan(1)); // leaving, animated
    await tester.pumpAndSettle();
    expect(await pushed, isNull);
    expect(find.text('card 3'), findsNothing);
    expect(find.text('stateful'), findsOneWidget);
    expect(StatefulCard.inits, 1);
  });
}
