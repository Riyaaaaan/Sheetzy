import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import '../models/item_model.dart';
import '../services/google_sheets_service.dart';

class ExcelImportService {
  final GoogleSheetsService _sheetsService = GoogleSheetsService();
  final _storage = const FlutterSecureStorage();

  // Fields to ignore (calculated fields like "days left")
  static const List<String> _ignoredFields = [
    'days left',
    'days until',
    'days remaining',
    'status',
    'expired',
    'expiring',
  ];

  // Column mapping patterns for smart detection
  static const Map<String, List<String>> _columnPatterns = {
    'employeeCompany': [
      'name',
      'employee',
      'employee/company',
      'employee name',
      'person',
      'person name',
    ],
    'companyName': [
      'company name',
      'company',
      'employer',
      'employer name',
      'organization',
      'organization name',
    ],
    'labourCardExpiry': [
      'labour card',
      'labour card expiry',
      'labour card expiration',
      'lc expiry',
      'lc expiration',
      'labor card',
      'labor card expiry',
    ],
    'visaExpiry': [
      'visa',
      'visa expiry',
      'visa expiration',
      'visa date',
      'visa expiry date',
    ],
    'contact': [
      'contact',
      'phone',
      'mobile',
      'telephone',
      'tel',
      'phone number',
      'mobile number',
      'contact number',
    ],
    'no': ['no', 'number', 'id', '#', 'serial', 'serial number'],
  };

  /// Import Excel file and return import result
  Future<ImportResult> importExcelFile(Uint8List fileBytes) async {
    try {
      print(
        '[ExcelImportService] Starting import with ${fileBytes.length} bytes',
      );
      final excel = Excel.decodeBytes(fileBytes);
      print(
        '[ExcelImportService] Excel decoded. Number of sheets: ${excel.tables.length}',
      );

      if (excel.tables.isEmpty) {
        return ImportResult(success: false, error: 'Excel file has no sheets');
      }

      // Use first sheet
      final sheetKey = excel.tables.keys.first;
      final sheet = excel.tables[sheetKey];
      if (sheet == null) {
        return ImportResult(
          success: false,
          error: 'Could not access Excel sheet',
        );
      }

      print('[ExcelImportService] Sheet has ${sheet.rows.length} total rows');

      if (sheet.rows.isEmpty) {
        return ImportResult(success: false, error: 'Excel sheet is empty');
      }

      // Debug: Print first few rows to understand structure
      print('[ExcelImportService] First 10 rows preview:');
      for (int i = 0; i < sheet.rows.length && i < 10; i++) {
        final row = sheet.rows[i];
        final preview = row
            .take(6)
            .map((cell) {
              if (cell == null || cell.value == null) return 'null';
              final str = cell.value.toString().trim();
              return str.length > 15 ? '${str.substring(0, 15)}...' : str;
            })
            .join(' | ');
        print('[ExcelImportService] Row $i: $preview');
      }

      // Find header row (usually first row)
      print('[ExcelImportService] Finding header row...');
      int headerRowIndex = _findHeaderRow(sheet);
      if (headerRowIndex == -1) {
        print('[ExcelImportService] Could not find header row');
        return ImportResult(
          success: false,
          error: 'Could not find header row in Excel file',
        );
      }
      print('[ExcelImportService] Header row found at index: $headerRowIndex');

      // Extract and map columns
      final headerRow = sheet.rows[headerRowIndex];
      print('[ExcelImportService] Mapping columns from header row...');
      final columnMapping = _mapColumns(headerRow);
      print('[ExcelImportService] Column mapping: $columnMapping');

      if (columnMapping.isEmpty) {
        print('[ExcelImportService] No columns could be mapped');
        return ImportResult(
          success: false,
          error:
              'Could not map any columns to app fields. Please check your Excel file has columns like: Name, Labour Card Expiry, Visa Expiry, Contact',
        );
      }

      // Detect sections and parse data
      print('[ExcelImportService] Detecting sections...');
      final sections = _detectSections(sheet, headerRowIndex, columnMapping);
      print(
        '[ExcelImportService] Found ${sections.companies.length} companies and ${sections.employees.length} employees',
      );

      // Ensure Google Sheets service is initialized
      await _ensureSheetsServiceInitialized();

      // Import items to Google Sheets
      int companiesImported = 0;
      int employeesImported = 0;
      int failedCount = 0;
      final errors = <String>[];

      for (final item in sections.companies) {
        try {
          await _sheetsService.addItem(item);
          companiesImported++;
        } catch (e) {
          failedCount++;
          errors.add('Company "${item.employeeCompany ?? item.no}": $e');
        }
      }

      for (final item in sections.employees) {
        try {
          await _sheetsService.addItem(item);
          employeesImported++;
        } catch (e) {
          failedCount++;
          errors.add('Employee "${item.employeeCompany ?? item.no}": $e');
        }
      }

      print(
        '[ExcelImportService] Import complete. Companies: $companiesImported, Employees: $employeesImported, Failed: $failedCount',
      );

      return ImportResult(
        success: true,
        companiesImported: companiesImported,
        employeesImported: employeesImported,
        failedCount: failedCount,
        errors: errors,
      );
    } catch (e, stackTrace) {
      print('[ExcelImportService] Exception during import: $e');
      print('[ExcelImportService] Stack trace: $stackTrace');
      return ImportResult(
        success: false,
        error: 'Error importing Excel file: $e',
      );
    }
  }

