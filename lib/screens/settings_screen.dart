import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/sheets_config.dart';
import '../services/google_sheets_service.dart';
import 'dart:convert';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _spreadsheetIdController = TextEditingController();
  final _serviceAccountEmailController = TextEditingController();
  final _credentialsController = TextEditingController();
  final _storage = const FlutterSecureStorage();
  bool _isLoading = false;
  bool _isTesting = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _spreadsheetIdController.dispose();
    _serviceAccountEmailController.dispose();
    _credentialsController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Load from secure storage
      final spreadsheetId = await _storage.read(key: 'spreadsheet_id');
      final serviceAccountEmail = await _storage.read(key: 'service_account_email');
      final credentials = await _storage.read(key: 'service_account_credentials');

      setState(() {
        _spreadsheetIdController.text = spreadsheetId ?? '';
        _serviceAccountEmailController.text = serviceAccountEmail ?? '';
        _credentialsController.text = credentials ?? '';
        
        // Update config
        SheetsConfig.spreadsheetId = spreadsheetId;
        SheetsConfig.serviceAccountEmail = serviceAccountEmail;
      });
    } catch (e) {
      print('Error loading settings: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _testResult = null;
    });

    try {
      // Validate JSON credentials if provided
      if (_credentialsController.text.trim().isNotEmpty) {
        try {
          json.decode(_credentialsController.text.trim());
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Invalid JSON credentials: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
          setState(() {
            _isLoading = false;
          });
          return;
        }
      }

      // Save to secure storage
      await _storage.write(
        key: 'spreadsheet_id',
        value: _spreadsheetIdController.text.trim(),
      );
      await _storage.write(
        key: 'service_account_email',
        value: _serviceAccountEmailController.text.trim(),
      );
      
      if (_credentialsController.text.trim().isNotEmpty) {
        await _storage.write(
          key: 'service_account_credentials',
          value: _credentialsController.text.trim(),
        );
      }

      // Update config
      SheetsConfig.spreadsheetId = _spreadsheetIdController.text.trim();
      SheetsConfig.serviceAccountEmail = _serviceAccountEmailController.text.trim();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Settings saved successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving settings: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Validate spreadsheet ID format
    final spreadsheetId = _spreadsheetIdController.text.trim();
    if (spreadsheetId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a spreadsheet ID'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Validate credentials JSON if provided
    if (_credentialsController.text.trim().isNotEmpty) {
      try {
        json.decode(_credentialsController.text.trim());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Invalid JSON credentials: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    try {
      print('[SettingsScreen] Starting connection test...');
      
      // Save settings first
      await _saveSettings();
      print('[SettingsScreen] Settings saved');

      // Initialize Google Sheets service
      final sheetsService = GoogleSheetsService();
      
      // Dispose any existing instance
      sheetsService.dispose();
      print('[SettingsScreen] Service disposed');
      
      // Try to initialize with credentials from storage if available
      final credentials = await _storage.read(key: 'service_account_credentials');
      bool initialized = false;
      String? initError;
      
      if (credentials != null && credentials.isNotEmpty) {
        print('[SettingsScreen] Found credentials in storage, initializing...');
        try {
          initialized = await sheetsService.initializeWithCredentials(credentials);
          if (initialized) {
            print('[SettingsScreen] Initialized successfully with stored credentials');
          } else {
            print('[SettingsScreen] Initialization returned false');
            initError = 'Failed to initialize with provided credentials';
          }
        } catch (e, stackTrace) {
          print('[SettingsScreen] Error initializing with stored credentials: $e');
          print('[SettingsScreen] Stack trace: $stackTrace');
          initError = e.toString();
        }
      } else {
        print('[SettingsScreen] No credentials in storage');
      }
      
      if (!initialized) {
        // Fallback to asset file
        print('[SettingsScreen] Trying to initialize from asset file...');
        try {
          initialized = await sheetsService.initialize();
          if (initialized) {
            print('[SettingsScreen] Initialized successfully from asset file');
          } else {
            print('[SettingsScreen] Initialization from asset file returned false');
            initError = initError ?? 'Failed to initialize from asset file';
          }
        } catch (e, stackTrace) {
          print('[SettingsScreen] Error initializing from asset file: $e');
          print('[SettingsScreen] Stack trace: $stackTrace');
          initError = initError ?? e.toString();
        }
      }

      if (!initialized) {
        final errorMsg = initError ?? 'Failed to initialize Google Sheets service. Please check your credentials.';
        print('[SettingsScreen] Initialization failed: $errorMsg');
        setState(() {
          _testResult = errorMsg;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMsg),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        setState(() {
          _isTesting = false;
        });
        return;
      }

      // Test connection - this may throw detailed exceptions
      print('[SettingsScreen] Testing connection...');
      try {
        final connected = await sheetsService.testConnection();
        
        if (connected) {
          print('[SettingsScreen] Connection test successful!');
          setState(() {
            _testResult = 'Connection successful! Spreadsheet is accessible.';
          });

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Connection successful! Spreadsheet is accessible.'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 4),
              ),
            );
          }
        } else {
          print('[SettingsScreen] Connection test returned false');
          setState(() {
            _testResult = 'Connection failed. Please check your settings.';
          });

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Connection failed. Please check your settings.'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 4),
              ),
            );
          }
        }
      } catch (e, stackTrace) {
        // testConnection throws detailed exceptions
        print('[SettingsScreen] Connection test threw exception: $e');
        print('[SettingsScreen] Stack trace: $stackTrace');
        final errorMessage = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _testResult = errorMessage;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 8),
            ),
          );
        }
      }
    } catch (e, stackTrace) {
      print('[SettingsScreen] Unexpected error: $e');
      print('[SettingsScreen] Stack trace: $stackTrace');
      final errorMessage = 'Unexpected error: ${e.toString()}';
      setState(() {
        _testResult = errorMessage;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboardData?.text != null) {
      setState(() {
        _credentialsController.text = clipboardData!.text!;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: _isLoading && _spreadsheetIdController.text.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Google Sheets Configuration',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Configure your Google Sheets connection settings below.',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _spreadsheetIdController,
                    decoration: const InputDecoration(
                      labelText: 'Spreadsheet ID *',
                      hintText: 'Enter your Google Sheets spreadsheet ID',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.table_chart),
                      helperText: 'Found in the URL: /spreadsheets/d/SPREADSHEET_ID/edit',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a spreadsheet ID';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _serviceAccountEmailController,
                    decoration: const InputDecoration(
                      labelText: 'Service Account Email',
                      hintText: 'Enter service account email (optional)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email),
                      helperText: 'Optional: Service account email for reference',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _credentialsController,
                    decoration: InputDecoration(
                      labelText: 'Service Account Credentials (JSON)',
                      hintText: 'Paste service account JSON credentials',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.key),
                      helperText: 'Optional: Paste JSON credentials if not using asset file',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.paste),
                        onPressed: _pasteFromClipboard,
                        tooltip: 'Paste from clipboard',
                      ),
                    ),
                    maxLines: 8,
                    textInputAction: TextInputAction.newline,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Note: If credentials are not provided here, the app will use the service_account_credentials.json file from assets.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_testResult != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: _testResult!.contains('successful')
                            ? Colors.green.shade50
                            : Colors.red.shade50,
                        border: Border.all(
                          color: _testResult!.contains('successful')
                              ? Colors.green
                              : Colors.red,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _testResult!,
                        style: TextStyle(
                          color: _testResult!.contains('successful')
                              ? Colors.green.shade900
                              : Colors.red.shade900,
                        ),
                      ),
                    ),
                  ElevatedButton.icon(
                    onPressed: _isTesting ? null : _testConnection,
                    icon: _isTesting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle),
                    label: Text(_isTesting ? 'Testing...' : 'Test Connection'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : _saveSettings,
                    icon: const Icon(Icons.save),
                    label: Text(_isLoading ? 'Saving...' : 'Save Settings'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

