import 'package:intl/intl.dart';

class DateUtils {
  static String formatDate(DateTime date) {
    return DateFormat('yyyy-MM-dd').format(date);
  }

  static String formatDateDisplay(DateTime date) {
    return DateFormat('MMM dd, yyyy').format(date);
  }

  static String formatDateShort(DateTime date) {
    return DateFormat('MM/dd/yyyy').format(date);
  }

  static DateTime? parseDate(String dateString) {
    try {
      // Try ISO format first
      if (dateString.contains('T') || dateString.contains('-')) {
        return DateTime.parse(dateString);
      }
      // Try common formats
      final formats = [
        'yyyy-MM-dd',
        'MM/dd/yyyy',
        'dd/MM/yyyy',
        'MM-dd-yyyy',
        'dd-MM-yyyy',
      ];
      for (final format in formats) {
        try {
          return DateFormat(format).parse(dateString);
        } catch (_) {
          continue;
        }
      }
      return DateTime.parse(dateString);
    } catch (e) {
      return null;
    }
  }

  static int daysBetween(DateTime start, DateTime end) {
    return end.difference(start).inDays;
  }

  static bool isWithinDays(DateTime date, int days) {
    final now = DateTime.now();
    final difference = date.difference(now).inDays;
    return difference >= 0 && difference <= days;
  }
}

