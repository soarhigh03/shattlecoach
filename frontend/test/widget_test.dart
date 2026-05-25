import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shattlecoach/app.dart';

void main() {
  testWidgets('App boots into a router-driven Material app', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShattlecoachApp()));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
