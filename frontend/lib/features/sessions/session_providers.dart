import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/supabase_service.dart';
import 'session_models.dart';
import 'session_schedule.dart';

/// Selected day in the date strip. Defaults to today.
final selectedDateProvider = StateProvider<DateTime>((_) => DateTime.now());

class SessionsRepository {
  SessionsRepository(this._client);
  final SupabaseClient _client;

  /// Returns DB rows for [date] keyed by slot.
  Future<Map<String, SessionRow>> sessionsByDate(DateTime date) async {
    final dateStr = _ymd(date);
    final rows = await _client
        .from('workout_sessions')
        .select('id, slot, capacity, status')
        .eq('session_date', dateStr);
    return {
      for (final r in (rows as List))
        (r as Map<String, dynamic>)['slot'] as String: SessionRow.fromJson(r),
    };
  }

  /// Map of session_id → attendee count.
  Future<Map<String, int>> attendeeCounts(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return const {};
    final rows = await _client
        .from('attendance')
        .select('session_id')
        .inFilter('session_id', sessionIds);
    final counts = <String, int>{};
    for (final r in rows as List) {
      final sid = (r as Map<String, dynamic>)['session_id'] as String;
      counts[sid] = (counts[sid] ?? 0) + 1;
    }
    return counts;
  }

  /// Set of session_ids the current user is registered for.
  Future<Set<String>> myRegistrations(List<String> sessionIds) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null || sessionIds.isEmpty) return const {};
    final rows = await _client
        .from('attendance')
        .select('session_id')
        .eq('user_id', uid)
        .inFilter('session_id', sessionIds);
    return {
      for (final r in rows as List)
        (r as Map<String, dynamic>)['session_id'] as String,
    };
  }

  /// Atomic upsert-session + insert-attendance via RPC.
  Future<void> register({
    required DateTime date,
    required String slot,
    required int capacity,
  }) async {
    await _client.rpc<dynamic>(
      'register_session',
      params: {'p_date': _ymd(date), 'p_slot': slot, 'p_capacity': capacity},
    );
  }

  Future<void> unregister(String sessionId) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return;
    await _client
        .from('attendance')
        .delete()
        .eq('session_id', sessionId)
        .eq('user_id', uid);
  }

  /// Attendee profiles for a session, in signup order.
  Future<List<Attendee>> attendees(String sessionId) async {
    final rows = await _client
        .from('attendance')
        .select('registered_at, profiles(id, name, email)')
        .eq('session_id', sessionId)
        .order('registered_at', ascending: true);
    return [
      for (final r in rows as List)
        Attendee.fromJson(r as Map<String, dynamic>),
    ];
  }

  String _ymd(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

class SessionRow {
  const SessionRow({
    required this.id,
    required this.slot,
    required this.capacity,
    required this.status,
  });
  final String id;
  final String slot;
  final int capacity;
  final String status;

  factory SessionRow.fromJson(Map<String, dynamic> json) => SessionRow(
    id: json['id'] as String,
    slot: json['slot'] as String,
    capacity: (json['capacity'] as num).toInt(),
    status: json['status'] as String,
  );
}

class Attendee {
  const Attendee({required this.id, required this.name, required this.email});
  final String id;
  final String name;
  final String email;

  factory Attendee.fromJson(Map<String, dynamic> json) {
    final p = json['profiles'] as Map<String, dynamic>;
    return Attendee(
      id: p['id'] as String,
      name: (p['name'] as String?) ?? '',
      email: (p['email'] as String?) ?? '',
    );
  }
}

final sessionsRepositoryProvider = Provider<SessionsRepository>(
  (_) => SessionsRepository(SupabaseBootstrap.client),
);

/// Merged schedule + DB state for the selected date.
final sessionViewsProvider = FutureProvider.autoDispose
    .family<List<SessionView>, DateTime>((ref, date) async {
      final templates = templatesForDate(date);
      if (templates.isEmpty || !SupabaseBootstrap.isInitialized) {
        return [
          for (final t in templates)
            SessionView(
              date: date,
              template: t,
              attendeeCount: 0,
              registered: false,
            ),
        ];
      }
      final repo = ref.read(sessionsRepositoryProvider);
      final rows = await repo.sessionsByDate(date);
      final ids = rows.values.map((r) => r.id).toList();
      final counts = await repo.attendeeCounts(ids);
      final mine = await repo.myRegistrations(ids);

      return [
        for (final t in templates)
          () {
            final row = rows[t.slot];
            return SessionView(
              date: date,
              template: t,
              attendeeCount: row == null ? 0 : (counts[row.id] ?? 0),
              registered: row != null && mine.contains(row.id),
              sessionId: row?.id,
            );
          }(),
      ];
    });

final attendeesProvider = FutureProvider.autoDispose
    .family<List<Attendee>, String>(
      (ref, sessionId) async =>
          ref.read(sessionsRepositoryProvider).attendees(sessionId),
    );
