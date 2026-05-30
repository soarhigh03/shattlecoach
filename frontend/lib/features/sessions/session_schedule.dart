import 'session_models.dart';

/// Locations.
const String _gymCheongryong = '청룡산체육관';
const String _gym71 = '서울대학교 71동 체육관 C코트';

/// Default capacity for every slot.
const int kDefaultCapacity = 16;

/// Returns the static schedule for [date]'s weekday.
///
/// - Mon/Wed/Fri: regular 17:00-19:00 @ 청룡산, extra 20:00-22:00 @ 71동
/// - Sat: extra 17:00-19:00 + extra 20:00-22:00, both @ 71동
/// - Tue/Thu/Sun: no sessions.
List<SessionTemplate> templatesForDate(DateTime date) {
  final wd = date.weekday; // 1 = Mon, 7 = Sun
  switch (wd) {
    case DateTime.monday:
    case DateTime.wednesday:
    case DateTime.friday:
      final prefix = const {
        DateTime.monday: 'mon',
        DateTime.wednesday: 'wed',
        DateTime.friday: 'fri',
      }[wd]!;
      return [
        SessionTemplate(
          slot: '${prefix}_1',
          category: SessionCategory.regular,
          startMinute: 17 * 60,
          endMinute: 19 * 60,
          location: _gymCheongryong,
          capacity: kDefaultCapacity,
        ),
        SessionTemplate(
          slot: '${prefix}_2',
          category: SessionCategory.extra,
          startMinute: 20 * 60,
          endMinute: 22 * 60,
          location: _gym71,
          capacity: kDefaultCapacity,
        ),
      ];
    case DateTime.saturday:
      return const [
        SessionTemplate(
          slot: 'sat_1',
          category: SessionCategory.extra,
          startMinute: 17 * 60,
          endMinute: 19 * 60,
          location: _gym71,
          capacity: kDefaultCapacity,
        ),
        SessionTemplate(
          slot: 'sat_2',
          category: SessionCategory.extra,
          startMinute: 20 * 60,
          endMinute: 22 * 60,
          location: _gym71,
          capacity: kDefaultCapacity,
        ),
      ];
    default:
      return const [];
  }
}

/// Monday of the ISO week that contains [date], with time set to 00:00.
DateTime mondayOf(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  return d.subtract(Duration(days: d.weekday - 1));
}

/// "M월 W주차" label. W is the week-of-month using the Korean convention
/// where the partial first week (the week containing the 1st) counts as 1주차.
///
/// We label by the month of the week's Monday — that's stable as the user
/// scrubs the date strip across a month boundary.
String weekLabel(DateTime weekStart) {
  final monday = mondayOf(weekStart);
  final firstOfMonth = DateTime(monday.year, monday.month, 1);
  // Days until the first Monday on/after the 1st of the month.
  final daysToFirstMonday = (8 - firstOfMonth.weekday) % 7;
  final firstMonday = firstOfMonth.add(Duration(days: daysToFirstMonday));
  final partialFirstWeek = firstOfMonth.weekday != DateTime.monday;
  final base = partialFirstWeek ? 2 : 1;
  final weeksFromFirstMonday = monday.difference(firstMonday).inDays ~/ 7;
  final weekNum = base + weeksFromFirstMonday;
  return '${monday.month}월 $weekNum주차';
}
