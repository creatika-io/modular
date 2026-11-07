import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// Hosts the `sheet` outlet over the base page.
class AppShell extends StatelessWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sheetOpen = context.routeState().outlets.containsKey('sheet');
    return Stack(
      children: [
        child,
        if (sheetOpen)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 360,
            child: Material(
              elevation: 12,
              child: Stack(
                children: [
                  const RouterOutlet(name: 'sheet'),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => context.closeOutlet('sheet'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
