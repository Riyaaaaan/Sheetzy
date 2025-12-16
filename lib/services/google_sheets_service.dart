import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:gsheets/gsheets.dart';
import '../config/sheets_config.dart';
import '../models/item_model.dart';

class GoogleSheetsService {
  static GoogleSheetsService? _instance;
  GSheets? _gsheets;
  Spreadsheet? _spreadsheet;
  Worksheet? _worksheet;
  bool _initialized = false;

  GoogleSheetsService._();

  factory GoogleSheetsService() {
    _instance ??= GoogleSheetsService._();
    return _instance!;
  }

  // Initialize with service account credentials from assets
  Future<bool> initialize() async {
    try {
      print('[GoogleSheetsService] Starting initialization from assets...');

      // Load service account credentials from assets
      final credentialsJson = await rootBundle.loadString(
        'assets/service_account_credentials.json',
      );
      print('[GoogleSheetsService] Credentials loaded from assets');

      final credentials = json.decode(credentialsJson) as Map<String, dynamic>;

      // Extract and store service account email
      _extractAndStoreServiceAccountEmail(credentials);

      // Validate credentials
      _validateCredentials(credentials);

      print('[GoogleSheetsService] Initializing GSheets...');
      // Initialize GSheets with service account credentials
      _gsheets = GSheets(credentials);
      _initialized = true;
      print('[GoogleSheetsService] GSheets initialized successfully');

      // Don't load spreadsheet during initialization - do it on demand
      // This prevents errors if spreadsheet ID is not yet configured

      return true;
    } catch (e, stackTrace) {
      print('[GoogleSheetsService] Error initializing from assets: $e');
      print('[GoogleSheetsService] Stack trace: $stackTrace');
      _initialized = false;
      return false;
    }
  }

  // Initialize with credentials from secure storage (alternative method)
  Future<bool> initializeWithCredentials(String credentialsJson) async {
    try {
      print(
        '[GoogleSheetsService] Starting initialization with provided credentials...',
      );

      // Parse credentials - credentialsJson is always a String here
      final credentials = json.decode(credentialsJson) as Map<String, dynamic>;

      print('[GoogleSheetsService] Credentials parsed successfully');

      // Extract and store service account email
      _extractAndStoreServiceAccountEmail(credentials);

      // Validate credentials
      _validateCredentials(credentials);

      print('[GoogleSheetsService] Initializing GSheets...');
      // Initialize GSheets with service account credentials
      _gsheets = GSheets(credentials);
      _initialized = true;
      print('[GoogleSheetsService] GSheets initialized successfully');

      // Don't load spreadsheet during initialization - do it on demand

      return true;
    } catch (e, stackTrace) {
      print('[GoogleSheetsService] Error initializing with credentials: $e');
      print('[GoogleSheetsService] Stack trace: $stackTrace');
      _initialized = false;
      return false;
    }
  }

  // Load spreadsheet and worksheet
  Future<void> _loadSpreadsheet() async {
    if (!_initialized ||
        !SheetsConfig.isConfigured ||
        SheetsConfig.spreadsheetId == null) {
      throw Exception(
        'Service not initialized or spreadsheet ID not configured',
      );
    }

    try {
      print(
        '[GoogleSheetsService] Loading spreadsheet: ${SheetsConfig.spreadsheetId}',
      );
      _spreadsheet = await _gsheets!.spreadsheet(SheetsConfig.spreadsheetId!);
      print('[GoogleSheetsService] Spreadsheet loaded successfully');

      // Get or create worksheet
      try {
        print(
          '[GoogleSheetsService] Looking for worksheet: ${SheetsConfig.sheetName}',
        );
        _worksheet = _spreadsheet!.worksheetByTitle(SheetsConfig.sheetName);
        if (_worksheet == null) {
          print('[GoogleSheetsService] Worksheet not found, creating new one');
          // Create worksheet if it doesn't exist
          _worksheet = await _spreadsheet!.addWorksheet(SheetsConfig.sheetName);
          // Add headers
          await _worksheet!.values.insertRow(1, SheetsConfig.headers);
          print('[GoogleSheetsService] Worksheet created with headers');
        } else {
          print('[GoogleSheetsService] Worksheet found');
        }
      } catch (e) {
        print(
          '[GoogleSheetsService] Error accessing worksheet, creating new one: $e',
        );
        // If worksheet doesn't exist, create it
        _worksheet = await _spreadsheet!.addWorksheet(SheetsConfig.sheetName);
        // Add headers
        await _worksheet!.values.insertRow(1, SheetsConfig.headers);
        print('[GoogleSheetsService] Worksheet created with headers');
      }
    } catch (e, stackTrace) {
      print('[GoogleSheetsService] Error loading spreadsheet: $e');
      print('[GoogleSheetsService] Stack trace: $stackTrace');
      rethrow;
    }
  }

