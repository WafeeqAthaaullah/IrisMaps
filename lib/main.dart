import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:iris_maps/services/image_enhancement_service.dart';
import 'package:iris_maps/services/head_pose_service.dart';
import 'package:iris_maps/services/eye_classifier_service.dart';
import 'package:iris_maps/screens/settings_screen.dart';
import 'package:iris_maps/screens/stats_screen.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IrisMapsApp());
}

class IrisMapsApp extends StatelessWidget {
  const IrisMapsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Iris Maps',
      theme: ThemeData.dark(),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Scaffold key for programmatic drawer control
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Map State
  LatLng? _currentLocation;
  bool _isLoadingMap = true;

  // Drowsiness State
  bool _isDrowsy = false;
  int _closedEyeFrames = 0;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final MapController _mapController = MapController();
  LatLng? _destination;
  List<LatLng> _routePoints = [];

  // Driver-Safety Thresholds & Toggles
  double eyeClosureThreshold = 0.3;
  double headTiltSensitivity = 20.0;
  bool isImageEnhancementEnabled = false;
  bool isAlarmVolumeOn = true;
  bool showLiveStatusHud = true; // Added for Toggleable HUD
  bool isDeveloperModeEnabled = false; // Added for Dev Mode

  // Alert history for Stats screen (last 5 alerts)
  final List<AlertEntry> _alertLog = [];

  // Search State
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  bool _isSearching = false;

  // Enhancement Service (Member 1)
  final ImageEnhancementService _enhancementService = ImageEnhancementService();

  // Head Pose State (Member 2)
  final HeadPoseService _headPoseService = HeadPoseService();
  String _alertMessage = "WAKE UP!";
  bool _headPoseWarning = false;
  String? _headPoseWarningMessage;

  // Eye Classifier (Member 3)
  final EyeClassifierService _eyeClassifierService = EyeClassifierService();

  // ML Kit & Camera State
  CameraController? _cameraController;
  late final FaceDetector _faceDetector;
  bool _isProcessingImage = false;

  // Dev Mode Tracking Variables
  Face? _currentFace;
  Size? _cameraImageSize;

  // HUD telemetry state
  double _hudEyeOpenness = 1.0;
  double _hudHeadTiltAngle = 0.0;
  HeadPoseAlertLevel _hudSafetyLevel = HeadPoseAlertLevel.safe;
  bool _hudFaceDetected = false;

  @override
  void initState() {
    super.initState();
    _getUserLocation();
    _initializeSilentCamera();
    _eyeClassifierService.loadModel();

    final options = FaceDetectorOptions(
      enableClassification: true,
      enableLandmarks: true,
      enableTracking: true,
      performanceMode: FaceDetectorMode.fast,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<void> _getUserLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        print('[IrisMaps] Location permission denied — showing fallback map.');
        if (mounted) setState(() => _isLoadingMap = false);
        return;
      }

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('GPS fix timed out after 15s'),
      );

