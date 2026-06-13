import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:convert';
import 'package:iris_maps/services/image_enhancement_service.dart';
import 'package:http/http.dart' as http;
// Ensure you have this for MapController

void main() async {
  // Ensure Flutter is fully initialized before grabbing the camera
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
  // Search State
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  bool _isSearching = false;
  final ImageEnhancementService _enhancementService = ImageEnhancementService();

  // ML Kit & Camera State
  CameraController? _cameraController;
  late final FaceDetector _faceDetector;
  bool _isProcessingImage = false;

  @override
  void initState() {
    super.initState();
    _getUserLocation();
    _initializeSilentCamera();

    // Initialize ML Kit Face Detector with high performance settings
    final options = FaceDetectorOptions(
      enableClassification: true, // REQUIRED: This gives us the eye open probability
      enableTracking: true,
      performanceMode: FaceDetectorMode.fast,
    );
    _faceDetector = FaceDetector(options: options);
  }

  Future<void> _getUserLocation() async {
    // [Keep your exact same Geolocator code here from the previous step]
    Position position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
      _isLoadingMap = false;
    });
  }

  Future<void> _getRoute() async {
    if (_currentLocation == null || _destination == null) return;

    final start = _currentLocation!;
    final end = _destination!;

    final url = 'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?geometries=geojson';

    try {
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // --- THE FIX: Ensure OSRM actually found a valid road ---
        if (data['code'] == 'Ok' && data['routes'] != null && data['routes'].isNotEmpty) {
          final List coordinates = data['routes'][0]['geometry']['coordinates'];
          
          if (!mounted) return; // Crash prevention if UI state changed

          setState(() {
            _routePoints = coordinates.map((coord) {
              return LatLng(
                (coord[1] as num).toDouble(), 
                (coord[0] as num).toDouble()
              );
            }).toList();
          });
        } else {
          // If no route is found (like tapping in the ocean), just ignore it instead of crashing
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

    // Ask the free Nominatim API for up to 5 matching locations
    final url = Uri.parse('https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=5');

    try {
      final response = await http.get(url, headers: {'User-Agent': 'IrisMapsApp/1.0'});
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
    // Find the selfie camera
    final frontCamera = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front);

    _cameraController = CameraController(
    frontCamera, 
    ResolutionPreset.low, 
    enableAudio: false,
    // --- THE FIX: Force the camera to output AI-compatible pixels ---
    imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    await _cameraController!.initialize();
    
    // Initialize the camera silently (ResolutionPreset.low saves battery!)
    _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessingImage) return; 
      _isProcessingImage = true;

      // 1. Convert CameraImage to ML Kit InputImage
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }

      final rawBytes = allBytes.done().buffer.asUint8List();

      final bytes = _enhancementService.enhanceIfDark(
        rawBytes,
        image.width,
        image.height,
      );

      final Size imageSize = Size(image.width.toDouble(), image.height.toDouble());
      
      // Note: For Android front camera, the rotation is usually 270
      const imageRotation = InputImageRotation.rotation270deg;
      
      final inputImageFormat = Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;
      final inputImageData = InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      );

      final inputImage = InputImage.fromBytes(bytes: bytes, metadata: inputImageData);

      // 2. Process the image with the Face Detector
      final faces = await _faceDetector.processImage(inputImage);

      // --- ADD THIS PRINT STATEMENT ---
      print("AI VISION: Found ${faces.length} faces."); 

      // 3. The REAL Drowsiness Logic
      if (faces.isNotEmpty) {
        final face = faces.first;
        
        // --- ADD THIS PRINT STATEMENT ---
        print("EYES -> Left: ${face.leftEyeOpenProbability}, Right: ${face.rightEyeOpenProbability}");

        if (face.leftEyeOpenProbability != null && face.rightEyeOpenProbability != null) {
          // Let's make it hyper-sensitive for testing (under 40% open instead of 20%)
          if (face.leftEyeOpenProbability! < 0.4 && face.rightEyeOpenProbability! < 0.4) {
            _closedEyeFrames++; 
            print("WARNING: Eyes closing! Frame $_closedEyeFrames"); // --- ADD THIS ---
            
            // Lower the threshold to just 3 frames (roughly 1/4 of a second)
            if (_closedEyeFrames >= 3) { 
              _triggerDrowsiness(); 
            }
          } else {
            _closedEyeFrames = 0; 
          }
        }
      }

      _isProcessingImage = false;
    });
  }

  // --- NEW: The Alarm Logic ---
  void _triggerDrowsiness() async {
    if (!_isDrowsy) {
      setState(() => _isDrowsy = true);
      // Play a harsh, repeating alarm
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      // Note: Add an 'alarm.mp3' to your flutter assets folder!
      await _audioPlayer.play(AssetSource('alarm.mp3')); 
    }
  }

  void _wakeUpDriver() async {
    if (_isDrowsy) {
      setState(() => _isDrowsy = false);
      await _audioPlayer.stop();
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector.close();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 1. This tells Flutter to let the map bleed behind the phone's status bar (battery/time)
      extendBodyBehindAppBar: true, 
      body: Stack(
        children: [
// ==========================================
          // LAYER 1: THE FULL SCREEN MAP
          // ==========================================
          _isLoadingMap
              ? const Center(child: CircularProgressIndicator())
              : FlutterMap(
                  mapController: _mapController, // <-- Attach the controller here
                  options: MapOptions(
                    initialCenter: _currentLocation ?? const LatLng(0, 0),
                    initialZoom: 16.0,
                    minZoom: 3.0,
                    maxZoom: 18.0,
                    // --- NEW: Long press to drop a destination pin ---
                    onLongPress: (tapPosition, point) {
                      setState(() {
                        _destination = point;
                        _routePoints.clear(); // Clear the old line
                      });
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.irismaps',
                    ),
                    // --- NEW: The Route Line ---
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
                    // The Markers (You and the Destination)
                    MarkerLayer(
                      markers: [
                        // You
                        if (_currentLocation != null)
                          Marker(
                            point: _currentLocation!,
                            width: 60,
                            height: 60,
                            child: const Icon(Icons.navigation, color: Colors.blueAccent, size: 40),
                          ),
                        // The Destination
                        if (_destination != null)
                          Marker(
                            point: _destination!,
                            width: 60,
                            height: 60,
                            child: const Icon(Icons.location_on, color: Colors.redAccent, size: 40),
                          ),
                      ],
                    ),
                  ],
                ),

          // ==========================================
          // LAYER 2: GOOGLE MAPS UI (Floating Elements)
          // ==========================================
          
          // --- Floating Search Bar (Top) ---
          Positioned(
            top: 50.0,
            left: 16.0,
            right: 16.0,
            child: Column(
              children: [
                // 1. The Input Field
                Container(
                  height: 50.0,
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(25.0),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 8.0, offset: Offset(0, 3))
                    ],
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.menu, color: Colors.white70),
                        onPressed: () {}, 
                      ),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: "Search here",
                            hintStyle: TextStyle(color: Colors.white54),
                            border: InputBorder.none, // Removes the ugly default underline
                          ),
                          onSubmitted: _searchPlaces, // Triggers the search when you hit 'Enter' on keyboard
                        ),
                      ),
                      _isSearching 
                        ? const Padding(
                            padding: EdgeInsets.all(12.0),
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            icon: const Icon(Icons.search, color: Colors.white70),
                            onPressed: () => _searchPlaces(_searchController.text),
                          ),
                    ],
                  ),
                ),
                
                // 2. The Dropdown Results
                if (_searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 8.0),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(15.0),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 8.0, offset: Offset(0, 3))
                      ],
                    ),
                    // Constrain the height so it doesn't take up the whole screen
                    constraints: const BoxConstraints(maxHeight: 250), 
                    child: ListView.separated(
                      shrinkWrap: true, // Tells the list to only be as tall as its children
                      padding: EdgeInsets.zero,
                      itemCount: _searchResults.length,
                      separatorBuilder: (context, index) => const Divider(height: 1, color: Colors.white24),
                      itemBuilder: (context, index) {
                        final result = _searchResults[index];
                        return ListTile(
                          leading: const Icon(Icons.location_on, color: Colors.white54),
                          title: Text(
                            result['display_name'],
                            style: const TextStyle(color: Colors.white),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            // When the user taps a result:
                            final lat = double.parse(result['lat']);
                            final lon = double.parse(result['lon']);
                            final location = LatLng(lat, lon);

                            setState(() {
                              _destination = location;           // Drop the pin
                              _routePoints.clear();              // Clear old route
                              _searchResults.clear();            // Hide the dropdown menu
                              _searchController.text = result['name'] ?? ''; // Update text bar
                            });

                            // Fly the camera to the new destination!
                            _mapController.move(location, 15.0);
                            
                            // Dismiss the keyboard
                            FocusScope.of(context).unfocus();
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          // --- Enhancement Toggle Button (Bottom Left) ---
          Positioned(
            bottom: 30.0,
            left: 16.0,
            child: GestureDetector(
              onTap: () => setState(() => _enhancementService.toggle()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _enhancementService.isEnabled
                      ? Colors.blueAccent.withValues(alpha: 0.85)
                      : Colors.grey[800]!.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.brightness_6,
                      color: _enhancementService.isEnabled ? Colors.white : Colors.white54,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _enhancementService.isEnabled ? 'Enhance: ON' : 'Enhance: OFF',
                      style: TextStyle(
                        color: _enhancementService.isEnabled ? Colors.white : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          
          // --- Floating Action Buttons (Bottom Right) ---
          Positioned(
            bottom: 30.0,
            right: 16.0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
// 'Center on Me' Button
                FloatingActionButton(
                  heroTag: "btn_locate",
                  backgroundColor: Colors.grey[900],
                  mini: true,
                  onPressed: () {
                    if (_currentLocation != null) {
                      // Tell the map controller to fly back to your GPS location
                      _mapController.move(_currentLocation!, 16.0);
                    }
                  },
                  child: const Icon(Icons.my_location, color: Colors.blueAccent),
                ),
                const SizedBox(height: 12.0),
                // 'Directions' Button
                FloatingActionButton(
                  heroTag: "btn_directions",
                  backgroundColor: Colors.blueAccent,
                  onPressed: () {
                    // Trigger the routing math
                    if (_destination != null) {
                      _getRoute();
                    } else {
                      // Optional: Show a quick popup telling them to drop a pin first
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Long-press on the map to drop a destination pin first!")),
                      );
                    }
                  },
                  child: const Icon(Icons.directions, color: Colors.white, size: 28.0),
                ),
              ],
            ),
          ),

          // ==========================================
          // LAYER 3: THE AI "WAKE UP" OVERLAY
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
                      const Icon(Icons.warning_amber_rounded, size: 100, color: Colors.white),
                      const SizedBox(height: 20),
                      const Text(
                        "WAKE UP!",
                        style: TextStyle(
                          fontSize: 60,
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
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                        ),
                        onPressed: _wakeUpDriver, 
                        child: const Text("I'M AWAKE", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
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