  // Check if service is initialized
  bool get isInitialized => _initialized && _gsheets != null;

  // Ensure spreadsheet is loaded
  Future<void> _ensureSpreadsheetLoaded() async {
    if (_spreadsheet == null || _worksheet == null) {
      await _loadSpreadsheet();
    }
  }

  // Read all items from Google Sheets
  Future<List<ItemModel>> readItems() async {
    if (!isInitialized || !SheetsConfig.isConfigured) {
      throw Exception('Service not initialized or not configured');
    }

    try {
      await _ensureSpreadsheetLoaded();

      // Read all rows from the worksheet
      final rows = await _worksheet!.values.allRows();

      if (rows.isEmpty) {
        return [];
      }

      // Skip header row (first row)
      final items = <ItemModel>[];
      for (int i = 1; i < rows.length; i++) {
        try {
          final row = rows[i];
          // Ensure row has at least 6 columns, pad with empty strings if needed
          while (row.length < 6) {
            row.add('');
          }
          final item = ItemModel.fromSheetRow(row, i - 1);
          // Only add items that have at least one field filled (no or employeeCompany)
          if ((item.no != null && item.no!.isNotEmpty) ||
              (item.employeeCompany != null &&
                  item.employeeCompany!.isNotEmpty)) {
            items.add(item);
          }
        } catch (e) {
          print('Error parsing row $i: $e');
          continue;
        }
      }

      return items;
    } catch (e) {
      print('Error reading items from Google Sheets: $e');
      rethrow;
    }
  }

  // Get next auto-increment number based on highest existing number
  Future<int> getNextAutoIncrementNumber() async {
    if (!isInitialized || !SheetsConfig.isConfigured) {
      throw Exception('Service not initialized or not configured');
    }

    try {
      await _ensureSpreadsheetLoaded();

      // Read all existing items
      final items = await readItems();

      if (items.isEmpty) {
        return 1;
      }

      // Find the maximum numeric value in the "No" column
      int maxNumber = 0;
      for (final item in items) {
        if (item.no != null && item.no!.isNotEmpty) {
          final number = int.tryParse(item.no!);
          if (number != null && number > maxNumber) {
            maxNumber = number;
          }
        }
      }

      return maxNumber + 1;
    } catch (e) {
      print('Error getting next auto-increment number: $e');
      // Return 1 as fallback if there's an error
      return 1;
    }
  }

  // Add a new item to Google Sheets
  Future<bool> addItem(ItemModel item) async {
    if (!isInitialized || !SheetsConfig.isConfigured) {
      throw Exception('Service not initialized or not configured');
    }

    try {
      await _ensureSpreadsheetLoaded();

      // Ensure item has a number (auto-increment if missing)
      ItemModel itemToAdd = item;
      if (item.no == null || item.no!.isEmpty) {
        final nextNumber = await getNextAutoIncrementNumber();
        itemToAdd = item.copyWith(no: nextNumber.toString());
      }

      // Add row to worksheet using appendRow
      await _worksheet!.values.appendRow(itemToAdd.toSheetRow());

      return true;
    } catch (e) {
      print('Error adding item to Google Sheets: $e');
      rethrow;
    }
  }

  // Initialize sheet with headers if it doesn't exist
  Future<bool> initializeSheet() async {
    if (!isInitialized || !SheetsConfig.isConfigured) {
      throw Exception('Service not initialized or not configured');
    }

    try {
      await _ensureSpreadsheetLoaded();

      // Check if headers exist
      final rows = await _worksheet!.values.allRows();

      if (rows.isEmpty ||
          rows[0].isEmpty ||
          rows[0][0] != SheetsConfig.headers[0]) {
        // Headers don't exist or are different, update them
        if (rows.isEmpty) {
          await _worksheet!.values.insertRow(1, SheetsConfig.headers);
        } else {
          await _worksheet!.values.insertRow(1, SheetsConfig.headers);
        }
      }

      return true;
    } catch (e) {
      print('Error initializing sheet: $e');
      return false;
    }
  }