      if (mounted) {
        setState(() {
          _currentLocation = LatLng(position.latitude, position.longitude);
          _isLoadingMap = false;
        });
      }
    } on LocationServiceDisabledException {
      print('[IrisMaps] Location services disabled — showing fallback map.');
      if (mounted) setState(() => _isLoadingMap = false);
    } on TimeoutException catch (e) {
      print('[IrisMaps] $e — showing fallback map.');
      if (mounted) setState(() => _isLoadingMap = false);
    } catch (e) {
      print('[IrisMaps] _getUserLocation error: $e — showing fallback map.');
      if (mounted) setState(() => _isLoadingMap = false);
    }
  }

  Future<void> _getRoute() async {
    if (_currentLocation == null || _destination == null) return;

    final start = _currentLocation!;
    final end = _destination!;

    final url =
        'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?geometries=geojson';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            data['routes'].isNotEmpty) {
          final List coordinates = data['routes'][0]['geometry']['coordinates'];

          if (!mounted) return;

          setState(() {
            _routePoints = coordinates.map((coord) {
              return LatLng(
                  (coord[1] as num).toDouble(), (coord[0] as num).toDouble());
            }).toList();
          });
        } else {
          print("WARNING: No driving route found to this location.");
        }
      }
    } catch (e) {
      print("Routing Error: $e");
    }
  }

  Future<void> _searchPlaces(String query) async {
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchResults.clear();
    });

    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=5');

    try {
      final response =
          await http.get(url, headers: {'User-Agent': 'IrisMapsApp/1.0'});
      if (response.statusCode == 200) {
        setState(() {
          _searchResults = json.decode(response.body);
          _isSearching = false;
        });
      }
    } catch (e) {
      print("Search Error: $e");
      setState(() => _isSearching = false);
    }
  }

  Future<void> _initializeSilentCamera() async {
    final cameras = await availableCameras();
    final frontCamera = cameras
        .firstWhere((c) => c.lensDirection == CameraLensDirection.front);

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await _cameraController!.initialize();

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessingImage) return;
      _isProcessingImage = true;

      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final Uint8List rawBytes = allBytes.done().buffer.asUint8List();

      _enhancementService.isEnabled = isImageEnhancementEnabled;
      final Uint8List detectionBytes = isImageEnhancementEnabled
          ? _enhancementService.enhanceIfDark(rawBytes, image.width, image.height)
          : rawBytes;

      final inputImageFormat = Platform.isAndroid
          ? InputImageFormat.nv21
          : InputImageFormat.bgra8888;
      final inputImage = InputImage.fromBytes(
        bytes: detectionBytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation270deg,
          format: inputImageFormat,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );

      final List<Face> faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        final Face face = faces.first;

        final double? leftProb  = face.leftEyeOpenProbability;
        final double? rightProb = face.rightEyeOpenProbability;
        final double avgEyeOpenness = (leftProb != null && rightProb != null)
            ? (leftProb + rightProb) / 2.0
            : 1.0;

        int tfliteEyeResult = 1;
        final leftLm  = face.landmarks[FaceLandmarkType.leftEye];
        if (leftLm != null && Platform.isAndroid) {
          final lm = leftLm;
          final crop = _extractEyeCrop(
            rawBytes, image.width, image.height,
            lm.position.x.toInt(), lm.position.y.toInt(), 24,
          );
          tfliteEyeResult = await _eyeClassifierService.classifyEye(crop);
        }

        final bool mlKitClosed = leftProb != null &&
            rightProb != null &&
            leftProb  < eyeClosureThreshold &&
            rightProb < eyeClosureThreshold;
        final bool tfliteClosed = tfliteEyeResult == 0;

        if (mlKitClosed || tfliteClosed) {
          _closedEyeFrames++;
          if (_closedEyeFrames >= 3 && mounted) {
            setState(() => _alertMessage = "WAKE UP!");
            _triggerDrowsiness();
          }
        } else {
          _closedEyeFrames = 0;
        }

        final HeadPoseResult? poseResult = _headPoseService.analyze(face);
        HeadPoseAlertLevel poseLevel = HeadPoseAlertLevel.safe;

        if (poseResult != null && mounted) {
          poseLevel = poseResult.level;

          final double maxAngle = poseResult.rollAngle.abs()
              .clamp(0, double.infinity)
              .toDouble();
          final bool angleExceedsThreshold = maxAngle > headTiltSensitivity ||
              poseResult.pitchAngle < -headTiltSensitivity;

          if (poseResult.level == HeadPoseAlertLevel.critical &&
              angleExceedsThreshold) {
            setState(() {
              _alertMessage = poseResult.alertMessage ??
                  "Head tilt detected – Stay Alert!";
              _headPoseWarning = false;
            });
            _triggerDrowsiness();
          } else if (poseResult.level == HeadPoseAlertLevel.warning &&
              poseResult.alertMessage != null) {
            setState(() {
              _headPoseWarning = true;
              _headPoseWarningMessage = poseResult.alertMessage;
            });
          } else if (poseResult.level == HeadPoseAlertLevel.safe &&
              _headPoseWarning) {
            setState(() => _headPoseWarning = false);
          }

          setState(() {
            _hudFaceDetected  = true;
            _hudEyeOpenness   = avgEyeOpenness;
            _hudHeadTiltAngle = poseResult.rollAngle.abs();
            _hudSafetyLevel   = poseLevel;
            _currentFace = face; // For dev mode
            _cameraImageSize = Size(image.height.toDouble(), image.width.toDouble()); // Rotated size
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _hudFaceDetected  = false;
            _hudSafetyLevel   = HeadPoseAlertLevel.safe;
            _headPoseWarning  = false;
            _currentFace = null; // Clear dev mode tracking
          });
        }
      }

      _isProcessingImage = false;
    });
  }

  void _triggerDrowsiness() async {
    if (!_isDrowsy) {
      setState(() {
        _isDrowsy = true;
        final entry = AlertEntry(
          message: _alertMessage,
          timestamp: DateTime.now(),
        );
        _alertLog.insert(0, entry);
        if (_alertLog.length > 5) _alertLog.removeLast();
      });
      if (isAlarmVolumeOn) {
        await _audioPlayer.setReleaseMode(ReleaseMode.loop);
        await _audioPlayer.play(AssetSource('alarm.mp3'));
      }
    }
  }

  void _wakeUpDriver() async {
    if (_isDrowsy) {
      setState(() {
        _isDrowsy = false;
        _alertMessage = "WAKE UP!"; 
      });
      _headPoseService.reset();
      await _audioPlayer.stop();
    }
  }

  List<List<List<List<double>>>> _extractEyeCrop(
    Uint8List yPlane, int imgW, int imgH, int cx, int cy, int size,
  ) {
    final int half = size ~/ 2;
    return List.generate(1, (_) =>
      List.generate(size, (row) =>
        List.generate(size, (col) {
          final int sx = (cy - half + row).clamp(0, imgH - 1);
          final int sy = (imgW - 1 - (cx - half + col)).clamp(0, imgW - 1);
          final double pixel = (yPlane[sx * imgW + sy] & 0xFF) / 255.0;
          return [pixel];
        }),
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector.close();
    _audioPlayer.dispose();
    _eyeClassifierService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      extendBodyBehindAppBar: true,
      drawer: Drawer(
        backgroundColor: Colors.grey[900],
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                child: Row(
                  children: [
                    const Icon(Icons.remove_red_eye, color: Colors.blueAccent, size: 28),
                    const SizedBox(width: 10),
                    const Text(
                      'Iris Maps',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.bar_chart, color: Colors.white70),
                title: const Text('Alert Stats', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StatsScreen(alertLog: _alertLog),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings, color: Colors.white70),
                title: const Text('Settings', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                        eyeClosureThreshold: eyeClosureThreshold,
                        headTiltSensitivity: headTiltSensitivity,
                        isImageEnhancementEnabled: isImageEnhancementEnabled,
                        isAlarmVolumeOn: isAlarmVolumeOn,
                        showLiveStatusHud: showLiveStatusHud, // Pass to settings
                        isDeveloperModeEnabled: isDeveloperModeEnabled, // Pass to settings
                        onChanged: ({
                          required double eye,
                          required double tilt,
                          required bool enhance,
                          required bool alarm,
                          required bool hud, // Receive from settings
                          required bool devMode, // Receive from settings
                        }) {
                          setState(() {
                            eyeClosureThreshold = eye;
                            headTiltSensitivity = tilt;
                            isImageEnhancementEnabled = enhance;
                            isAlarmVolumeOn = alarm;
                            showLiveStatusHud = hud;
                            isDeveloperModeEnabled = devMode;
                          });
                        },
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          // ==========================================
          // LAYER 1: THE FULL SCREEN MAP
          // ==========================================
          _isLoadingMap
              ? const Center(child: CircularProgressIndicator())
              : FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentLocation ?? const LatLng(0, 0),
                    initialZoom: 16.0,
                    minZoom: 3.0,
                    maxZoom: 18.0,
                    onLongPress: (tapPosition, point) {
                      setState(() {
                        _destination = point;
                        _routePoints.clear();
                      });
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.irismaps',
                    ),
                    if (_routePoints.length > 1)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _routePoints,
                            strokeWidth: 5.0,
                            color: Colors.blueAccent.withValues(alpha: 0.8),
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        if (_currentLocation != null)
                          Marker(
                            point: _currentLocation!,
                            width: 60,
                            height: 60,
                            child: const Icon(Icons.navigation,
                                color: Colors.blueAccent, size: 40),
                          ),
                        if (_destination != null)
                          Marker(
                            point: _destination!,
                            width: 60,
                            height: 60,
                            child: const Icon(Icons.location_on,
                                color: Colors.redAccent, size: 40),
                          ),
                      ],
                    ),
                  ],
                ),

          // ==========================================
          // LAYER 2: FLOATING UI ELEMENTS
          // ==========================================
          Positioned(
            top: 50.0,
            left: 16.0,
            right: 16.0,
            child: Column(
              children: [
                Container(
                  height: 50.0,
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(25.0),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8.0,
                          offset: Offset(0, 3))
                    ],
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.menu, color: Colors.white70),
                        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: "Search here",
                            hintStyle: TextStyle(color: Colors.white54),
                            border: InputBorder.none,
                          ),
                          onSubmitted: _searchPlaces,
                        ),
                      ),
                      _isSearching
                          ? const Padding(
                              padding: EdgeInsets.all(12.0),
                              child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          : IconButton(
                              icon: const Icon(Icons.search,
                                  color: Colors.white70),
                              onPressed: () =>
                                  _searchPlaces(_searchController.text),
                            ),
                    ],
                  ),
                ),
                if (_searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 8.0),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(15.0),
                      boxShadow: const [
                        BoxShadow(
                            color: Colors.black26,
                            blurRadius: 8.0,
                            offset: Offset(0, 3))
                      ],
                    ),
                    constraints: const BoxConstraints(maxHeight: 250),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _searchResults.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, color: Colors.white24),
                      itemBuilder: (context, index) {
                        final result = _searchResults[index];
                        return ListTile(
                          leading: const Icon(Icons.location_on,
                              color: Colors.white54),
                          title: Text(
                            result['display_name'],
                            style: const TextStyle(color: Colors.white),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            final lat = double.parse(result['lat']);
                            final lon = double.parse(result['lon']);
                            final location = LatLng(lat, lon);

                            setState(() {
                              _destination = location;
                              _routePoints.clear();
                              _searchResults.clear();
                              _searchController.text = result['name'] ?? '';
                            });

                            _mapController.move(location, 15.0);
                            FocusScope.of(context).unfocus();
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // ==========================================
          // LAYER 2b: DEVELOPER MODE PiP (Camera Feed & Bounding Boxes)
          // ==========================================
          if (isDeveloperModeEnabled && _cameraController != null && _cameraController!.value.isInitialized)
            Positioned(
              top: 120.0,
              right: 16.0,
              width: 140.0,
              height: 210.0,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.greenAccent, width: 2),
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(_cameraController!),
                      if (_currentFace != null && _cameraImageSize != null)
                        CustomPaint(
                          painter: FaceOverlayPainter(_currentFace!, _cameraImageSize!),
                        ),
                    ],
                  ),
                ),
              ),
            ),

          // --- Enhancement Toggle Button (Bottom Left) ---
          Positioned(
            bottom: 30.0,
            left: 16.0,
            child: GestureDetector(
              // FIX: Now modifies the state variable directly so it doesn't get instantly overwritten by the camera loop
              onTap: () => setState(() => isImageEnhancementEnabled = !isImageEnhancementEnabled),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isImageEnhancementEnabled
                      ? Colors.blueAccent.withValues(alpha: 0.85)
                      : Colors.grey[800]!.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black26,
                        blurRadius: 6,
                        offset: Offset(0, 2))
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.brightness_6,
                      color: isImageEnhancementEnabled
                          ? Colors.white
                          : Colors.white54,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isImageEnhancementEnabled
                          ? 'Enhance: ON'
                          : 'Enhance: OFF',
                      style: TextStyle(
                        color: isImageEnhancementEnabled
                            ? Colors.white
                            : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // --- HUD Card (Bottom Left, Toggleable via Settings) ---
          if (showLiveStatusHud)
            Positioned(
              bottom: 90.0,
              left: 16.0,
              child: _HudCard(
                faceDetected: _hudFaceDetected,
                eyeOpenness: _hudEyeOpenness,
                headTiltAngle: _hudHeadTiltAngle,
                enhancementOn: isImageEnhancementEnabled,
                safetyLevel: _hudSafetyLevel,
              ),
            ),

          // --- Floating Action Buttons (Bottom Right) ---
          Positioned(
            bottom: 30.0,
            right: 16.0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FloatingActionButton(
                  heroTag: "btn_locate",
                  backgroundColor: Colors.grey[900],
                  mini: true,
                  onPressed: () {
                    if (_currentLocation != null) {
                      _mapController.move(_currentLocation!, 16.0);
                    }
                  },
                  child: const Icon(Icons.my_location, color: Colors.blueAccent),
                ),
                const SizedBox(height: 12.0),
                FloatingActionButton(
                  heroTag: "btn_directions",
                  backgroundColor: Colors.blueAccent,
                  onPressed: () {
                    if (_destination != null) {
                      _getRoute();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                "Long-press on the map to drop a destination pin first!")),
                      );
                    }
                  },
                  child: const Icon(Icons.directions,
                      color: Colors.white, size: 28.0),
                ),
              ],
            ),
          ),

          // ==========================================
          // LAYER 3: HEAD POSE WARNING BANNER
          // ==========================================
          if (_headPoseWarning &&
              _headPoseWarningMessage != null &&
              !_isDrowsy)
            Positioned(
              top: 110.0,
              left: 16.0,
              right: 16.0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black38,
                        blurRadius: 8,
                        offset: Offset(0, 3))
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _headPoseWarningMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ==========================================
          // LAYER 4: FULL-SCREEN "WAKE UP" OVERLAY
          // ==========================================
          IgnorePointer(
            ignoring: !_isDrowsy,
            child: AnimatedOpacity(
              opacity: _isDrowsy ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                color: Colors.red.withValues(alpha: 0.85),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 100, color: Colors.white),
                      const SizedBox(height: 20),
                      Text(
                        _alertMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 2.0,
                        ),
                      ),
                      const SizedBox(height: 40),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 40, vertical: 20),
                        ),
                        onPressed: _wakeUpDriver,
                        child: const Text("I'M AWAKE",
                            style: TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold)),
                      )
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Custom Painter for Developer Mode
// Maps ML Kit bounding boxes and landmarks over the camera preview.
// ════════════════════════════════════════════════════════════════════════════
class FaceOverlayPainter extends CustomPainter {
  final Face face;
  final Size absoluteImageSize;

