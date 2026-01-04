import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/item_model.dart';
import '../services/google_sheets_service.dart';
import '../services/expiry_checker_service.dart';
import '../services/notification_service.dart';
import '../config/sheets_config.dart';
import '../utils/date_utils.dart' as app_date_utils;
import 'add_item_screen.dart';
import 'settings_screen.dart';

enum SortMode { none, visaExpiry, labourCardExpiry }

enum FilterType { all, visa, labourCard }

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
  FilterType _filterType = FilterType.all;

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

  List<ItemModel> _filterAndSortItems(List<ItemModel> items) {
    // First, filter items based on selected filter type
    List<ItemModel> filteredItems = items;
    if (_filterType == FilterType.visa) {
      filteredItems = items.where((item) => item.visaExpiry != null).toList();
    } else if (_filterType == FilterType.labourCard) {
      filteredItems = items
          .where((item) => item.labourCardExpiry != null)
          .toList();
    }

    // Then, separate items into categories
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final List<ItemModel> expiredMore10Days = [];
    final List<ItemModel> expiredLess10Days = [];
    final List<ItemModel> notExpired = [];

    for (final item in filteredItems) {
      // Determine if item is expired based on filter type
      bool isExpired = false;
      int? daysExpired;

      if (_filterType == FilterType.visa) {
        // For visa filter, only check visa expiry
        if (item.visaExpiry != null) {
          final expiry = DateTime(
            item.visaExpiry!.year,
            item.visaExpiry!.month,
            item.visaExpiry!.day,
          );
          if (expiry.isBefore(today)) {
            isExpired = true;
            daysExpired = today.difference(expiry).inDays;
          }
        }
      } else if (_filterType == FilterType.labourCard) {
        // For labour card filter, only check labour card expiry
        if (item.labourCardExpiry != null) {
          final expiry = DateTime(
            item.labourCardExpiry!.year,
            item.labourCardExpiry!.month,
            item.labourCardExpiry!.day,
          );
          if (expiry.isBefore(today)) {
            isExpired = true;
            daysExpired = today.difference(expiry).inDays;
          }
        }
      } else {
        // For 'all' filter, check both
        if (item.isVisaExpired || (item.isCompany != true && item.isExpired)) {
          isExpired = true;
          // Calculate which expiry is more severe
          int? visaDays;
          int? labourDays;
          if (item.visaExpiry != null && item.isVisaExpired) {
            final expiry = DateTime(
              item.visaExpiry!.year,
              item.visaExpiry!.month,
              item.visaExpiry!.day,
            );
            visaDays = today.difference(expiry).inDays;
          }
          if (item.labourCardExpiry != null &&
              item.isCompany != true &&
              item.isExpired) {
            final expiry = DateTime(
              item.labourCardExpiry!.year,
              item.labourCardExpiry!.month,
              item.labourCardExpiry!.day,
            );
            labourDays = today.difference(expiry).inDays;
          }
          // Use the larger expiry duration
          if (visaDays != null && labourDays != null) {
            daysExpired = visaDays > labourDays ? visaDays : labourDays;
          } else {
            daysExpired = visaDays ?? labourDays;
          }
        }
      }

      if (isExpired) {
        if (daysExpired != null && daysExpired > 10) {
          expiredMore10Days.add(item);
        } else {
          expiredLess10Days.add(item);
        }
      } else {
        notExpired.add(item);
      }
    }

    // Sort each category based on filter type
    _applySortingByFilter(notExpired);
    _applySortingByFilter(expiredLess10Days);
    _applySortingByFilter(expiredMore10Days);

    // Combine: not expired + expired <10 days + expired >10 days
    return [...notExpired, ...expiredLess10Days, ...expiredMore10Days];
  }

  void _applySortingByFilter(List<ItemModel> items) {
    items.sort((a, b) {
      if (_filterType == FilterType.visa) {
        // Sort by visa expiry in ascending order
        final dateA = a.visaExpiry;
        final dateB = b.visaExpiry;

        // Handle nulls - put them at the end
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;

        return dateA.compareTo(dateB);
      } else if (_filterType == FilterType.labourCard) {
        // Sort by labour card expiry in ascending order
        final dateA = a.labourCardExpiry;
        final dateB = b.labourCardExpiry;

        // Handle nulls - put them at the end
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;

        return dateA.compareTo(dateB);
      } else {
        // For 'All' filter: sort by earliest expiry (either visa or labour card)
        DateTime? earliestA;
        DateTime? earliestB;

        // Find earliest expiry for item A
        if (a.visaExpiry != null && a.labourCardExpiry != null) {
          earliestA = a.visaExpiry!.isBefore(a.labourCardExpiry!)
              ? a.visaExpiry
              : a.labourCardExpiry;
        } else {
          earliestA = a.visaExpiry ?? a.labourCardExpiry;
        }

        // Find earliest expiry for item B
        if (b.visaExpiry != null && b.labourCardExpiry != null) {
          earliestB = b.visaExpiry!.isBefore(b.labourCardExpiry!)
              ? b.visaExpiry
              : b.labourCardExpiry;
        } else {
          earliestB = b.visaExpiry ?? b.labourCardExpiry;
        }

        // Handle nulls - put them at the end
        if (earliestA == null && earliestB == null) return 0;
        if (earliestA == null) return 1;
        if (earliestB == null) return -1;

        return earliestA.compareTo(earliestB);
      }
    });
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

    final filteredAndSortedItems = _filterAndSortItems(_items);

    return Column(
      children: [
        // Filter chips
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Colors.white,
          child: Row(
            children: [
              _buildFilterChip(
                label: 'All',
                filterType: FilterType.all,
                icon: Icons.apps_rounded,
              ),
              const SizedBox(width: 8),
              _buildFilterChip(
                label: 'Visa',
                filterType: FilterType.visa,
                icon: Icons.credit_card_rounded,
              ),
              const SizedBox(width: 8),
              _buildFilterChip(
                label: 'Labour Card',
                filterType: FilterType.labourCard,
                icon: Icons.badge_rounded,
              ),
            ],
          ),
        ),
        // List
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadItems,
            child: filteredAndSortedItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.filter_list_off_rounded,
                          size: 56,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No items match this filter',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: filteredAndSortedItems.length,
                    padding: const EdgeInsets.all(16),
                    itemBuilder: (context, index) {
                      final item = filteredAndSortedItems[index];
                      return _buildModernCard(item);
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChip({
    required String label,
    required FilterType filterType,
    required IconData icon,
  }) {
    final isSelected = _filterType == filterType;
    return InkWell(
      onTap: () {
        setState(() {
          _filterType = filterType;
        });
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF3B82F6) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF3B82F6) : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? Colors.white : const Color(0xFF64748B),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModernCard(ItemModel item) {
    final statusColor = _getStatusColor(item);
    final statusIcon = _getStatusIcon(item);

    return Slidable(
      key: ValueKey(item.rowIndex ?? item.no ?? item.employeeCompany),
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: 0.25,
        children: [
          CustomSlidableAction(
            onPressed: (context) => _showEditDialog(item),
            backgroundColor: const Color(0xFF3B82F6),
            foregroundColor: Colors.white,
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.edit_outlined, size: 24),
                SizedBox(height: 4),
                Text(
                  'Edit',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
      child: Container(
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
      ),
    );
  }

  Future<void> _showEditDialog(ItemModel item) async {
    DateTime? labourCardExpiry = item.labourCardExpiry;
    DateTime? visaExpiry = item.visaExpiry;
    bool isUpdating = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle bar
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Title
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3B82F6).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.edit_outlined,
                            color: Color(0xFF3B82F6),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Edit Expiry Dates',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1E293B),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.employeeCompany ?? item.no ?? 'Unknown',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Labour Card Expiry
                    _buildDatePickerTile(
                      icon: Icons.badge_outlined,
                      label: 'Labour Card Expiry',
                      date: labourCardExpiry,
                      originalDate: item.labourCardExpiry,
                      onTap: () async {
                        // Lock to original date - cannot go back to previous dates
                        final minDate = item.labourCardExpiry ?? DateTime.now();
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: labourCardExpiry ?? minDate,
                          firstDate: minDate,
                          lastDate: DateTime(2100),
                          builder: (context, child) {
                            return Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: const ColorScheme.light(
                                  primary: Color(0xFF3B82F6),
                                ),
                              ),
                              child: child!,
                            );
                          },
                        );
                        if (picked != null) {
                          setModalState(() {
                            labourCardExpiry = picked;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),

                    // Visa Expiry
                    _buildDatePickerTile(
                      icon: Icons.travel_explore_outlined,
                      label: 'Visa Expiry',
                      date: visaExpiry,
                      originalDate: item.visaExpiry,
                      onTap: () async {
                        // Lock to original date - cannot go back to previous dates
                        final minDate = item.visaExpiry ?? DateTime.now();
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: visaExpiry ?? minDate,
                          firstDate: minDate,
                          lastDate: DateTime(2100),
                          builder: (context, child) {
                            return Theme(
                              data: Theme.of(context).copyWith(
                                colorScheme: const ColorScheme.light(
                                  primary: Color(0xFF3B82F6),
                                ),
                              ),
                              child: child!,
                            );
                          },
                        );
                        if (picked != null) {
                          setModalState(() {
                            visaExpiry = picked;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 24),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: isUpdating
                                ? null
                                : () => Navigator.pop(context),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: isUpdating
                                ? null
                                : () async {
                                    setModalState(() {
                                      isUpdating = true;
                                    });

                                    try {
                                      final updatedItem = item.copyWith(
                                        labourCardExpiry: labourCardExpiry,
                                        visaExpiry: visaExpiry,
                                      );

                                      await _sheetsService.updateItem(
                                        updatedItem,
                                      );

                                      if (mounted) {
                                        Navigator.pop(context);
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Item updated successfully',
                                            ),
                                            backgroundColor: Color(0xFF10B981),
                                          ),
                                        );
                                        _loadItems();
                                      }
                                    } catch (e) {
                                      setModalState(() {
                                        isUpdating = false;
                                      });
                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Error updating item: $e',
                                            ),
                                            backgroundColor: Colors.red,
                                          ),
                                        );
                                      }
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF3B82F6),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: isUpdating
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Save Changes',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDatePickerTile({
    required IconData icon,
    required String label,
    required DateTime? date,
    required DateTime? originalDate,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon, color: const Color(0xFF64748B), size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        date != null
                            ? app_date_utils.DateUtils.formatDateDisplay(date)
                            : 'Not set',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: date != null
                              ? const Color(0xFF1E293B)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.calendar_today_outlined,
                  color: Color(0xFF3B82F6),
                  size: 20,
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
