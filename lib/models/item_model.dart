import 'package:intl/intl.dart';

class ItemModel {
  final String? no;
  final String? employeeCompany;
  final DateTime? labourCardExpiry;
  final DateTime? visaExpiry;
  final String? contact;
  final bool? isCompany;
  final int? rowIndex; // For updating existing rows in Google Sheets

  ItemModel({
    this.no,
    this.employeeCompany,
    this.labourCardExpiry,
    this.visaExpiry,
    this.contact,
    this.isCompany,
    this.rowIndex,
  });

  // Convert from Google Sheets row data
  factory ItemModel.fromSheetRow(List<dynamic> row, int index) {
    DateTime? labourCardExpiry;
    if (row.length > 2 &&
        row[2] != null &&
        row[2].toString().trim().isNotEmpty) {
      labourCardExpiry = _parseDate(row[2]);
    }

    DateTime? visaExpiry;
    if (row.length > 3 &&
        row[3] != null &&
        row[3].toString().trim().isNotEmpty) {
      visaExpiry = _parseDate(row[3]);
    }

    // Parse isCompany from column 5 (index 5)
    // Accepts "Company" or "Employee" (case-insensitive)
    // Also supports legacy "true"/"false" for backward compatibility
    bool? isCompany;
    if (row.length > 5 &&
        row[5] != null &&
        row[5].toString().trim().isNotEmpty) {
      final typeValue = row[5].toString().trim().toLowerCase();
      if (typeValue == 'company') {
        isCompany = true;
      } else if (typeValue == 'employee') {
        isCompany = false;
      } else {
        // Backward compatibility: support "true"/"false" or "1"/"0"
        isCompany = typeValue == 'true' || typeValue == '1';
      }
    }

    return ItemModel(
      no: row.length > 0 && row[0] != null ? row[0].toString().trim() : null,
      employeeCompany: row.length > 1 && row[1] != null
          ? row[1].toString().trim()
          : null,
      labourCardExpiry: labourCardExpiry,
      visaExpiry: visaExpiry,
      contact: row.length > 4 && row[4] != null
          ? row[4].toString().trim()
          : null,
      isCompany: isCompany,
      rowIndex: index + 2, // +2 because row 1 is header, and index is 0-based
    );
  }

  // Convert to Google Sheets row data
  List<String> toSheetRow() {
    String typeValue = '';
    if (isCompany == true) {
      typeValue = 'Company';
    } else if (isCompany == false) {
      typeValue = 'Employee';
    }
    return [
      no ?? '',
      employeeCompany ?? '',
      labourCardExpiry != null ? _formatDate(labourCardExpiry!) : '',
      visaExpiry != null ? _formatDate(visaExpiry!) : '',
      contact ?? '',
      typeValue,
    ];
  }

  // Parse date from various formats (handles Google Sheets date formats)
  // Returns null if date cannot be parsed (instead of defaulting to current date)
  static DateTime? _parseDate(dynamic dateValue) {
    try {
      // Handle null or empty values
      if (dateValue == null) {
        return null;
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
        return null;
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

      // If all parsing fails, return null
      print(
        '[ItemModel] All date parsing attempts failed for: $dateString, returning null',
      );
      return null;
    } catch (e) {
      print('[ItemModel] Error in _parseDate: $e');
      return null;
    }
  }

  // Format date for Google Sheets (ISO format: YYYY-MM-DD)
  static String _formatDate(DateTime date) {
    // Normalize to date-only (midnight) to avoid time component issues
    final normalizedDate = DateTime(date.year, date.month, date.day);
    return normalizedDate.toIso8601String().split('T')[0]; // Returns YYYY-MM-DD
  }

  // Check if labour card is expiring within specified days
  bool isExpiringWithinDays(int days) {
    if (labourCardExpiry == null) return false;
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      labourCardExpiry!.year,
      labourCardExpiry!.month,
      labourCardExpiry!.day,
    );
    final difference = expiry.difference(today).inDays;
    return difference >= 0 && difference <= days;
  }

  // Check if visa is expiring within specified days
  bool isVisaExpiringWithinDays(int days) {
    if (visaExpiry == null) return false;
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      visaExpiry!.year,
      visaExpiry!.month,
      visaExpiry!.day,
    );
    final difference = expiry.difference(today).inDays;
    return difference >= 0 && difference <= days;
  }

  // Check if labour card has expired
  bool get isExpired {
    if (labourCardExpiry == null) return false;
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      labourCardExpiry!.year,
      labourCardExpiry!.month,
      labourCardExpiry!.day,
    );
    return expiry.isBefore(today);
  }

  // Check if visa has expired
  bool get isVisaExpired {
    if (visaExpiry == null) return false;
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      visaExpiry!.year,
      visaExpiry!.month,
      visaExpiry!.day,
    );
    return expiry.isBefore(today);
  }

  // Get days until labour card expiry
  int? get daysUntilExpiry {
    if (labourCardExpiry == null) return null;
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      labourCardExpiry!.year,
      labourCardExpiry!.month,
      labourCardExpiry!.day,
    );
    return expiry.difference(today).inDays;
  }

  // Get days until visa expiry
  int? get visaDaysUntilExpiry {
    if (visaExpiry == null) return null;
    final now = DateTime.now();
    // Normalize both dates to midnight for accurate date-only comparison
    final today = DateTime(now.year, now.month, now.day);
    final expiry = DateTime(
      visaExpiry!.year,
      visaExpiry!.month,
      visaExpiry!.day,
    );
    return expiry.difference(today).inDays;
  }

  ItemModel copyWith({
    String? no,
    String? employeeCompany,
    DateTime? labourCardExpiry,
    DateTime? visaExpiry,
    String? contact,
    bool? isCompany,
    int? rowIndex,
  }) {
    return ItemModel(
      no: no ?? this.no,
      employeeCompany: employeeCompany ?? this.employeeCompany,
      labourCardExpiry: labourCardExpiry ?? this.labourCardExpiry,
      visaExpiry: visaExpiry ?? this.visaExpiry,
      contact: contact ?? this.contact,
      isCompany: isCompany ?? this.isCompany,
      rowIndex: rowIndex ?? this.rowIndex,
    );
  }
}
