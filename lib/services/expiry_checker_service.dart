import 'dart:convert';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_core/firebase_core.dart';
import '../services/google_sheets_service.dart';
import '../services/notification_service.dart';
import '../services/fcm_service.dart';
import '../config/sheets_config.dart';

class ExpiryCheckerService {
  static const String taskName = 'expiryCheckerTask';
  static const List<int> notificationIntervals = [10, 5, 3, 1];

  // Initialize workmanager
  static Future<void> initialize() async {
    await Workmanager().initialize(callbackDispatcher);
  }

  // Register periodic task to check expiry dates
  static Future<void> registerPeriodicTask() async {
    try {
      // Cancel existing task first to ensure clean registration
      await Workmanager().cancelByUniqueName(taskName);

      // Register with improved constraints for better reliability
      await Workmanager().registerPeriodicTask(
        taskName,
        taskName,
        frequency: const Duration(hours: 12), // Check twice daily
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: false, // Allow execution even on low battery
          requiresCharging: false, // Allow execution without charging
          requiresDeviceIdle:
              false, // Allow execution even when device is in use
          requiresStorageNotLow: false, // Allow execution even with low storage
        ),
        existingWorkPolicy:
            ExistingPeriodicWorkPolicy.keep, // Keep existing task if present
        initialDelay: const Duration(
          minutes: 1,
        ), // Start checking after 1 minute
      );
      print('[ExpiryChecker] Periodic task registered successfully');
    } catch (e) {
      print('[ExpiryChecker] Error registering periodic task: $e');
      // Try to register without existing work policy as fallback
      try {
        await Workmanager().registerPeriodicTask(
          taskName,
          taskName,
          frequency: const Duration(hours: 12),
          constraints: Constraints(networkType: NetworkType.connected),
        );
        print('[ExpiryChecker] Periodic task registered with fallback method');
      } catch (e2) {
        print('[ExpiryChecker] Failed to register periodic task: $e2');
      }
    }
  }

  // Cancel the periodic task
  static Future<void> cancelTask() async {
    await Workmanager().cancelByUniqueName(taskName);
  }

  // Load configuration from secure storage (for background context)
  static Future<void> _loadConfigFromStorage() async {
    try {
      const storage = FlutterSecureStorage();
      final spreadsheetId = await storage.read(key: 'spreadsheet_id');
      final serviceAccountEmail = await storage.read(
        key: 'service_account_email',
      );
      final credentials = await storage.read(
        key: 'service_account_credentials',
      );

      if (spreadsheetId != null && spreadsheetId.isNotEmpty) {
        SheetsConfig.spreadsheetId = spreadsheetId;
        print('[ExpiryChecker] Loaded spreadsheet ID from storage');
      }

      // Set service account email from storage if available
      if (serviceAccountEmail != null && serviceAccountEmail.isNotEmpty) {
        SheetsConfig.serviceAccountEmail = serviceAccountEmail;
        print('[ExpiryChecker] Loaded service account email from storage');
      } else if (credentials != null && credentials.isNotEmpty) {
        // Extract service account email from credentials if not explicitly set
        try {
          final credentialsMap =
              json.decode(credentials) as Map<String, dynamic>;
          if (credentialsMap.containsKey('client_email')) {
            SheetsConfig.serviceAccountEmail =
                credentialsMap['client_email'] as String;
            print(
              '[ExpiryChecker] Extracted service account email from credentials',
            );
          }
        } catch (e) {
          print('[ExpiryChecker] Error extracting email from credentials: $e');
        }
      }
    } catch (e) {
      print('[ExpiryChecker] Error loading config from storage: $e');
    }
  }

  // Check expiry dates and send notifications
  static Future<void> checkExpiryDates() async {
    try {
      print('[ExpiryChecker] Starting expiry check...');

      // Load configuration from storage (important for background context)
      await _loadConfigFromStorage();

      // Check if service is configured
      if (!SheetsConfig.isConfigured) {
        print('[ExpiryChecker] Sheets not configured, skipping expiry check');
        return;
      }

      // Initialize Firebase if needed (for background context)
      try {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp();
          print('[ExpiryChecker] Firebase initialized in background');
        }
      } catch (e) {
        print('[ExpiryChecker] Firebase already initialized or error: $e');
      }

      // Initialize Google Sheets service
      final sheetsService = GoogleSheetsService();
      if (!sheetsService.isInitialized) {
        print('[ExpiryChecker] Initializing Google Sheets service...');

        // Try to initialize with credentials from storage
        const storage = FlutterSecureStorage();
        final credentials = await storage.read(
          key: 'service_account_credentials',
        );

        bool initialized = false;
        if (credentials != null && credentials.isNotEmpty) {
          try {
            initialized = await sheetsService.initializeWithCredentials(
              credentials,
            );
            if (initialized) {
              print('[ExpiryChecker] Initialized with stored credentials');
            }
          } catch (e) {
            print('[ExpiryChecker] Error initializing with credentials: $e');
          }
        }

        if (!initialized) {
          initialized = await sheetsService.initialize();
          if (!initialized) {
            print('[ExpiryChecker] Failed to initialize Google Sheets service');
            return;
          }
          print('[ExpiryChecker] Google Sheets service initialized');
        }
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

      // Initialize notification service (fallback) with retry logic
      final notificationService = NotificationService();
      bool notificationServiceReady = false;

      if (!notificationService.isInitialized) {
        print('[ExpiryChecker] Initializing local notification service...');
        // Retry initialization up to 3 times
        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            final initialized = await notificationService.initialize();
            if (initialized) {
              // Request permissions (may fail silently in background, but that's OK)
              try {
                await notificationService.requestPermissions();
              } catch (e) {
                print(
                  '[ExpiryChecker] Permission request failed (may be normal in background): $e',
                );
              }
              notificationServiceReady = true;
              print(
                '[ExpiryChecker] Local notification service initialized successfully',
              );
              break;
            } else {
              print(
                '[ExpiryChecker] Notification service initialization attempt $attempt failed',
              );
              if (attempt < 3) {
                await Future.delayed(Duration(seconds: attempt));
              }
            }
          } catch (e) {
            print(
              '[ExpiryChecker] Error initializing notification service (attempt $attempt): $e',
            );
            if (attempt < 3) {
              await Future.delayed(Duration(seconds: attempt));
            }
          }
        }

        if (!notificationServiceReady) {
          print(
            '[ExpiryChecker] WARNING: Notification service failed to initialize after retries',
          );
        }
      } else {
        notificationServiceReady = true;
        print('[ExpiryChecker] Notification service already initialized');
      }

      // Ensure notification channel exists (critical for Android)
      if (notificationServiceReady) {
        try {
          // The channel should already be created during initialization,
          // but we verify it exists by checking if service is initialized
          print('[ExpiryChecker] Notification service ready for use');
        } catch (e) {
          print('[ExpiryChecker] Error verifying notification channel: $e');
        }
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
                if (useFCM && fcmService.isInitialized) {
                  try {
                    await fcmService.sendExpiryNotification(
                      item,
                      isVisa: false,
                    );
                    print(
                      '[ExpiryChecker] FCM notification sent for: $identifier (Labour card) - $interval days',
                    );
                  } catch (e) {
                    print(
                      '[ExpiryChecker] FCM notification failed, falling back to local: $e',
                    );
                    // Fallback to local notifications
                    if (notificationServiceReady) {
                      await notificationService.sendExpiryNotification(
                        item,
                        isVisa: false,
                        daysInterval: interval,
                      );
                    }
                  }
                } else if (notificationServiceReady) {
                  try {
                    await notificationService.sendExpiryNotification(
                      item,
                      isVisa: false,
                      daysInterval: interval,
                    );
                    print(
                      '[ExpiryChecker] Local notification sent for: $identifier (Labour card) - $interval days',
                    );
                  } catch (e) {
                    print(
                      '[ExpiryChecker] Failed to send local notification: $e',
                    );
                  }
                } else {
                  print(
                    '[ExpiryChecker] WARNING: Cannot send notification - services not ready',
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
              if (useFCM && fcmService.isInitialized) {
                try {
                  await fcmService.sendExpiryNotification(item, isVisa: true);
                  print(
                    '[ExpiryChecker] FCM notification sent for: $identifier (Visa) - $interval days',
                  );
                } catch (e) {
                  print(
                    '[ExpiryChecker] FCM notification failed, falling back to local: $e',
                  );
                  // Fallback to local notifications
                  if (notificationServiceReady) {
                    await notificationService.sendExpiryNotification(
                      item,
                      isVisa: true,
                      daysInterval: interval,
                    );
                  }
                }
              } else if (notificationServiceReady) {
                try {
                  await notificationService.sendExpiryNotification(
                    item,
                    isVisa: true,
                    daysInterval: interval,
                  );
                  print(
                    '[ExpiryChecker] Local notification sent for: $identifier (Visa) - $interval days',
                  );
                } catch (e) {
                  print(
                    '[ExpiryChecker] Failed to send local notification: $e',
                  );
                }
              } else {
                print(
                  '[ExpiryChecker] WARNING: Cannot send notification - services not ready',
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
    final startTime = DateTime.now();
    print('[Workmanager] ========================================');
    print('[Workmanager] Background task started: $task');
    print('[Workmanager] Timestamp: ${startTime.toIso8601String()}');
    if (inputData != null && inputData.isNotEmpty) {
      print('[Workmanager] Input data: $inputData');
    }

    try {
      if (task == ExpiryCheckerService.taskName) {
        print('[Workmanager] Executing expiry check task...');

        try {
          await ExpiryCheckerService.checkExpiryDates();

          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          print('[Workmanager] Background task completed successfully');
          print('[Workmanager] Duration: ${duration.inSeconds} seconds');
          print('[Workmanager] ========================================');
          return true;
        } catch (checkError, checkStackTrace) {
          print('[Workmanager] ERROR in checkExpiryDates: $checkError');
          print('[Workmanager] Error type: ${checkError.runtimeType}');
          print('[Workmanager] Stack trace: $checkStackTrace');

          // Try to send a diagnostic notification if possible
          try {
            final notificationService = NotificationService();
            if (notificationService.isInitialized) {
              // Don't send user-facing error notifications, just log
              print(
                '[Workmanager] Notification service available but not sending error notification',
              );
            }
          } catch (notifError) {
            print(
              '[Workmanager] Could not access notification service for diagnostics: $notifError',
            );
          }

          final endTime = DateTime.now();
          final duration = endTime.difference(startTime);
          print(
            '[Workmanager] Task failed after ${duration.inSeconds} seconds',
          );
          print('[Workmanager] ========================================');
          return false;
        }
      } else {
        print('[Workmanager] WARNING: Unknown task received: $task');
        print('[Workmanager] Expected task: ${ExpiryCheckerService.taskName}');
        print('[Workmanager] ========================================');
        return false;
      }
    } catch (e, stackTrace) {
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      print('[Workmanager] CRITICAL ERROR in background task: $e');
      print('[Workmanager] Error type: ${e.runtimeType}');
      print('[Workmanager] Stack trace: $stackTrace');
      print('[Workmanager] Task failed after ${duration.inSeconds} seconds');
      print('[Workmanager] ========================================');

      // Return false to indicate failure
      return false;
    }
  });
}
