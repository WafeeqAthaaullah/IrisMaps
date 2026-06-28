import 'package:tflite_flutter/tflite_flutter.dart';

class EyeClassifierService {
  Interpreter? _interpreter;

  /// Loads the TFLite model from the assets folder
  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/eye_classifier.tflite');
      print('Eye classifier model loaded successfully.');
    } catch (e) {
      print('Failed to load model: $e');
    }
  }

  /// Runs inference on a 24x24 cropped eye image
  /// Returns 1 (open) or 0 (closed)
  Future<int> classifyEye(List<List<List<List<double>>>> inputCrop) async {
    if (_interpreter == null) {
      print('Interpreter is not initialized.');
      return -1; 
    }

    // Since our output layer is a single Dense node with a sigmoid activation,
    // the output shape will be [1, 1].
    var output = List.filled(1 * 1, 0.0).reshape([1, 1]);

    // Run the model
    _interpreter!.run(inputCrop, output);

    // Interpret the sigmoid output (threshold at 0.5)
    double prediction = output[0][0];
    return prediction >= 0.5 ? 1 : 0; 
  }

  /// Closes the interpreter to free up resources
  void dispose() {
    _interpreter?.close();
  }
}

  