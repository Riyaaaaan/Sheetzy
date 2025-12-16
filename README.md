# sheetzy

A Flutter app for tracking item expiry dates with Google Sheets integration and push notifications.

## Getting Started

### Prerequisites

- Flutter SDK (3.9.0 or higher)
- Android Studio / Xcode
- Google Cloud Project with Firebase enabled

### Firebase Setup (Required for Notifications)

1. **Create a Firebase Project**:
   - Go to [Firebase Console](https://console.firebase.google.com/)
   - Create a new project or select an existing one

2. **Add Android App to Firebase**:
   - In Firebase Console, click "Add app" and select Android
   - Package name: `com.example.sheetzy` (or your app's package name)
   - Download `google-services.json`

3. **Add google-services.json**:
   - Place the downloaded `google-services.json` file in `android/app/` directory
   - The file should be at: `android/app/google-services.json`

4. **Verify Firebase Configuration**:
   - The Firebase plugins are already configured in `android/build.gradle.kts` and `android/app/build.gradle.kts`
   - Run `flutter pub get` to install dependencies

### Running the App

1. Install dependencies:
   ```bash
   flutter pub get
   ```

2. Configure Google Sheets:
   - Open the app and go to Settings
   - Add your Google Sheets spreadsheet ID
   - Add service account credentials

3. Run the app:
   ```bash
   flutter run
   ```

## Features

- Track item expiry dates in Google Sheets
- Automatic background checks for expiring items
- Push notifications for items expiring within 5 days
- Android 13+ notification permission handling
- Firebase Cloud Messaging (FCM) for reliable notifications

## Notification System

The app uses Firebase Cloud Messaging (FCM) for reliable push notifications, with local notifications as a fallback. Notifications are sent when:
- Items are expiring within 5 days
- Background checks run twice daily via Workmanager
- Manual notification trigger (debug mode)

## Troubleshooting

### Notifications Not Working

1. **Check Firebase Setup**:
   - Ensure `google-services.json` is in `android/app/` directory
   - Verify Firebase project is properly configured

2. **Check Permissions**:
   - Android 13+ requires runtime permission for notifications
   - Grant notification permission when prompted

3. **Check Logs**:
   - Look for `[FCM]` and `[NotificationService]` tags in logs
   - Verify services are initializing correctly

4. **Battery Optimization**:
   - Disable battery optimization for the app to ensure background tasks run

## Development

- Local notifications fallback works without Firebase
- FCM provides more reliable background notifications
- All notification code includes comprehensive error handling and logging
