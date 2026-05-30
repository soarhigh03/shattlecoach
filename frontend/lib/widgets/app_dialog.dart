import 'package:flutter/material.dart';

/// 앱 공용 팝업 다이얼로그.
///
/// ## 디자인 스펙
/// - 배경 오버레이: 검정 30% (`Colors.black.withValues(alpha: 0.3)`).
/// - 팝업 본체: 흰색(테마 surface) 둥근 모서리, `blurRadius: 10` 그림자.
/// - 타이틀 영역: 검정 배경 + 흰 글씨, 세미볼드(`FontWeight.w600`) 17pt, 가운데 정렬.
/// - 본문: 미디움(`FontWeight.w500`) 15pt, 가운데 정렬. 본문 안의 [Text] 위젯은
///   별도 스타일을 지정하지 않아도 이 값이 기본으로 적용된다 (DefaultTextStyle 머지).
///
/// ## 사용 가이드
/// - [title] 은 선택사항이다. `null` 이면 본문만 표시된다.
/// - [child] 로 본문 위젯을 자유롭게 구성할 수 있다 — 단순 [Text] 부터 입력 필드,
///   버튼 묶음까지 모두 가능하다.
/// - 다이얼로그를 닫고 결과를 받으려면 [showAppDialog] 헬퍼를 사용하고
///   본문 안에서 `Navigator.of(context).pop(value)` 를 호출한다.
///
/// ## 호출 예시
/// ```dart
/// final code = await showAppDialog<String>(
///   context: context,
///   title: '임원진 등록하기',
///   builder: (_) => const _ExecCodeForm(),
/// );
/// ```
class AppDialog extends StatelessWidget {
  const AppDialog({super.key, this.title, required this.child});

  final String? title;
  final Widget child;

  static const double _radius = 20;
  static const double _maxWidth = 360;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(_radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Container(
                    color: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Text(
                      title!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [AppDialog] 를 표시하는 헬퍼. 결과 값을 [Navigator.pop] 으로 돌려받는다.
///
/// [barrierDismissible] 가 `true` (기본) 이면 오버레이를 탭해서 닫을 수 있다.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  String? title,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'AppDialog',
    barrierColor: Colors.black.withValues(alpha: 0.3),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) =>
        AppDialog(title: title, child: Builder(builder: builder)),
    transitionBuilder: (context, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}
