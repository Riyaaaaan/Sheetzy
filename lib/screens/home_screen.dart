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

enum SortMode { none, visaExpiry, labourCardExpiry }

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
  SortMode _sortMode = SortMode.none;

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

  Color _getStatusColor(ItemModel item) {
    // Check labour card expiry only for employees
    if (item.isCompany != true) {
      if (item.isExpired) {
        return const Color(0xFFEF4444); // Red
      } else if (item.isExpiringWithinDays(5)) {
        return const Color(0xFFF59E0B); // Orange
      } else if (item.isExpiringWithinDays(15)) {
        return const Color(0xFFFBBF24); // Yellow
      }
    }
    // Check visa expiry for all
    if (item.isVisaExpired) {
      return const Color(0xFFEF4444);
    } else if (item.isVisaExpiringWithinDays(5)) {
      return const Color(0xFFF59E0B);
    } else if (item.isVisaExpiringWithinDays(15)) {
      return const Color(0xFFFBBF24);
    }
    return const Color(0xFF10B981); // Green
  }

  IconData _getStatusIcon(ItemModel item) {
    final hasLabourCardIssue = item.isCompany != true && item.isExpired;
    if (hasLabourCardIssue || item.isVisaExpired) {
      return Icons.error_outline_rounded;
    } else if ((item.isCompany != true && item.isExpiringWithinDays(5)) ||
        item.isVisaExpiringWithinDays(5)) {
      return Icons.warning_amber_rounded;
    }
    return Icons.check_circle_outline_rounded;
  }

  List<ItemModel> _sortItems(List<ItemModel> items, SortMode mode) {
    if (mode == SortMode.none) {
      return items;
    }

    final sorted = List<ItemModel>.from(items);
    sorted.sort((a, b) {
      DateTime? dateA, dateB;
      if (mode == SortMode.visaExpiry) {
        dateA = a.visaExpiry;
        dateB = b.visaExpiry;
      } else if (mode == SortMode.labourCardExpiry) {
        dateA = a.labourCardExpiry;
        dateB = b.labourCardExpiry;
      }

      // Handle nulls - put them at the end
      if (dateA == null && dateB == null) return 0;
      if (dateA == null) return 1;
      if (dateB == null) return -1;

      // Ascending order (earliest dates first - items expiring soonest appear first)
      return dateA.compareTo(dateB);
    });
    return sorted;
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
            // Check all notification intervals (10, 5, 3, 1 days)
            bool hasLabourCardExpiring = false;
            bool hasVisaExpiring = false;

            if (item.isCompany != true && !item.isExpired) {
              for (final interval in [10, 5, 3, 1]) {
                if (item.isExpiringWithinDays(interval)) {
                  hasLabourCardExpiring = true;
                  break;
                }
              }
            }

            if (!item.isVisaExpired) {
              for (final interval in [10, 5, 3, 1]) {
                if (item.isVisaExpiringWithinDays(interval)) {
                  hasVisaExpiring = true;
                  break;
                }
              }
            }

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
                  : 'Notification check completed. No items expiring within 10, 5, 3, or 1 days found.',
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
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        title: const Text(
          'Sheetzy',
          style: TextStyle(
            color: Color(0xFF1E293B),
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        actions: [
          PopupMenuButton<SortMode>(
            icon: const Icon(Icons.sort_outlined),
            color: const Color(0xFF64748B),
            tooltip: 'Sort items',
            onSelected: (SortMode mode) {
              setState(() {
                _sortMode = mode;
              });
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<SortMode>>[
              PopupMenuItem<SortMode>(
                value: SortMode.none,
                child: Row(
                  children: [
                    Icon(
                      _sortMode == SortMode.none
                          ? Icons.check
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: _sortMode == SortMode.none
                          ? const Color(0xFF3B82F6)
                          : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    const Text('No Sort'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<SortMode>(
                value: SortMode.visaExpiry,
                child: Row(
                  children: [
                    Icon(
                      _sortMode == SortMode.visaExpiry
                          ? Icons.check
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: _sortMode == SortMode.visaExpiry
                          ? const Color(0xFF3B82F6)
                          : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    const Text('Sort by Visa Expiry'),
                  ],
                ),
              ),
              PopupMenuItem<SortMode>(
                value: SortMode.labourCardExpiry,
                child: Row(
                  children: [
                    Icon(
                      _sortMode == SortMode.labourCardExpiry
                          ? Icons.check
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: _sortMode == SortMode.labourCardExpiry
                          ? const Color(0xFF3B82F6)
                          : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    const Text('Sort by Labour Card Expiry'),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.notifications_active_outlined),
            color: const Color(0xFF64748B),
            tooltip: 'Trigger notifications (Debug)',
            onPressed: _triggerDebugNotifications,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            color: const Color(0xFF64748B),
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
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
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
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Item'),
        backgroundColor: const Color(0xFF3B82F6),
        elevation: 2,
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
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 48,
                  color: Colors.red.shade400,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loadItems,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Retry'),
              ),
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
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.inbox_outlined,
                size: 56,
                color: Colors.grey.shade400,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No items found',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Color(0xFF475569),
              ),
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

    final sortedItems = _sortItems(_items, _sortMode);

    return RefreshIndicator(
      onRefresh: _loadItems,
      child: ListView.builder(
        itemCount: sortedItems.length,
        padding: const EdgeInsets.all(16),
        itemBuilder: (context, index) {
          final item = sortedItems[index];
          return _buildModernCard(item);
        },
      ),
    );
  }

  Widget _buildModernCard(ItemModel item) {
    final statusColor = _getStatusColor(item);
    final statusIcon = _getStatusIcon(item);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            // Handle card tap if needed
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  children: [
                    // Status indicator
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(statusIcon, color: statusColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    // Name and type
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.employeeCompany ?? item.no ?? 'No name',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                          if (item.companyName != null &&
                              item.companyName!.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              item.companyName!,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                          if (item.no != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              item.no!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Type badge
                    if (item.isCompany != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: item.isCompany == true
                              ? const Color(0xFF3B82F6).withOpacity(0.1)
                              : const Color(0xFF8B5CF6).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          item.isCompany == true ? 'Company' : 'Employee',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: item.isCompany == true
                                ? const Color(0xFF3B82F6)
                                : const Color(0xFF8B5CF6),
                          ),
                        ),
                      ),
                  ],
                ),

                // Expiry information
                const SizedBox(height: 16),

                // Labour card expiry (only for employees)
                if (item.isCompany != true &&
                    item.labourCardExpiry != null) ...[
                  _buildExpiryRow(
                    icon: Icons.badge_outlined,
                    label: 'Labour Card',
                    date: app_date_utils.DateUtils.formatDateDisplay(
                      item.labourCardExpiry!,
                    ),
                    daysInfo: _getDaysText(item, isVisa: false),
                    color: item.isExpired
                        ? const Color(0xFFEF4444)
                        : item.isExpiringWithinDays(5)
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF64748B),
                  ),
                  const SizedBox(height: 12),
                ],

                // Visa expiry
                if (item.visaExpiry != null) ...[
                  _buildExpiryRow(
                    icon: Icons.travel_explore_outlined,
                    label: 'Visa',
                    date: app_date_utils.DateUtils.formatDateDisplay(
                      item.visaExpiry!,
                    ),
                    daysInfo: _getDaysText(item, isVisa: true),
                    color: item.isVisaExpired
                        ? const Color(0xFFEF4444)
                        : item.isVisaExpiringWithinDays(5)
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF64748B),
                  ),
                  const SizedBox(height: 12),
                ],

                // Contact info
                if (item.contact != null && item.contact!.isNotEmpty)
                  Row(
                    children: [
                      Icon(
                        Icons.phone_outlined,
                        size: 16,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.contact!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpiryRow({
    required IconData icon,
    required String label,
    required String date,
    required String daysInfo,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                date,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            daysInfo,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  String _getDaysText(ItemModel item, {required bool isVisa}) {
    final days = isVisa ? item.visaDaysUntilExpiry : item.daysUntilExpiry;
    if (days == null) return '';

    final isExpired = isVisa ? item.isVisaExpired : item.isExpired;

    if (isExpired) {
      final daysSinceExpiry = -days;
      return 'Expired ${daysSinceExpiry}d ago';
    } else if (days == 0) {
      return 'Expires today';
    } else if (days == 1) {
      return '1 day left';
    } else {
      return '$days days left';
    }
  }
}
