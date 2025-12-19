import 'dart:convert';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/item_model.dart';

class NotificationService {
  static NotificationService? _instance;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  bool get isInitialized => _initialized;

  NotificationService._();

  factory NotificationService() {
    _instance ??= NotificationService._();
    return _instance!;
  }

  // Initialize notification service
  Future<bool> initialize() async {
    if (_initialized) return true;

    try {
      // Android initialization settings
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );

      // iOS initialization settings
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      // Initialization settings
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      // Initialize plugin
      final initialized = await _notifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      if (initialized ?? false) {
        // Create notification channel for Android
        await _createNotificationChannel();
        _initialized = true;
        print(
          '[NotificationService] Notification service initialized successfully',
        );
        return true;
      }

      print('[NotificationService] Failed to initialize notification service');
      return false;
    } catch (e, stackTrace) {
      print('[NotificationService] Error initializing notifications: $e');
      print('[NotificationService] Stack trace: $stackTrace');
      return false;
    }
  }

  // Create notification channel for Android
  Future<void> _createNotificationChannel() async {
    try {
      const androidChannel = AndroidNotificationChannel(
        'expiry_notifications',
        'Expiry Notifications',
        description: 'Notifications for items expiring soon',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      );

      final androidImplementation = _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      if (androidImplementation != null) {
        await androidImplementation.createNotificationChannel(androidChannel);
        print(
          '[NotificationService] Notification channel created successfully',
        );
      } else {
        print('[NotificationService] Android implementation not available');
      }
    } catch (e) {
      print('[NotificationService] Error creating notification channel: $e');
    }
  }

  // Check if notification permissions are granted
  Future<bool> checkPermissions() async {
    try {
      // Android 13+ (API 33+) requires runtime permission check
      if (Platform.isAndroid) {
        final androidImplementation = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

        if (androidImplementation != null) {
          // Check if permissions are granted (Android 13+)
          try {
            final granted = await androidImplementation
                .areNotificationsEnabled();
            if (granted == true) {
              print('[NotificationService] Android notifications are enabled');
              return true;
            } else {
              print('[NotificationService] Android notifications are disabled');
              return false;
            }
          } catch (e) {
            // If check fails, assume permissions are OK for older Android versions
            print(
              '[NotificationService] Could not check Android permissions: $e',
            );
            return true; // Assume granted for older versions
          }
        }
      }

      // iOS - permissions are checked during initialization
      // If service is initialized, assume permissions are OK
      if (Platform.isIOS && _initialized) {
        return true;
      }

      // Default: assume permissions are granted if we can't check
      return _initialized;
    } catch (e) {
      print(
        '[NotificationService] Error checking notification permissions: $e',
      );
      // If check fails, assume permissions might be OK
      return _initialized;
    }
  }

  // Request notification permissions
  Future<bool> requestPermissions() async {
    try {
      // Android 13+ (API 33+) requires runtime permission for POST_NOTIFICATIONS
      if (Platform.isAndroid) {
        final androidImplementation = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();

        if (androidImplementation != null) {
          // Request permissions for Android 13+
          final granted = await androidImplementation
              .requestNotificationsPermission();
          if (granted == true) {
            print(
              '[NotificationService] Android notification permission granted',
            );
            return true;
          } else {
            print(
              '[NotificationService] Android notification permission denied',
            );
            // Still return true for older Android versions
            return true;
          }
        }
      }

      // iOS requires permission
      final iosImplementation = _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();

      if (iosImplementation != null) {
        final result = await iosImplementation.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        print('[NotificationService] iOS permission result: $result');
        return result ?? false;
      }

      return true;
    } catch (e) {
      print(
        '[NotificationService] Error requesting notification permissions: $e',
      );
      return false;
    }
  }

  // Check if notification was already sent for an item (labour card)
  Future<bool> wasNotificationSent(
    ItemModel item, {
    bool isVisa = false,
    int? daysInterval,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final identifier = item.no ?? item.employeeCompany ?? 'unknown';
    final expiryDate = isVisa ? item.visaExpiry : item.labourCardExpiry;
    if (expiryDate == null) return false;
    final intervalSuffix = daysInterval != null ? '_$daysInterval' : '';
    final key =
        'notification_sent_${identifier}_${isVisa ? 'visa' : 'labour'}_${expiryDate.millisecondsSinceEpoch}$intervalSuffix';
    return prefs.getBool(key) ?? false;
  }

  // Mark notification as sent for an item
  Future<void> markNotificationSent(
    ItemModel item, {
    bool isVisa = false,
    int? daysInterval,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final identifier = item.no ?? item.employeeCompany ?? 'unknown';
    final expiryDate = isVisa ? item.visaExpiry : item.labourCardExpiry;
    if (expiryDate == null) return;
    final intervalSuffix = daysInterval != null ? '_$daysInterval' : '';
    final key =
        'notification_sent_${identifier}_${isVisa ? 'visa' : 'labour'}_${expiryDate.millisecondsSinceEpoch}$intervalSuffix';
    await prefs.setBool(key, true);
  }

  // Send notification for expiring item (labour card or visa)
  Future<void> sendExpiryNotification(
    ItemModel item, {
    bool isVisa = false,
    int? daysInterval,
  }) async {
    // Check if service is initialized
    if (!_initialized) {
      print(
        '[NotificationService] Service not initialized, cannot send notification',
      );
      return;
    }

    // Check if permissions are granted (especially important for Android 13+)
    final hasPermissions = await checkPermissions();
    if (!hasPermissions) {
      print(
        '[NotificationService] Notification permissions not granted, cannot send notification',
      );
      // Try to request permissions as a last resort
      final requested = await requestPermissions();
      if (!requested) {
        print(
          '[NotificationService] Failed to obtain notification permissions',
        );
        return;
      }
    }

    final expiryDate = isVisa ? item.visaExpiry : item.labourCardExpiry;
    final daysUntilExpiry = isVisa
        ? item.visaDaysUntilExpiry
        : item.daysUntilExpiry;
    final isExpired = isVisa ? item.isVisaExpired : item.isExpired;

    // Don't send notifications for expired items
    if (expiryDate == null ||
        isExpired ||
        daysUntilExpiry == null ||
        daysUntilExpiry < 0) {
      return;
    }

    // Check if notification was already sent for this specific interval
    if (await wasNotificationSent(
      item,
      isVisa: isVisa,
      daysInterval: daysInterval,
    )) {
      return;
    }

    try {
      final identifier = item.employeeCompany ?? item.no ?? 'Unknown';
      final expiryType = isVisa ? 'Visa' : 'Labour card';
      final title = '$expiryType Expiring Soon';
      final body = daysUntilExpiry == 0
          ? '$identifier - $expiryType expires today!'
          : '$identifier - $expiryType expires in $daysUntilExpiry day${daysUntilExpiry == 1 ? '' : 's'}';

      const androidDetails = AndroidNotificationDetails(
        'expiry_notifications',
        'Expiry Notifications',
        channelDescription: 'Notifications for items expiring soon',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        enableVibration: true,
        playSound: true,
        // Ensure notifications show in foreground
        ongoing: false,
        autoCancel: true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Use a unique ID based on identifier and expiry date
      // XOR and mask to ensure 32-bit integer range (0 to 2^31 - 1)
      final notificationId =
          (identifier.hashCode ^
              expiryDate.millisecondsSinceEpoch ^
              (isVisa ? 1 : 0)) &
          0x7FFFFFFF;

      await _notifications.show(
        notificationId,
        title,
        body,
        details,
        payload: json.encode({
          'identifier': identifier,
          'expiryDate': expiryDate.toIso8601String(),
          'isVisa': isVisa,
        }),
      );

      // Mark notification as sent for this interval
      await markNotificationSent(
        item,
        isVisa: isVisa,
        daysInterval: daysInterval,
      );
      print(
        '[NotificationService] Notification sent successfully for: $identifier ($expiryType)${daysInterval != null ? ' - $daysInterval days' : ''}',
      );
    } catch (e, stackTrace) {
      print('[NotificationService] Error sending notification: $e');
      print('[NotificationService] Stack trace: $stackTrace');
    }
  }

  // Schedule notification for a specific date/time
  Future<void> scheduleExpiryNotification(
    ItemModel item,
    DateTime scheduledDate, {
    bool isVisa = false,
    int? daysInterval,
  }) async {
    if (await wasNotificationSent(
      item,
      isVisa: isVisa,
      daysInterval: daysInterval,
    )) {
      return;
    }

    try {
      final expiryDate = isVisa ? item.visaExpiry : item.labourCardExpiry;
      final daysUntilExpiry = isVisa
          ? item.visaDaysUntilExpiry
          : item.daysUntilExpiry;

      if (expiryDate == null || daysUntilExpiry == null) return;

      final identifier = item.employeeCompany ?? item.no ?? 'Unknown';
      final expiryType = isVisa ? 'Visa' : 'Labour card';
      final title = '$expiryType Expiring Soon';
      final body = daysUntilExpiry == 0
          ? '$identifier - $expiryType expires today!'
          : '$identifier - $expiryType expires in $daysUntilExpiry day${daysUntilExpiry == 1 ? '' : 's'}';

      const androidDetails = AndroidNotificationDetails(
        'expiry_notifications',
        'Expiry Notifications',
        channelDescription: 'Notifications for items expiring soon',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        enableVibration: true,
        playSound: true,
        // Ensure notifications show in foreground
        ongoing: false,
        autoCancel: true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Use a unique ID based on identifier and expiry date
      // XOR and mask to ensure 32-bit integer range (0 to 2^31 - 1)
      final notificationId =
          (identifier.hashCode ^
              expiryDate.millisecondsSinceEpoch ^
              (isVisa ? 1 : 0)) &
          0x7FFFFFFF;

      // Note: flutter_local_notifications doesn't support exact scheduling
      // We'll use workmanager for scheduled checks instead
      // This method is kept for future use or immediate notifications
      await _notifications.show(
        notificationId,
        title,
        body,
        details,
        payload: json.encode({
          'identifier': identifier,
          'expiryDate': expiryDate.toIso8601String(),
          'isVisa': isVisa,
        }),
      );

      await markNotificationSent(
        item,
        isVisa: isVisa,
        daysInterval: daysInterval,
      );
    } catch (e) {
      print('Error scheduling notification: $e');
    }
  }

  // Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    // Handle notification tap - could navigate to item details
    print('Notification tapped: ${response.payload}');
  }

  // Cancel all notifications
  Future<void> cancelAllNotifications() async {
    await _notifications.cancelAll();
  }

  // Cancel specific notification
  Future<void> cancelNotification(int notificationId) async {
    await _notifications.cancel(notificationId);
  }

  // Clear notification sent flags (for testing or reset)
  Future<void> clearNotificationFlags() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    for (final key in keys) {
      if (key.startsWith('notification_sent_')) {
        await prefs.remove(key);
      }
    }
  }
}
