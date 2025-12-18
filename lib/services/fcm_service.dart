import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/item_model.dart';

// Top-level function for handling background messages
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('[FCM] Background message received: ${message.messageId}');
  print('[FCM] Notification title: ${message.notification?.title}');
  print('[FCM] Notification body: ${message.notification?.body}');
}

class FCMService {
  static FCMService? _instance;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  String? _fcmToken;

  bool get isInitialized => _initialized;
  String? get fcmToken => _fcmToken;

  FCMService._();

  factory FCMService() {
    _instance ??= FCMService._();
    return _instance!;
  }

  // Initialize FCM service
  Future<bool> initialize() async {
    if (_initialized) return true;

    try {
      // Initialize Firebase if not already initialized
      if (Firebase.apps.isEmpty) {
        try {
          await Firebase.initializeApp();
          print('[FCM] Firebase initialized successfully');
        } catch (e) {
          print(
            '[FCM] Failed to initialize Firebase (google-services.json may be missing): $e',
          );
          print(
            '[FCM] Continuing without FCM - local notifications will be used',
          );
          return false;
        }
      }

      // Set up background message handler
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Request notification permissions (Android 13+)
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        print('[FCM] Notification permissions granted');
      } else {
        print('[FCM] Notification permissions denied');
        // Still continue initialization for local notifications fallback
      }

      // Get FCM token
      _fcmToken = await _messaging.getToken();
      print('[FCM] FCM Token: $_fcmToken');

      // Listen for token refresh
      _messaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        print('[FCM] FCM Token refreshed: $newToken');
      });

      // Set up foreground message handler
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Set up notification tap handler (when app is in background or terminated)
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Check if app was opened from a notification
      final initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationTap(initialMessage);
      }

      // Initialize local notifications for fallback
      await _initializeLocalNotifications();

      _initialized = true;
      return true;
    } catch (e) {
      print('[FCM] Error initializing FCM service: $e');
      return false;
    }
  }

  // Initialize local notifications for fallback
  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        print('[FCM] Local notification tapped: ${response.payload}');
      },
    );

    // Create notification channel for Android
    const androidChannel = AndroidNotificationChannel(
      'expiry_notifications',
      'Expiry Notifications',
      description: 'Notifications for items expiring soon',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(androidChannel);
  }

  // Handle foreground messages
  void _handleForegroundMessage(RemoteMessage message) {
    print('[FCM] Foreground message received: ${message.messageId}');
    print('[FCM] Title: ${message.notification?.title}');
    print('[FCM] Body: ${message.notification?.body}');

    // Show local notification when app is in foreground
    if (message.notification != null) {
      _showLocalNotification(
        message.notification!.title ?? 'Notification',
        message.notification!.body ?? '',
        message.data,
      );
    }
  }

  // Handle notification tap
  void _handleNotificationTap(RemoteMessage message) {
    print('[FCM] Notification tapped: ${message.messageId}');
    print('[FCM] Data: ${message.data}');
    // Handle navigation or action based on notification data
  }

  // Show local notification
  Future<void> _showLocalNotification(
    String title,
    String body,
    Map<String, dynamic> data,
  ) async {
    const androidDetails = AndroidNotificationDetails(
      'expiry_notifications',
      'Expiry Notifications',
      channelDescription: 'Notifications for items expiring soon',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
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

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch % 2147483647,
      title,
      body,
      details,
      payload: json.encode(data),
    );
  }

  // Send notification for expiring item (using local notifications as FCM requires server)
  // In a production app, you would send FCM messages from your server
  Future<void> sendExpiryNotification(
    ItemModel item, {
    bool isVisa = false,
    int? daysInterval,
  }) async {
    if (!_initialized) {
      print('[FCM] Service not initialized, cannot send notification');
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

      final notificationId =
          (identifier.hashCode ^
              expiryDate.millisecondsSinceEpoch ^
              (isVisa ? 1 : 0)) &
          0x7FFFFFFF;

      await _localNotifications.show(
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

      print('[FCM] Local notification sent for: $identifier ($expiryType)');
    } catch (e) {
      print('[FCM] Error sending notification: $e');
    }
  }

  // Request notification permissions (Android 13+)
  Future<bool> requestPermissions() async {
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      final granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      print('[FCM] Permission request result: $granted');
      return granted;
    } catch (e) {
      print('[FCM] Error requesting permissions: $e');
      return false;
    }
  }

  // Subscribe to a topic (for future server-side notifications)
  Future<void> subscribeToTopic(String topic) async {
    try {
      await _messaging.subscribeToTopic(topic);
      print('[FCM] Subscribed to topic: $topic');
    } catch (e) {
      print('[FCM] Error subscribing to topic: $e');
    }
  }

  // Unsubscribe from a topic
  Future<void> unsubscribeFromTopic(String topic) async {
    try {
      await _messaging.unsubscribeFromTopic(topic);
      print('[FCM] Unsubscribed from topic: $topic');
    } catch (e) {
      print('[FCM] Error unsubscribing from topic: $e');
    }
  }
}