  /// Find the header row (row with most text cells that look like column headers)
  int _findHeaderRow(Sheet sheet) {
    int bestRow = -1;
    int maxTextCells = 0;
    int maxHeaderMatches = 0;

    // Check first 20 rows (in case there are section headers or empty rows)
    final maxRowsToCheck = sheet.rows.length < 20 ? sheet.rows.length : 20;

    print(
      '[ExcelImportService] Checking first $maxRowsToCheck rows for header...',
    );

    for (int i = 0; i < maxRowsToCheck; i++) {
      final row = sheet.rows[i];
      int textCellCount = 0;
      int headerMatches = 0;

      for (final cell in row) {
        if (cell != null && cell.value != null) {
          final value = cell.value.toString().trim().toLowerCase();
          // Check if it looks like a header (not a date, not a number)
          if (value.isNotEmpty &&
              !_isNumeric(value) &&
              !_isDate(value) &&
              !_isIgnoredField(value)) {
            textCellCount++;

            // Check if it matches known header patterns
            for (final patterns in _columnPatterns.values) {
              for (final pattern in patterns) {
                if (value.contains(pattern) || pattern.contains(value)) {
                  headerMatches++;
                  break;
                }
              }
            }
          }
        }
      }

      // Prefer rows with more header matches, then more text cells
      if (headerMatches > maxHeaderMatches ||
          (headerMatches == maxHeaderMatches && textCellCount > maxTextCells)) {
        maxHeaderMatches = headerMatches;
        maxTextCells = textCellCount;
        bestRow = i;
        print(
          '[ExcelImportService] Row $i is candidate header: $headerMatches header matches, $textCellCount text cells',
        );
      }
    }

    if (bestRow == -1) {
      print('[ExcelImportService] No header row found');
      return -1;
    }

    print(
      '[ExcelImportService] Selected row $bestRow as header (${maxHeaderMatches} header matches, ${maxTextCells} text cells)',
    );
    return bestRow;
  }

  /// Map Excel columns to app fields
  Map<String, int> _mapColumns(List<Data?> headerRow) {
    final mapping = <String, int>{};

    for (int i = 0; i < headerRow.length; i++) {
      final cell = headerRow[i];
      if (cell == null || cell.value == null) continue;

      final columnName = cell.value.toString().trim().toLowerCase();

      // Skip ignored fields
      if (_isIgnoredField(columnName)) {
        continue;
      }

      // Try to match against patterns
      for (final entry in _columnPatterns.entries) {
        final fieldName = entry.key;
        final patterns = entry.value;

        for (final pattern in patterns) {
          if (columnName.contains(pattern) || pattern.contains(columnName)) {
            if (!mapping.containsKey(fieldName)) {
              mapping[fieldName] = i;
              break;
            }
          }
        }
      }
    }

    return mapping;
  }

