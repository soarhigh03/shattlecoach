import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Flutter 의 [LicensePage] 를 우리 헤더 디자인으로 감싼 페이지.
///
/// 내부 [LicensePage] 가 자체 AppBar 를 가지므로, [Theme] 으로 그 AppBar 를
/// 0 높이/투명으로 만들어 시각적으로 숨기고 외부 AppBar 만 보이게 한다.
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  static const String _appName = 'Shattlecoach';
  static const String _appVersion = '0.1.0';

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(fontSize: 17),
        title: const Text('오픈소스 라이선스'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => context.pop(),
        ),
      ),
      body: Theme(
        data: base.copyWith(
          appBarTheme: base.appBarTheme.copyWith(
            toolbarHeight: 0,
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
        ),
        child: const LicensePage(
          applicationName: _appName,
          applicationVersion: _appVersion,
        ),
      ),
    );
  }
}
