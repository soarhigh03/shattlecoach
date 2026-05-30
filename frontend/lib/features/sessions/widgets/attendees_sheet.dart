import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session_providers.dart';

Future<void> showAttendeesSheet({
  required BuildContext context,
  required String? sessionId,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _AttendeesSheet(sessionId: sessionId, title: title),
  );
}

class _AttendeesSheet extends ConsumerWidget {
  const _AttendeesSheet({required this.sessionId, required this.title});

  final String? sessionId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$title 참여자',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            if (sessionId == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  '아직 신청자가 없어요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              _AttendeesList(sessionId: sessionId!),
          ],
        ),
      ),
    );
  }
}

class _AttendeesList extends ConsumerWidget {
  const _AttendeesList({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(attendeesProvider(sessionId));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          '명단을 불러오지 못했어요.\n$e',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '아직 신청자가 없어요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.5,
          ),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: list.length,
            separatorBuilder: (_, _) =>
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
            itemBuilder: (_, i) {
              final a = list[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        a.name.isEmpty ? '이름 미입력' : a.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