  /// Detect company and employee sections
  Sections _detectSections(
    Sheet sheet,
    int headerRowIndex,
    Map<String, int> columnMapping,
  ) {
    final companies = <ItemModel>[];
    final employees = <ItemModel>[];

    final startIndex = headerRowIndex + 1;
    final endIndex = sheet.rows.length - 1;
    print(
      '[ExcelImportService] Processing rows from index $startIndex to $endIndex (total rows: ${sheet.rows.length})',
    );

    if (startIndex >= sheet.rows.length) {
      print(
        '[ExcelImportService] WARNING: Start index $startIndex >= total rows ${sheet.rows.length}. No data rows to process.',
      );
      return Sections(companies: companies, employees: employees);
    }

    // Start from row after header
    for (int i = startIndex; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];

      // Debug: Print first few cells of row for first 10 data rows
      if (i < startIndex + 10) {
        final rowPreview = row
            .take(6)
            .map((cell) {
              if (cell == null || cell.value == null) return 'null';
              final str = cell.value.toString().trim();
              return str.length > 20 ? '${str.substring(0, 20)}...' : str;
            })
            .join(' | ');
        print('[ExcelImportService] Row $i preview: $rowPreview');
      }

      // Skip empty rows
      if (_isRowEmpty(row)) {
        if (i <= headerRowIndex + 5) {
          print('[ExcelImportService] Row $i is empty, skipping');
        }
        continue;
      }

      // Check if this row has a section header
      final sectionType = _detectSectionHeader(row);
      if (sectionType != null) {
        print(
          '[ExcelImportService] Row $i is a section header ($sectionType), skipping',
        );
        // This is a section header, skip it
        continue;
      }

      // Parse row data
      print('[ExcelImportService] Parsing row $i...');
      final item = _parseRow(row, columnMapping);
      if (item == null) {
        print('[ExcelImportService] Row $i parsed to null, skipping');
        continue;
      }

      print(
        '[ExcelImportService] Row $i parsed: name="${item.employeeCompany}", no="${item.no}", isCompany=${item.isCompany}, hasLabourCard=${item.labourCardExpiry != null}',
      );

      // Determine if company or employee
      // Priority: explicit isCompany flag > labour card presence > name analysis
      if (item.isCompany == true) {
        // Explicitly marked as company
        print(
          '[ExcelImportService] Row $i classified as COMPANY (explicit flag)',
        );
        companies.add(item);
      } else if (item.labourCardExpiry != null) {
        // Has labour card expiry, must be employee
        print(
          '[ExcelImportService] Row $i classified as EMPLOYEE (has labour card)',
        );
        employees.add(item);
      } else {
        // No explicit flag and no labour card - use name analysis
        final name = item.employeeCompany?.toLowerCase() ?? '';
        if (name.contains('company') ||
            name.contains('ltd') ||
            name.contains('inc') ||
            name.contains('corp') ||
            name.contains('llc')) {
          print(
            '[ExcelImportService] Row $i classified as COMPANY (name analysis)',
          );
          companies.add(item);
        } else {
          // Default to employee if unclear
          print('[ExcelImportService] Row $i classified as EMPLOYEE (default)');
          employees.add(item);
        }
      }
    }

