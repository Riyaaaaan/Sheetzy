import 'package:workmanager/workmanager.dart';
import '../services/google_sheets_service.dart';
import '../services/notification_service.dart';
import '../services/fcm_service.dart';
import '../config/sheets_config.dart';

class ExpiryCheckerService {
  static const String taskName = 'expiryCheckerTask';
  static const List<int> notificationIntervals = [10, 5, 3, 1];

  // Initialize workmanager
  static Future<void> initialize() async {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  }

  // Register periodic task to check expiry dates
  static Future<void> registerPeriodicTask() async {
    await Workmanager().registerPeriodicTask(
      taskName,
      taskName,
      frequency: const Duration(hours: 12), // Check twice daily
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  // Cancel the periodic task
  static Future<void> cancelTask() async {
    await Workmanager().cancelByUniqueName(taskName);
  }

  // Check expiry dates and send notifications
  static Future<void> checkExpiryDates() async {
    try {
      print('[ExpiryChecker] Starting expiry check...');

      // Check if service is configured
      if (!SheetsConfig.isConfigured) {
        print('[ExpiryChecker] Sheets not configured, skipping expiry check');
        return;
      }

      // Initialize Google Sheets service
      final sheetsService = GoogleSheetsService();
      if (!sheetsService.isInitialized) {
        print('[ExpiryChecker] Initializing Google Sheets service...');
        final initialized = await sheetsService.initialize();
        if (!initialized) {
          print('[ExpiryChecker] Failed to initialize Google Sheets service');
          return;
        }
        print('[ExpiryChecker] Google Sheets service initialized');
      }

      // Initialize FCM service (preferred for background notifications)
      final fcmService = FCMService();
      bool useFCM = false;
      if (!fcmService.isInitialized) {
        print('[ExpiryChecker] Initializing FCM service...');
        final fcmInitialized = await fcmService.initialize();
        if (fcmInitialized) {
          useFCM = true;
          print('[ExpiryChecker] FCM service initialized successfully');
        } else {
          print(
            '[ExpiryChecker] FCM service initialization failed, using local notifications',
          );
        }
      } else {
        useFCM = true;
        print('[ExpiryChecker] FCM service already initialized');
      }

      // Initialize notification service (fallback)
      final notificationService = NotificationService();
      if (!notificationService.isInitialized) {
        print('[ExpiryChecker] Initializing local notification service...');
        await notificationService.initialize();
        await notificationService.requestPermissions();
        print('[ExpiryChecker] Local notification service initialized');
      }

      // Read items from Google Sheets
      print('[ExpiryChecker] Reading items from Google Sheets...');
      final items = await sheetsService.readItems();
      print('[ExpiryChecker] Found ${items.length} items');

      int notificationsSent = 0;
      int itemsChecked = 0;

      // Check each item for expiry (both labour card and visa) at all intervals
      for (final item in items) {
        final identifier = item.employeeCompany ?? item.no ?? 'Unknown';

        // Check labour card expiry only for employees at all intervals
        if (item.isCompany != true) {
          for (final interval in notificationIntervals) {
            if (item.isExpiringWithinDays(interval)) {
              itemsChecked++;
              // Check if notification was already sent for this interval
              final wasSent = await notificationService.wasNotificationSent(
                item,
                isVisa: false,
                daysInterval: interval,
              );
              if (!wasSent) {
                // Send notification via FCM if available, otherwise use local notifications
                if (useFCM) {
                  await fcmService.sendExpiryNotification(item, isVisa: false);
                  print(
                    '[ExpiryChecker] FCM notification sent for: $identifier (Labour card) - $interval days',
                  );
                } else {
                  await notificationService.sendExpiryNotification(
                    item,
                    isVisa: false,
                    daysInterval: interval,
                  );
                  print(
                    '[ExpiryChecker] Local notification sent for: $identifier (Labour card) - $interval days',
                  );
                }
                // Mark as sent using notification service (shared state)
                await notificationService.markNotificationSent(
                  item,
                  isVisa: false,
                  daysInterval: interval,
                );
                notificationsSent++;
              } else {
                print(
                  '[ExpiryChecker] Notification already sent for: $identifier (Labour card) - $interval days',
                );
              }
            }
          }
        }

        // Check visa expiry at all intervals
        for (final interval in notificationIntervals) {
          if (item.isVisaExpiringWithinDays(interval)) {
            itemsChecked++;
            // Check if notification was already sent for this interval
            final wasSent = await notificationService.wasNotificationSent(
              item,
              isVisa: true,
              daysInterval: interval,
            );
            if (!wasSent) {
              // Send notification via FCM if available, otherwise use local notifications
              if (useFCM) {
                await fcmService.sendExpiryNotification(item, isVisa: true);
                print(
                  '[ExpiryChecker] FCM notification sent for: $identifier (Visa) - $interval days',
                );
              } else {
                await notificationService.sendExpiryNotification(
                  item,
                  isVisa: true,
                  daysInterval: interval,
                );
                print(
                  '[ExpiryChecker] Local notification sent for: $identifier (Visa) - $interval days',
                );
              }
              // Mark as sent using notification service (shared state)
              await notificationService.markNotificationSent(
                item,
                isVisa: true,
                daysInterval: interval,
              );
              notificationsSent++;
            } else {
              print(
                '[ExpiryChecker] Notification already sent for: $identifier (Visa) - $interval days',
              );
            }
          }
        }
      }

      print(
        '[ExpiryChecker] Expiry check completed. Checked ${items.length} items, $itemsChecked expiring items found, $notificationsSent notifications sent.',
      );
    } catch (e, stackTrace) {
      print('[ExpiryChecker] Error checking expiry dates: $e');
      print('[ExpiryChecker] Stack trace: $stackTrace');
    }
  }
}

// Top-level function for workmanager callback
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      print('[Workmanager] Background task started: $task');
      if (task == ExpiryCheckerService.taskName) {
        await ExpiryCheckerService.checkExpiryDates();
        print('[Workmanager] Background task completed successfully');
        return true;
      }
      print('[Workmanager] Unknown task: $task');
      return false;
    } catch (e, stackTrace) {
      print('[Workmanager] Error in background task: $e');
      print('[Workmanager] Stack trace: $stackTrace');
      return false;
    }
  });
}
