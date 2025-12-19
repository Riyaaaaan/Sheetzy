import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/notification_service.dart';
import 'services/fcm_service.dart';
import 'services/expiry_checker_service.dart';
import 'config/sheets_config.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services
  await _initializeServices();

  runApp(const MyApp());
}

Future<void> _initializeServices() async {
  // Load configuration from secure storage
  const storage = FlutterSecureStorage();
  final spreadsheetId = await storage.read(key: 'spreadsheet_id');
  final serviceAccountEmail = await storage.read(key: 'service_account_email');
  final credentials = await storage.read(key: 'service_account_credentials');

  if (spreadsheetId != null && spreadsheetId.isNotEmpty) {
    SheetsConfig.spreadsheetId = spreadsheetId;
  }

  // Set service account email from storage if available
  if (serviceAccountEmail != null && serviceAccountEmail.isNotEmpty) {
    SheetsConfig.serviceAccountEmail = serviceAccountEmail;
  } else if (credentials != null && credentials.isNotEmpty) {
    // Extract service account email from credentials if not explicitly set
    try {
      final credentialsMap = json.decode(credentials) as Map<String, dynamic>;
      if (credentialsMap.containsKey('client_email')) {
        SheetsConfig.serviceAccountEmail =
            credentialsMap['client_email'] as String;
        print(
          '[main] Extracted service account email from credentials: ${SheetsConfig.serviceAccountEmail}',
        );
      }
    } catch (e) {
      print('[main] Error extracting email from credentials: $e');
    }
  }

  // Initialize Firebase and FCM service
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
      print('[main] Firebase initialized');
    }

    final fcmService = FCMService();
    final fcmInitialized = await fcmService.initialize();
    if (fcmInitialized) {
      print('[main] FCM service initialized successfully');
      // Request permissions
      await fcmService.requestPermissions();
    } else {
      print(
        '[main] FCM service initialization failed, using local notifications only',
      );
    }
  } catch (e, stackTrace) {
    print('[main] Error initializing Firebase/FCM: $e');
    print('[main] Stack trace: $stackTrace');
    print('[main] Continuing with local notifications as fallback');
    // Continue with local notifications as fallback - app will still work
  }

  // Initialize notification service (fallback)
  final notificationService = NotificationService();
  await notificationService.initialize();
  await notificationService.requestPermissions();

  // Note: Workmanager initialization is deferred to after app startup
  // to avoid platform channel errors. It will be initialized in HomeScreen.
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      // Re-register WorkManager tasks when app resumes
      _reRegisterWorkManager();
    }
  }

  Future<void> _reRegisterWorkManager() async {
    try {
      print('[MyApp] App resumed, re-registering WorkManager tasks...');
      await ExpiryCheckerService.initialize();
      await ExpiryCheckerService.registerPeriodicTask();
      print('[MyApp] WorkManager tasks re-registered successfully');
    } catch (e) {
      print('[MyApp] Error re-registering WorkManager: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sheetzy - Expiry Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