    print(
      '[ExcelImportService] Section detection complete: ${companies.length} companies, ${employees.length} employees',
    );
    return Sections(companies: companies, employees: employees);
  }

  /// Parse a row into ItemModel
  ItemModel? _parseRow(List<Data?> row, Map<String, int> columnMapping) {
    try {
      String? no;
      String? employeeCompany;
      String? companyName;
      DateTime? labourCardExpiry;
      DateTime? visaExpiry;
      String? contact;
      bool? isCompany;

      // Extract values based on mapping
      if (columnMapping.containsKey('no')) {
        final index = columnMapping['no']!;
        if (index < row.length &&
            row[index] != null &&
            row[index]!.value != null) {
          final value = row[index]!.value.toString().trim();
          if (value.isNotEmpty) {
            no = value;
          }
        }
      }

      if (columnMapping.containsKey('employeeCompany')) {
        final index = columnMapping['employeeCompany']!;
        if (index < row.length &&
            row[index] != null &&
            row[index]!.value != null) {
          final value = row[index]!.value.toString().trim();
          if (value.isNotEmpty) {
            employeeCompany = value;
          }
        }
      }

      if (columnMapping.containsKey('companyName')) {
        final index = columnMapping['companyName']!;
        if (index < row.length &&
            row[index] != null &&
            row[index]!.value != null) {
          final value = row[index]!.value.toString().trim();
          if (value.isNotEmpty) {
            companyName = value;
          }
        }
      }

      if (columnMapping.containsKey('labourCardExpiry')) {
        final index = columnMapping['labourCardExpiry']!;
        if (index < row.length &&
            row[index] != null &&
            row[index]!.value != null) {
          final value = row[index]!.value;
          if (value != null && value.toString().trim().isNotEmpty) {
            labourCardExpiry = _parseDate(value);
          }
        }
      }

      if (columnMapping.containsKey('visaExpiry')) {
        final index = columnMapping['visaExpiry']!;
        if (index < row.length &&
            row[index] != null &&
            row[index]!.value != null) {
          final value = row[index]!.value;
          if (value != null && value.toString().trim().isNotEmpty) {
            visaExpiry = _parseDate(value);
          }
        }
      }

      if (columnMapping.containsKey('contact')) {
        final index = columnMapping['contact']!;
        if (index < row.length &&
            row[index] != null &&
            row[index]!.value != null) {
          final value = row[index]!.value.toString().trim();
          if (value.isNotEmpty) {
            contact = value;
          }
        }
      }

      // Check if row has any data - be more lenient
      // If we have at least a name or number, it's a valid row
      if (employeeCompany == null && no == null) {
        print('[ExcelImportService] Row has no name or number, skipping');
        return null;
      }

      // Try to detect if it's a company from the data
      // Look for "company" in name or absence of labour card
      if (employeeCompany != null) {
        final nameLower = employeeCompany.toLowerCase();
        if (nameLower.contains('company') ||
            nameLower.contains('ltd') ||
            nameLower.contains('inc') ||
            nameLower.contains('corp')) {
          isCompany = true;
        }
      }

      return ItemModel(
        no: no,
        employeeCompany: employeeCompany,
        companyName: companyName,
        labourCardExpiry: labourCardExpiry,
        visaExpiry: visaExpiry,
        contact: contact,
        isCompany: isCompany,
      );
    } catch (e) {
      print('[ExcelImportService] Error parsing row: $e');
      return null;
    }
  }

  /// Parse date from Excel cell value
  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;

    try {
      // Handle Excel date serial numbers
      if (value is num) {
        // Excel epoch: January 1, 1900 (but Excel incorrectly treats 1900 as leap year)
        // For dates after Feb 28, 1900, subtract 1 day
        final serialNumber = value.toDouble();
        final baseDate = DateTime(1899, 12, 30);
        final days = serialNumber.toInt();
        final parsedDate = baseDate.add(Duration(days: days));
        return DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
      }

      // Handle string dates
      final dateString = value.toString().trim();
      if (dateString.isEmpty) return null;

      // Try numeric string (serial number)
      final numericValue = double.tryParse(dateString);
      if (numericValue != null && numericValue > 0 && numericValue < 1000000) {
        final baseDate = DateTime(1899, 12, 30);
        final parsedDate = baseDate.add(Duration(days: numericValue.toInt()));
        return DateTime(parsedDate.year, parsedDate.month, parsedDate.day);
      }

      // Try common date formats
      final dateFormats = [
        'yyyy-MM-dd',
        'dd/MM/yyyy',
        'MM/dd/yyyy',
        'dd-MM-yyyy',
        'MM-dd-yyyy',
        'yyyy/MM/dd',
        'dd MMM yyyy',
        'MMM dd, yyyy',
      ];

      for (final format in dateFormats) {
        try {
          final parsed = DateFormat(format).parse(dateString);
          return DateTime(parsed.year, parsed.month, parsed.day);
        } catch (_) {
          continue;
        }
      }

      // Try DateTime.parse as last resort
      try {
        final parsed = DateTime.parse(dateString);
        return DateTime(parsed.year, parsed.month, parsed.day);
      } catch (_) {
        return null;
      }
    } catch (e) {
      print('[ExcelImportService] Error parsing date: $e');
      return null;
    }
  }

  /// Check if a field should be ignored
  bool _isIgnoredField(String fieldName) {
    final normalized = fieldName.toLowerCase().trim();
    for (final ignored in _ignoredFields) {
      if (normalized.contains(ignored) || ignored.contains(normalized)) {
        return true;
      }
    }
    return false;
  }

  /// Check if row is empty
  bool _isRowEmpty(List<Data?> row) {
    if (row.isEmpty) return true;

    for (final cell in row) {
      if (cell != null && cell.value != null) {
        final value = cell.value.toString().trim();
        // Don't consider empty strings, whitespace, or just dashes as data
        if (value.isNotEmpty && value != '-' && value != '—') {
          return false;
        }
      }
    }
    return true;
  }

  /// Detect section headers (e.g., "Company Section", "Employee Section")
  String? _detectSectionHeader(List<Data?> row) {
    for (final cell in row) {
      if (cell != null && cell.value != null) {
        final value = cell.value.toString().trim().toLowerCase();
        if (value.contains('company') &&
            (value.contains('section') || value.contains('companies'))) {
          return 'company';
        }
        if (value.contains('employee') &&
            (value.contains('section') || value.contains('employees'))) {
          return 'employee';
        }
      }
    }
    return null;
  }

  /// Check if string is numeric
  bool _isNumeric(String value) {
    return double.tryParse(value) != null;
  }

  /// Check if string looks like a date
  bool _isDate(String value) {
    // Simple heuristic: contains date-like separators
    return value.contains('/') || value.contains('-') || value.contains('.');
  }

  /// Ensure Google Sheets service is initialized
  Future<void> _ensureSheetsServiceInitialized() async {
    if (_sheetsService.isInitialized) {
      return;
    }

    // Try to initialize with credentials from storage if available
    final credentials = await _storage.read(key: 'service_account_credentials');
    bool initialized = false;

    if (credentials != null && credentials.isNotEmpty) {
      try {
        initialized = await _sheetsService.initializeWithCredentials(
          credentials,
        );
      } catch (e) {
        print(
          '[ExcelImportService] Error initializing with stored credentials: $e',
        );
      }
    }

    if (!initialized) {
      // Fallback to asset file initialization
      initialized = await _sheetsService.initialize();
      if (!initialized) {
        throw Exception('Failed to initialize Google Sheets service');
      }
    }

    // Initialize sheet with headers if needed
    await _sheetsService.initializeSheet();
  }
}

/// Result of Excel import operation
class ImportResult {
  final bool success;
  final String? error;
  final int companiesImported;
  final int employeesImported;
  final int failedCount;
  final List<String> errors;

  ImportResult({
    required this.success,
    this.error,
    this.companiesImported = 0,
    this.employeesImported = 0,
    this.failedCount = 0,
    this.errors = const [],
  });

  String get summary {
    if (!success) {
      return error ?? 'Import failed';
    }
    final parts = <String>[];
    if (companiesImported > 0) {
      parts.add('$companiesImported company(ies)');
    }
    if (employeesImported > 0) {
      parts.add('$employeesImported employee(s)');
    }
    if (failedCount > 0) {
      parts.add('$failedCount failed');
    }
    return parts.isEmpty ? 'No items imported' : parts.join(', ') + ' imported';
  }
}

/// Detected sections from Excel
class Sections {
  final List<ItemModel> companies;
  final List<ItemModel> employees;

  Sections({required this.companies, required this.employees});
}
