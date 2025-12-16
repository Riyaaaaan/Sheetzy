class SheetsConfig {
  // These will be loaded from secure storage or set via settings
  static String? spreadsheetId;
  static String? serviceAccountEmail;
  static String sheetName = 'Sheet1'; // Default sheet name
  static String range = 'A:F'; // Default range for data

  // Headers for the sheet
  static List<String> get headers => [
    'No',
    'Employee/Company',
    'Labour card expiry',
    'Visa expiry',
    'contact',
    'Company/Employee',
  ];

  // Validate configuration
  // Only requires spreadsheetId - serviceAccountEmail is optional (can be extracted from credentials)
  static bool get isConfigured {
    return spreadsheetId != null && spreadsheetId!.isNotEmpty;
  }

  // Clear configuration
  static void clear() {
    spreadsheetId = null;
    serviceAccountEmail = null;
  }
}
