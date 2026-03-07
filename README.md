# PowerMark Mobile App

A comprehensive IoT power monitoring application built with Flutter that provides real-time energy consumption tracking and management for smart devices.

## 📱 Overview

PowerMark is a cross-platform mobile application designed to help users monitor and manage their electrical power consumption through IoT-enabled devices. The app connects to IoT sensors and provides detailed insights into energy usage patterns, helping users optimize their power consumption and reduce electricity bills.

## 🚀 Features

### Real-time Monitoring
- Live power consumption data from IoT devices
- Real-time voltage, current, and power factor monitoring
- Instantaneous power readings with historical data

### Dashboard Analytics
- Interactive charts and graphs for energy consumption trends
- Daily, weekly, and monthly usage reports
- Peak usage time identification and analysis

### Device Management
- Multiple device connectivity and monitoring
- Device status tracking and alerts
- Remote device control capabilities

### Smart Alerts
- Customizable threshold notifications
- Power outage alerts
- Abnormal consumption pattern detection

### Data Export
- Export consumption data to various formats
- Integration with cloud storage services
- API access for third-party integrations

## 🛠️ Technologies Used

- **Frontend**: Flutter (Dart)
- **Backend**: Firebase (Authentication, Firestore, Cloud Functions)
- **IoT Communication**: MQTT, WebSocket
- **Data Visualization**: Charts Flutter, Syncfusion
- **Platform Support**: iOS, Android, Web, Desktop (Linux, macOS, Windows)

## 📋 Requirements

- Flutter SDK 3.16.0 or higher
- Dart 3.1.0 or higher
- Firebase project for backend services
- IoT devices with MQTT/WebSocket support

## 🚀 Installation

### Prerequisites

1. Install Flutter SDK from [flutter.dev](https://flutter.dev/docs/get-started/install)
2. Set up Firebase project and configure authentication
3. Install required dependencies

### Setup Instructions

1. **Clone the repository:**
   ```bash
   git clone https://github.com/balkrishnashah0/PowerMark-Mobile-App.git
   cd PowerMark-Mobile-App
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Configure Firebase:**
   - Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
   - Add your iOS and Android apps to the Firebase project
   - Download the configuration files:
     - For Android: `google-services.json` → `android/app/`
     - For iOS: `GoogleService-Info.plist` → `ios/Runner/`
   - Enable Firestore, Authentication, and Cloud Functions in Firebase console

4. **Run the application:**
   ```bash
   flutter run
   ```

## 📱 Platform Support

- ✅ **Android** (API 21+)
- ✅ **iOS** (iOS 12.0+)
- ✅ **Web** (Progressive Web App)
- ✅ **Linux** (Desktop)
- ✅ **macOS** (Desktop)
- ✅ **Windows** (Desktop)

## 🏗️ Project Structure

```
lib/
├── main.dart              # Application entry point
├── dashboard_page.dart    # Main dashboard with analytics
├── models/               # Data models and entities
├── services/             # API services and Firebase integration
├── utils/               # Utility functions and constants
└── widgets/             # Reusable UI components

assets/
├── icon/                # App icons and images
├── css/                 # Web-specific styles
└── js/                  # JavaScript utilities for web

android/                 # Android-specific configuration
ios/                     # iOS-specific configuration
web/                     # Web-specific configuration
```

## 🔧 Configuration

### Environment Variables

Create a `.env` file in the project root with the following variables:

```env
FIREBASE_API_KEY=your_firebase_api_key
FIREBASE_AUTH_DOMAIN=your_project_id.firebaseapp.com
FIREBASE_PROJECT_ID=your_project_id
FIREBASE_STORAGE_BUCKET=your_project_id.appspot.com
FIREBASE_MESSAGING_SENDER_ID=your_messaging_sender_id
FIREBASE_APP_ID=your_app_id
FIREBASE_MEASUREMENT_ID=your_measurement_id
```

### IoT Device Configuration

Configure your IoT devices to connect to the following endpoints:
- **MQTT Broker**: `mqtt://your-broker-url:1883`
- **WebSocket**: `wss://your-websocket-url`

## 📊 Screenshots

![Dashboard](assets/screenshots/dashboard.png)
*Main dashboard showing real-time power consumption*

![Analytics](assets/screenshots/analytics.png)
*Detailed analytics and historical data*

![Device Management](assets/screenshots/devices.png)
*Device management and control interface*

## 🤝 Contributing

We welcome contributions! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

For support and questions:
- Create an issue on GitHub
- Join our Discord community
- Email us at support@powermark.app

## 🙏 Acknowledgments

- Flutter Team for the amazing framework
- Firebase for backend services
- MQTT.js for IoT communication
- Our beta testers for valuable feedback

---

**PowerMark** - Smart Energy Monitoring for a Sustainable Future