  // Test connection to Google Sheets
  Future<bool> testConnection() async {
    print('[GoogleSheetsService] Testing connection...');

    if (!isInitialized) {
      print('[GoogleSheetsService] Service not initialized');
      throw Exception(
        'Service not initialized. Please check your credentials.',
      );
    }

    if (!SheetsConfig.isConfigured) {
      print('[GoogleSheetsService] Config not set');
      throw Exception('Configuration not set. Please enter spreadsheet ID.');
    }

    try {
      if (SheetsConfig.spreadsheetId == null ||
          SheetsConfig.spreadsheetId!.isEmpty) {
        print('[GoogleSheetsService] Spreadsheet ID is empty');
        throw Exception('Spreadsheet ID is required.');
      }

      print(
        '[GoogleSheetsService] Attempting to access spreadsheet: ${SheetsConfig.spreadsheetId}',
      );

      // Try to access the spreadsheet
      // If we can access it without error, connection is successful
      await _gsheets!.spreadsheet(SheetsConfig.spreadsheetId!);
      print('[GoogleSheetsService] Successfully accessed spreadsheet');
      return true;
    } catch (e, stackTrace) {
      print('[GoogleSheetsService] Error testing connection: $e');
      print('[GoogleSheetsService] Error type: ${e.runtimeType}');
      print('[GoogleSheetsService] Stack trace: $stackTrace');

      // Handle GSheetsException specifically
      if (e is GSheetsException) {
        final errorMessage = e.cause.toLowerCase();
        print('[GoogleSheetsService] GSheetsException: $errorMessage');

        if (errorMessage.contains('403') ||
            errorMessage.contains('permission') ||
            errorMessage.contains('denied')) {
          throw Exception(
            'Permission denied. Please share the spreadsheet with the service account email: ${_getServiceAccountEmail()}\n\nTo fix: Open your Google Sheet, click Share, and add the email above with Editor access.',
          );
        } else if (errorMessage.contains('404') ||
            errorMessage.contains('not found')) {
          throw Exception(
            'Spreadsheet not found. Please check the spreadsheet ID.\n\nMake sure the ID is correct. You can find it in the URL: https://docs.google.com/spreadsheets/d/SPREADSHEET_ID/edit',
          );
        } else if (errorMessage.contains('401') ||
            errorMessage.contains('unauthorized') ||
            errorMessage.contains('unauthenticated')) {
          throw Exception(
            'Authentication failed. Please check your service account credentials.\n\nMake sure the JSON credentials are valid and the service account has the Google Sheets API enabled.',
          );
        } else {
          throw Exception('Connection failed: ${e.cause}');
        }
      }

      // Handle generic exceptions
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('403') ||
          errorString.contains('permission') ||
          errorString.contains('denied')) {
        throw Exception(
          'Permission denied. Please share the spreadsheet with the service account email: ${_getServiceAccountEmail()}\n\nTo fix: Open your Google Sheet, click Share, and add the email above with Editor access.',
        );
      } else if (errorString.contains('404') ||
          errorString.contains('not found')) {
        throw Exception(
          'Spreadsheet not found. Please check the spreadsheet ID.\n\nMake sure the ID is correct. You can find it in the URL: https://docs.google.com/spreadsheets/d/SPREADSHEET_ID/edit',
        );
      } else if (errorString.contains('401') ||
          errorString.contains('unauthorized') ||
          errorString.contains('unauthenticated')) {
        throw Exception(
          'Authentication failed. Please check your service account credentials.\n\nMake sure the JSON credentials are valid and the service account has the Google Sheets API enabled.',
        );
      }

      // Re-throw with more context
      throw Exception('Connection failed: $e');
    }
  }

  // Extract and store service account email from credentials
  void _extractAndStoreServiceAccountEmail(Map<String, dynamic> credentials) {
    try {
      if (credentials.containsKey('client_email')) {
        final email = credentials['client_email'] as String;
        SheetsConfig.serviceAccountEmail = email;
        print('[GoogleSheetsService] Extracted service account email: $email');
      } else {
        print(
          '[GoogleSheetsService] Warning: client_email not found in credentials',
        );
      }
    } catch (e) {
      print('[GoogleSheetsService] Error extracting service account email: $e');
    }
  }

  // Validate credentials structure
  void _validateCredentials(Map<String, dynamic> credentials) {
    final requiredFields = [
      'type',
      'project_id',
      'private_key_id',
      'private_key',
      'client_email',
    ];
    final missingFields = <String>[];

    for (final field in requiredFields) {
      if (!credentials.containsKey(field) || credentials[field] == null) {
        missingFields.add(field);
      }
    }

    if (missingFields.isNotEmpty) {
      throw Exception(
        'Missing required credential fields: ${missingFields.join(", ")}',
      );
    }

    if (credentials['type'] != 'service_account') {
      throw Exception('Invalid credential type. Expected "service_account"');
    }

    print('[GoogleSheetsService] Credentials validation passed');
  }

  // Get service account email from credentials (helper method)
  String _getServiceAccountEmail() {
    try {
      // Try to get from config first
      if (SheetsConfig.serviceAccountEmail != null &&
          SheetsConfig.serviceAccountEmail!.isNotEmpty) {
        return SheetsConfig.serviceAccountEmail!;
      }
      // Otherwise return a generic message
      return 'your-service-account@your-project.iam.gserviceaccount.com';
    } catch (e) {
      return 'your-service-account@your-project.iam.gserviceaccount.com';
    }
  }

  // Dispose resources
  void dispose() {
    _worksheet = null;
    _spreadsheet = null;
    _gsheets = null;
    _initialized = false;
  }
}