  FaceOverlayPainter(this.face, this.absoluteImageSize);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.greenAccent;

    // Scale factors to map the raw ML Kit coordinates to the UI rendering box
    final double scaleX = size.width / absoluteImageSize.width;
    final double scaleY = size.height / absoluteImageSize.height;

    // Draw the main bounding box around the face
    final rect = Rect.fromLTRB(
      face.boundingBox.left * scaleX,
      face.boundingBox.top * scaleY,
      face.boundingBox.right * scaleX,
      face.boundingBox.bottom * scaleY,
    );
    canvas.drawRect(rect, paint);

    // Draw red dots for all detected facial landmarks (eyes, nose, cheeks, etc.)
    final landmarkPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.redAccent;

    for (final landmark in face.landmarks.values) {
      // FIX: Check if the landmark is null before accessing its position
      if (landmark != null) {
        canvas.drawCircle(
          Offset(landmark.position.x.toDouble() * scaleX,
              landmark.position.y.toDouble() * scaleY),
          3,
          landmarkPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) {
    return oldDelegate.face != face || oldDelegate.absoluteImageSize != absoluteImageSize;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// HUD Card Widget
// ════════════════════════════════════════════════════════════════════════════
class _HudCard extends StatelessWidget {
  final bool faceDetected;
  final double eyeOpenness;
  final double headTiltAngle;
  final bool enhancementOn;
  final HeadPoseAlertLevel safetyLevel;

  const _HudCard({
    required this.faceDetected,
    required this.eyeOpenness,
    required this.headTiltAngle,
    required this.enhancementOn,
    required this.safetyLevel,
  });

  Color get _levelColor => switch (safetyLevel) {
    HeadPoseAlertLevel.safe     => const Color(0xFF4CAF50),
    HeadPoseAlertLevel.warning  => const Color(0xFFFF9800),
    HeadPoseAlertLevel.critical => const Color(0xFFF44336),
  };

  String get _levelLabel => switch (safetyLevel) {
    HeadPoseAlertLevel.safe     => 'SAFE',
    HeadPoseAlertLevel.warning  => 'WARNING',
    HeadPoseAlertLevel.critical => 'CRITICAL',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 210,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _levelColor.withValues(alpha: 0.55), width: 1.2),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.remove_red_eye, color: _levelColor, size: 13),
              const SizedBox(width: 5),
              Text(
                'IRIS  LIVE STATUS',
                style: TextStyle(
                  color: _levelColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 7),

          if (!faceDetected) ...[
            const _HudRow(
              icon: Icons.face_retouching_off,
              label: 'No face detected',
              valueWidget: SizedBox.shrink(),
              iconColor: Colors.white38,
            ),
          ] else ...[
            // Eye Openness
            _HudRow(
              icon: Icons.visibility,
              label: 'Eye openness',
              valueWidget: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 42,
                    height: 5,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: eyeOpenness.clamp(0.0, 1.0),
                        backgroundColor: Colors.white12,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          eyeOpenness > 0.4
                              ? Colors.greenAccent
                              : Colors.redAccent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${(eyeOpenness * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 5),

            // Head Tilt
            _HudRow(
              icon: Icons.rotate_right,
              label: 'Head tilt',
              valueWidget: Text(
                '${headTiltAngle.toStringAsFixed(1)}°',
                style: TextStyle(
                  color: headTiltAngle > 20
                      ? Colors.orangeAccent
                      : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],

          const SizedBox(height: 5),

          // Preprocessing Filter
          _HudRow(
            icon: Icons.brightness_6,
            label: 'Filter',
            valueWidget: Text(
              enhancementOn ? 'ON' : 'OFF',
              style: TextStyle(
                color: enhancementOn ? Colors.blueAccent : Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          const SizedBox(height: 7),
          const Divider(height: 1, color: Colors.white12),
          const SizedBox(height: 7),

          // Safety Alert Level
          Row(
            children: [
              Icon(Icons.shield, color: _levelColor, size: 12),
              const SizedBox(width: 5),
              Text(
                _levelLabel,
                style: TextStyle(
                  color: _levelColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HudRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget valueWidget;
  final Color iconColor;

  const _HudRow({
    required this.icon,
    required this.label,
    required this.valueWidget,
    this.iconColor = Colors.white38,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 11),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        const Spacer(),
        valueWidget,
      ],
    );
  }
}