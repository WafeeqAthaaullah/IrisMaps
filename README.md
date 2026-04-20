# 👁️ Iris Maps - AI Navigation System

Iris Maps is a high-performance **Flutter** application designed to prevent drowsy driving. It features real-time GPS routing integrated with on-device **AI computer vision** to monitor driver alertness and trigger life-saving alerts.

## Features

  - **Drowsiness Detection**: Real-time eye-tracking using Google ML Kit to calculate "Eye Open" probability at 30fps.
  - **Active Wake-Up System**: High-frequency audio alarms and full-screen visual overlays to alert drowsy drivers.
  - **Smart Routing**: Live navigation with destination search and dynamic polyline path drawing.
  - **Dark Mode Optimization**: Sleek, low-glare dark-mode tiles designed for nighttime road safety.

## Tech Stack

  - **Frontend**: Flutter (Dart)
  - **AI & Vision**: 
      - `camera`: For real-time frame streaming.
      - `google_mlkit_face_detection`: For on-device facial landmark processing.
  - **Mapping**:
      - `flutter_map`: Open-source mapping engine.
      - `latlong2`: For geographic coordinate math.
  - **Utilities**:
      - `geolocator`: High-accuracy GPS location services.
      - `audioplayers`: For triggering the emergency wake-up alarm.
      - `http`: To communicate with OSRM and Nominatim APIs.

## Getting Started

### Prerequisites

  - Flutter SDK (v3.22 or higher)
  - Android SDK (API 35+ recommended)
  - A physical Android device (Required for AI hardware acceleration)

### Installation

1.  **Clone the repository**:
    
    ``` bash
    git clone [https://github.com/WafeeqAthaaullah/IrisMaps.git](https://github.com/WafeeqAthaaullah/IrisMaps.git)
    
    ```

2.  **Install dependencies**:
    
    ``` bash
    flutter pub get
    
    ```

3.  **Configure Assets**:
    Ensure an `alarm.mp3` file exists in the `assets/` folder and is declared in `pubspec.yaml`:
    
    ``` yaml
    flutter:
      assets:
        - assets/alarm.mp3
    
    ```

### Running the App

  - **Debug Mode**:
    ``` bash
    flutter run
    
    ```
  - **Build Release APK**:
    ``` bash
    flutter build apk --release
    
    ```

## CI/CD Automation

This project includes a **GitHub Actions** workflow that automatically compiles a release-ready APK whenever a new version tag (e.g., `v1.0.0`) is pushed to the repository.

## License

This project is licensed under the **MIT License**.