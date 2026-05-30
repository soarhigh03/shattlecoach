import 'package:flutter/material.dart';

class MenuDropdownItem {
  const MenuDropdownItem({
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool destructive;
}

/// Opens a small rounded popup anchored under [anchorKey].
///
/// Matches the "수정하기 / 삭제하기" sample design: white card, light gray
/// border, items stacked vertically with left-aligned labels.
Future<void> showMenuDropdown({
  required BuildContext context,
  required GlobalKey anchorKey,
  required List<MenuDropdownItem> items,
}) async {
  final renderBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (renderBox == null) return;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final anchorTopLeft = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
  final anchorSize = renderBox.size;

  const edgeInset = 12.0;
  final right =
      overlay.size.width - (anchorTopLeft.dx + anchorSize.width) + edgeInset;
  final top = anchorTopLeft.dy + anchorSize.height + 4;

  final selected = await showGeneralDialog<int>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    barrierLabel: 'menu',
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (ctx, _, _) {
      final theme = Theme.of(ctx);
      return Stack(
        children: [
          Positioned(
            top: top,
            right: right,
            child: Material(
              color: Colors.transparent,
              child: IntrinsicWidth(
                child: Container(
                  constraints: const BoxConstraints(minWidth: 132),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < items.length; i++)
                      InkWell(
                        onTap: () => Navigator.of(ctx).pop(i),
                        borderRadius: BorderRadius.vertical(
                          top: i == 0
                              ? const Radius.circular(12)
                              : Radius.zero,
                          bottom: i == items.length - 1
                              ? const Radius.circular(12)
                              : Radius.zero,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Text(
                            items[i].label,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: items[i].destructive
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (_, anim, _, child) {
      return FadeTransition(opacity: anim, child: child);
    },
  );

  if (selected != null && selected >= 0 && selected < items.length) {
    items[selected].onTap();
  }
}
