/// Domain types for the 운동 신청 board.
library;

import 'package:flutter/foundation.dart';

/// 정규 vs 추가. Affects the title shown on the card.
enum SessionCategory {
  regular('정규 운동'),
  extra('추가 운동');

  const SessionCategory(this.label);
  final String label;
}

/// Static, locally-derived description of a slot for a given weekday.
///
/// The schedule itself isn't stored in the DB — every Mon/Wed/Fri/Sat has the
/// same shape week over week. The DB only stores the rows that have been
/// "opened" (i.e. someone signed up).
@immutable
class SessionTemplate {
  const SessionTemplate({
    required this.slot,
    required this.category,
    required this.startMinute,
    required this.endMinute,
    required this.location,
    required this.capacity,
  });

  /// e.g. `mon_1`, `sat_2`. Matches the `slot` column in workout_sessions.
  final String slot;
  final SessionCategory category;
  final int startMinute;
  final int endMinute;
  final String location;
  final int capacity;

  String get timeRange {
    String fmt(int m) {
      final h = (m ~/ 60).toString().padLeft(2, '0');
      final mm = (m % 60).toString().padLeft(2, '0');
      return '$h:$mm';
    }

    return '${fmt(startMinute)}-${fmt(endMinute)}';
  }
}

/// A slot template merged with whatever the DB knows about it for a given
/// date — capacity counters, the current user's registration state, the
/// `workout_sessions.id` if it has been opened yet.
@immutable
class SessionView {
  const SessionView({
    required this.date,
    required this.template,
    required this.attendeeCount,
    required this.registered,
    this.sessionId,
  });

  final DateTime date;
  final SessionTemplate template;
  final int attendeeCount;
  final bool registered;

  /// Null until the row has been opened (first signup or exec creation).
  final String? sessionId;

  bool get full => attendeeCount >= template.capacity;

  String get title {
    final dow = const ['월', '화', '수', '목', '금', '토', '일'][date.weekday - 1];
    return '$dow요일 ${template.category.label}';
  }
}
