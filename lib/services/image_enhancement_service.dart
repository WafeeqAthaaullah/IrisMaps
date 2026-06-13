import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageEnhancementService {
  bool isEnabled = true;

  /// Enhances NV21 (Android) or BGRA8888 (iOS) raw camera bytes.
  /// Only boosts brightness/contrast when the frame is dark.
  /// Returns original bytes untouched if enhancement is off or fails.
  Uint8List enhanceIfDark(
    Uint8List inputBytes,
    int width,
    int height, {
    int darknessThreshold = 85,
    int brightnessBoost = 25,
    double contrastBoost = 1.25,
  }) {
    if (!isEnabled) return inputBytes;

    try {
      // Sample brightness from raw bytes directly (fast - no full decode needed)
      double avgBrightness = _sampleBrightnessNV21(inputBytes, width, height);

      // Only enhance if dark enough to matter
      if (avgBrightness >= darknessThreshold) return inputBytes;

      // Decode full image for processing
      img.Image? image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: inputBytes.buffer,
        format: img.Format.uint8,
        numChannels: 1, // Y plane only (luminance)
      );

      if (image == null) return inputBytes;

      // Apply brightness then contrast
      image = img.adjustColor(
        image,
        brightness: brightnessBoost / 255.0,
        contrast: contrastBoost,
      );

      return image.toUint8List();
    } catch (e) {
      // Never crash the camera stream
      return inputBytes;
    }
  }

  /// Samples every 20th pixel of the Y plane (luminance) for speed.
  /// NV21 format: first width*height bytes are the Y (brightness) plane.
  double _sampleBrightnessNV21(Uint8List bytes, int width, int height) {
    double total = 0;
    int count = 0;
    int yPlaneSize = width * height;
    int step = 20;

    for (int i = 0; i < yPlaneSize; i += step) {
      total += bytes[i] & 0xFF;
      count++;
    }

    return count > 0 ? total / count : 128.0;
  }

  void toggle() => isEnabled = !isEnabled;
}