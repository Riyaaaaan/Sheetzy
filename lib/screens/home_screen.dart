import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/item_model.dart';
import '../services/google_sheets_service.dart';
import '../services/expiry_checker_service.dart';
import '../services/notification_service.dart';
import '../config/sheets_config.dart';
import '../utils/date_utils.dart' as app_date_utils;
import 'add_item_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GoogleSheetsService _sheetsService = GoogleSheetsService();
  final _storage = const FlutterSecureStorage();
  List<ItemModel> _items = [];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _loadItems();
    _initializeWorkmanager();
  }

  // Load configuration from secure storage
  Future<void> _loadConfig() async {
    try {
      print('[HomeScreen] Loading configuration from secure storage...');
      final spreadsheetId = await _storage.read(key: 'spreadsheet_id');
      final serviceAccountEmail = await _storage.read(
        key: 'service_account_email',
      );
      final credentials = await _storage.read(
        key: 'service_account_credentials',
      );

      if (spreadsheetId != null && spreadsheetId.isNotEmpty) {
        SheetsConfig.spreadsheetId = spreadsheetId;
        print('[HomeScreen] Loaded spreadsheet ID: $spreadsheetId');
      }

      // Set service account email from storage if available
      if (serviceAccountEmail != null && serviceAccountEmail.isNotEmpty) {
        SheetsConfig.serviceAccountEmail = serviceAccountEmail;
        print(
          '[HomeScreen] Loaded service account email from storage: $serviceAccountEmail',
        );
      } else if (credentials != null && credentials.isNotEmpty) {
        // Extract service account email from credentials if not explicitly set
        try {
          final credentialsMap =
              json.decode(credentials) as Map<String, dynamic>;
          if (credentialsMap.containsKey('client_email')) {
            SheetsConfig.serviceAccountEmail =
                credentialsMap['client_email'] as String;
            print(
              '[HomeScreen] Extracted service account email from credentials: ${SheetsConfig.serviceAccountEmail}',
            );
          }
        } catch (e) {
          print('[HomeScreen] Error extracting email from credentials: $e');
        }
      }

      print(
        '[HomeScreen] Configuration loaded. isConfigured: ${SheetsConfig.isConfigured}',
      );
    } catch (e) {
      print('[HomeScreen] Error loading configuration: $e');
    }
  }

  // Initialize workmanager after app startup to avoid platform channel errors
  Future<void> _initializeWorkmanager() async {
    try {
      await ExpiryCheckerService.initialize();
      await ExpiryCheckerService.registerPeriodicTask();
    } catch (e) {
      // Silently fail - background tasks are optional
      print('Failed to initialize workmanager: $e');
    }
  }

  Future<void> _loadItems() async {
    if (!SheetsConfig.isConfigured) {
      setState(() {
        _errorMessage = 'Please configure Google Sheets in Settings';
        _items = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Dispose and reinitialize service to ensure fresh connection
      _sheetsService.dispose();

      // Try to initialize with credentials from storage if available
      final credentials = await _storage.read(
        key: 'service_account_credentials',
      );
      bool initialized = false;

      if (credentials != null && credentials.isNotEmpty) {
        print('[HomeScreen] Initializing with stored credentials...');
        try {
          initialized = await _sheetsService.initializeWithCredentials(
            credentials,
          );
          if (initialized) {
            print(
              '[HomeScreen] Initialized successfully with stored credentials',
            );
          }
        } catch (e) {
          print('[HomeScreen] Error initializing with stored credentials: $e');
        }
      }

      if (!initialized) {
        print('[HomeScreen] Falling back to asset file initialization...');
        initialized = await _sheetsService.initialize();
        if (!initialized) {
          setState(() {
            _errorMessage = 'Failed to initialize Google Sheets service';
            _isLoading = false;
          });
          return;
        }
      }

      // Initialize sheet with headers if needed
      await _sheetsService.initializeSheet();

      final items = await _sheetsService.readItems();
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      print('[HomeScreen] Error loading items: $e');
      setState(() {
        _errorMessage = 'Error loading items: $e';
        _isLoading = false;
      });
    }
  }

  Color _getItemColor(ItemModel item) {
    // Check labour card expiry only for employees
    if (item.isCompany != true) {
      if (item.isExpired) {
        return Colors.red.shade100;
      } else if (item.isExpiringWithinDays(5)) {
        return Colors.orange.shade100;
      } else if (item.isExpiringWithinDays(15)) {
        return Colors.yellow.shade100;
      }
    }
    // Check visa expiry for all
    if (item.isVisaExpired) {
      return Colors.red.shade100;
    } else if (item.isVisaExpiringWithinDays(5)) {
      return Colors.orange.shade100;
    } else if (item.isVisaExpiringWithinDays(15)) {
      return Colors.yellow.shade100;
    }
    return Colors.white;
  }

  IconData _getItemIcon(ItemModel item) {
    final hasLabourCardIssue = item.isCompany != true && item.isExpired;
    if (hasLabourCardIssue || item.isVisaExpired) {
      return Icons.error;
    } else if ((item.isCompany != true && item.isExpiringWithinDays(5)) ||
        item.isVisaExpiringWithinDays(5)) {
      return Icons.warning;
    }
    return Icons.check_circle;
  }

  Color _getIconColor(ItemModel item) {
    final hasLabourCardIssue = item.isCompany != true && item.isExpired;
    if (hasLabourCardIssue || item.isVisaExpired) {
      return Colors.red;
    } else if ((item.isCompany != true && item.isExpiringWithinDays(5)) ||
        item.isVisaExpiringWithinDays(5)) {
      return Colors.orange;
    }
    return Colors.green;
  }

  // Trigger debug notifications manually
  Future<void> _triggerDebugNotifications() async {
    try {
      // Clear notification flags to ensure all eligible items get notifications
      final notificationService = NotificationService();
      await notificationService.clearNotificationFlags();

      // Show loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Checking for expiring items...'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // Manually trigger the expiry check
      await ExpiryCheckerService.checkExpiryDates();

      // Count how many items are eligible for notifications
      int eligibleItems = 0;
      try {
        if (_sheetsService.isInitialized) {
          final items = await _sheetsService.readItems();
          for (final item in items) {
            final hasLabourCardExpiring =
                item.isCompany != true &&
                item.isExpiringWithinDays(5) &&
                !item.isExpired;
            final hasVisaExpiring =
                item.isVisaExpiringWithinDays(5) && !item.isVisaExpired;
            if (hasLabourCardExpiring || hasVisaExpiring) {
              eligibleItems++;
            }
          }
        }
      } catch (e) {
        print('Error counting eligible items: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              eligibleItems > 0
                  ? 'Notification check completed. $eligibleItems item(s) should have received system notifications. Check your notification tray!'
                  : 'Notification check completed. No items expiring within 5 days found.',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error triggering notifications: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sheetzy - Expiry Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_active),
            tooltip: 'Trigger notifications (Debug)',
            onPressed: _triggerDebugNotifications,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
              // Reload config and items after returning from settings
              await _loadConfig();
              _loadItems();
            },
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const AddItemScreen()),
          );
          // Reload items after adding new item
          if (result == true) {
            _loadItems();
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadItems, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'No items found',
              style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the + button to add an item',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadItems,
      child: ListView.builder(
        itemCount: _items.length,
        padding: const EdgeInsets.all(8),
        itemBuilder: (context, index) {
          final item = _items[index];
          return Card(
            color: _getItemColor(item),
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: ListTile(
              leading: Icon(_getItemIcon(item), color: _getIconColor(item)),
              title: Text(
                item.employeeCompany ?? item.no ?? 'No name',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.no != null) ...[
                    const SizedBox(height: 4),
                    Text('No: ${item.no}'),
                  ],
                  if (item.isCompany != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Type: ${item.isCompany == true ? 'Company' : 'Employee'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  // Show labour card expiry only for employees
                  if (item.isCompany != true &&
                      item.labourCardExpiry != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Labour card expires: ${app_date_utils.DateUtils.formatDateDisplay(item.labourCardExpiry!)}',
                      style: TextStyle(
                        color: item.isExpired
                            ? Colors.red
                            : item.isExpiringWithinDays(5)
                            ? Colors.orange.shade700
                            : Colors.grey.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _buildDaysUntilExpiry(item, isVisa: false),
                  ],
                  if (item.visaExpiry != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Visa expires: ${app_date_utils.DateUtils.formatDateDisplay(item.visaExpiry!)}',
                      style: TextStyle(
                        color: item.isVisaExpired
                            ? Colors.red
                            : item.isVisaExpiringWithinDays(5)
                            ? Colors.orange.shade700
                            : Colors.grey.shade700,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _buildDaysUntilExpiry(item, isVisa: true),
                  ],
                  if (item.contact != null && item.contact!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Contact: ${item.contact}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ],
              ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }

  Widget _buildDaysUntilExpiry(ItemModel item, {required bool isVisa}) {
    final days = isVisa ? item.visaDaysUntilExpiry : item.daysUntilExpiry;
    if (days == null) return const SizedBox.shrink();

    final isExpired = isVisa ? item.isVisaExpired : item.isExpired;
    final expiryType = isVisa ? 'visa' : 'labour card';

    if (isExpired) {
      // Calculate days since expiry (positive number)
      final daysSinceExpiry = -days;
      return Text(
        '$expiryType expired $daysSinceExpiry day${daysSinceExpiry == 1 ? '' : 's'} ago',
        style: const TextStyle(
          color: Colors.red,
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
      );
    } else if (days == 0) {
      return Text(
        '$expiryType expires today!',
        style: const TextStyle(
          color: Colors.red,
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
      );
    } else if (days <= 5) {
      return Text(
        '$expiryType: $days day${days == 1 ? '' : 's'} until expiry',
        style: TextStyle(
          color: Colors.orange.shade700,
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
      );
    } else {
      return Text(
        '$expiryType: $days day${days == 1 ? '' : 's'} until expiry',
        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
      );
    }
  }
}
