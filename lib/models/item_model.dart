import 'package:intl/intl.dart';

class ItemModel {
  final String name;
  final DateTime expiryDate;
  final String category;
  final String notes;
  final int? rowIndex; // For updating existing rows in Google Sheets

  ItemModel({
    required this.name,
    required this.expiryDate,
    required this.category,
    required this.notes,
    this.rowIndex,
  });

  // Convert from Google Sheets row data
  factory ItemModel.fromSheetRow(List<dynamic> row, int index) {
    DateTime expiryDate;
    if (row.length > 1 && row[1] != null) {
      expiryDate = _parseDate(row[1]);
    } else {
      final now = DateTime.now();
      expiryDate = DateTime(now.year, now.month, now.day);
    }
    return ItemModel(
      name: row.length > 0 ? (row[0]?.toString() ?? '') : '',
      expiryDate: expiryDate,
      category: row.length > 2 ? (row[2]?.toString() ?? '') : '',
      notes: row.length > 3 ? (row[3]?.toString() ?? '') : '',
      rowIndex: index + 2, // +2 because row 1 is header, and index is 0-based
    );
  }

  // Convert to Google Sheets row data
  List<String> toSheetRow() {
    return [name, _formatDate(expiryDate), category, notes];
  }

  // Parse date from various formats (handles Google Sheets date formats)
  static DateTime _parseDate(dynamic dateValue) {
    try {
      // Handle null or empty values
      if (dateValue == null) {
        print('[ItemModel] Date value is null, using current date');
        final now = DateTime.now();
        return DateTime(now.year, now.month, now.day);
      }

      // Handle numeric values (Google Sheets date serial numbers)
      // Google Sheets uses days since December 30, 1899 (similar to Excel)
      if (dateValue is num) {
        final serialNumber = dateValue.toDouble();
        // Google Sheets epoch: December 30, 1899
        final baseDate = DateTime(1899, 12, 30);
        final parsedDate = baseDate.add(Duration(days: serialNumber.toInt()));
        // Normalize to date-only (midnight) to avoid time component issues
        final normalizedDate = DateTime(
          parsedDate.year,
          parsedDate.month,
          parsedDate.day,
        );
        print(
          '[ItemModel] Parsed date from serial number $serialNumber: $normalizedDate',
        );
        return normalizedDate;
      }

      // Convert to string for parsing
      final dateString = dateValue.toString().trim();

      if (dateString.isEmpty) {
        print('[ItemModel] Date string is empty, using current date');
        final now = DateTime.now();
        return DateTime(now.year, now.month, now.day);
      }

      // Check if string is a numeric value (Google Sheets date serial number as string)
      // Try parsing as number first (e.g., "46008" is a serial number)
      try {
        final numericValue = double.tryParse(dateString);
        if (numericValue != null &&
            numericValue > 0 &&
            numericValue < 1000000) {
          // Likely a Google Sheets date serial number
          // Google Sheets epoch: December 30, 1899
          final baseDate = DateTime(1899, 12, 30);
          final parsedDate = baseDate.add(Duration(days: numericValue.toInt()));
          // Normalize to date-only (midnight) to avoid time component issues
          final normalizedDate = DateTime(
            parsedDate.year,
            parsedDate.month,
            parsedDate.day,
          );
          print(
            '[ItemModel] Parsed date from serial number string "$dateString": $normalizedDate',
          );
          return normalizedDate;
        }
      } catch (e) {
        // Not a numeric string, continue with date parsing
        print(
          '[ItemModel] String "$dateString" is not a serial number, trying date formats',
        );
      }

      // Try ISO format first (e.g., "2024-12-25" or "2024-12-25T00:00:00")
      if (dateString.contains('T') ||
          (dateString.contains('-') && dateString.length >= 10)) {
        try {
          final parsed = DateTime.parse(dateString);
          // Normalize to date-only (midnight) to avoid time component issues
          final normalizedDate = DateTime(
            parsed.year,
            parsed.month,
            parsed.day,
          );
          print('[ItemModel] Parsed ISO date: $dateString -> $normalizedDate');
          return normalizedDate;
        } catch (e) {
          print('[ItemModel] Failed to parse ISO date: $e');
        }
      }

      // Try common date formats using DateFormat
      final dateFormats = [
        'yyyy-MM-dd', // 2024-12-25 (ISO format)
        'ddMMyyyy', // 25122024 (ddmmyyyy format)
        'dd/MM/yyyy', // 25/12/2024
        'MM/dd/yyyy', // 12/25/2024
        'dd-MM-yyyy', // 25-12-2024
        'MM-dd-yyyy', // 12-25-2024
        'MMM dd, yyyy', // Dec 25, 2024
        'dd MMM yyyy', // 25 Dec 2024
        'yyyy/MM/dd', // 2024/12/25
      ];

      for (final format in dateFormats) {
        try {
          final parsed = DateFormat(format).parse(dateString);
          // Normalize to date-only (midnight) to avoid time component issues
          final normalizedDate = DateTime(
            parsed.year,
            parsed.month,
            parsed.day,
          );
          print(
            '[ItemModel] Parsed date with format $format: $dateString -> $normalizedDate',
          );
          return normalizedDate;
        } catch (_) {
          continue;
        }
      }

      // Last resort: try DateTime.parse with the original string
      try {
        final parsed = DateTime.parse(dateString);
        // Normalize to date-only (midnight) to avoid time component issues
        final normalizedDate = DateTime(parsed.year, parsed.month, parsed.day);
        print(
          '[ItemModel] Parsed with DateTime.parse: $dateString -> $normalizedDate',
        );
        return normalizedDate;
      } catch (e) {
        print('[ItemModel] Failed to parse date: $dateString, error: $e');
      }

      // If all parsing fails, return current date (normalized)
      print(
        '[ItemModel] All date parsing attempts failed for: $dateString, using current date',
      );
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    } catch (e) {
      print('[ItemModel] Error in _parseDate: $e');
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    }
  }

  // Format date for Google Sheets (ISO format: YYYY-MM-DD)
  static String _formatDate(DateTime date) {
    // Normalize to date-only (midnight) to avoid time component issues
    final normalizedDate = DateTime(date.year, date.month, date.day);
    return normalizedDate.toIso8601String().split('T')[0]; // Returns YYYY-MM-DD
  }

  // Check if item is expiring within specified days
  bool isExpiringWithinDays(int days) {
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
    final difference = expiry.difference(today).inDays;
    return difference >= 0 && difference <= days;
  }

  // Check if item has expired
  bool get isExpired {
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
    return expiry.isBefore(today);
  }

  // Get days until expiry
  int get daysUntilExpiry {
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
    return expiry.difference(today).inDays;
  }

  ItemModel copyWith({
    String? name,
    DateTime? expiryDate,
    String? category,
    String? notes,
    int? rowIndex,
  }) {
    return ItemModel(
      name: name ?? this.name,
      expiryDate: expiryDate ?? this.expiryDate,
      category: category ?? this.category,
      notes: notes ?? this.notes,
      rowIndex: rowIndex ?? this.rowIndex,
    );
  }
}
