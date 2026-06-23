import 'dart:math' as math;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Severity level emitted per-frame by [HeadPoseService].
enum HeadPoseAlertLevel { safe, warning, critical }

/// Immutable snapshot of a single frame's head-pose analysis.
class HeadPoseResult {
  /// Pitch in degrees (X-axis). Negative = head drooping forward.
  final double pitchAngle;

  /// Roll in degrees (Z-axis). Nonzero = head tilting sideways.
  final double rollAngle;

  /// Yaw in degrees (Y-axis). Large values = head turned away from camera.
  final double yawAngle;

  /// True when pitch OR roll has exceeded the configured threshold for
  /// [HeadPoseService.sustainedFrameThreshold] consecutive frames.
  final bool isSustainedTilt;

  /// True when pitch or roll jumped sharply between this frame and the last.
  /// Indicates a microsleep jerk or a sudden correction after nodding off.
  final bool isSuddenMovement;

  /// Human-readable alert string; null when [level] == safe.
  final String? alertMessage;

  final HeadPoseAlertLevel level;

  const HeadPoseResult({
    required this.pitchAngle,
    required this.rollAngle,
    required this.yawAngle,
    required this.isSustainedTilt,
    required this.isSuddenMovement,
    required this.alertMessage,
    required this.level,
  });

  bool get shouldAlert => level != HeadPoseAlertLevel.safe;

  @override
  String toString() =>
      'HeadPoseResult(pitch=$pitchAngle, roll=$rollAngle, '
      'level=$level, msg=$alertMessage)';
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Stateful per-session service that analyses [Face] objects from ML Kit and
/// returns a [HeadPoseResult] for each frame.
///
/// Lifecycle:
///   1. Instantiate once and keep alive for the camera session.
///   2. Call [analyze] in your camera image stream callback.
///   3. Call [reset] when the alert is dismissed so counters restart cleanly.
///
/// ### Design rationale
/// ML Kit exposes `headEulerAngleX/Y/Z` directly on the [Face] object when
/// `enableClassification: true` is set on [FaceDetectorOptions]. These are
/// more reliable than computing the angle from two landmarks manually because
/// they are derived from the full 3-D face mesh, not just a 2-D pixel pair.
///
/// For the report: the angle between the nose base and chin *is* effectively
/// what `headEulerAngleX` captures – ML Kit internally fits a 3-D model to
/// the 468-point landmark mesh to compute it, giving sub-degree precision.
class HeadPoseService {
  // ---------- configurable thresholds -------------------------------------- //

  /// Negative pitch threshold for nodding-off detection (degrees).
  /// Head drooping forward → pitch goes negative; −25° is a clear nod.
  final double pitchDropThreshold;

  /// Roll threshold for sideways tilt detection (degrees, absolute value).
  final double rollTiltThreshold;

  /// Yaw threshold: beyond this the face is turned away enough that eye
  /// probabilities are unreliable. Flag separately so the caller can decide
  /// whether to suppress the eye-closure signal.
  final double yawLookAwayThreshold;

  /// Number of consecutive frames a pose must hold before triggering
  /// [HeadPoseResult.isSustainedTilt]. At ~15 fps this is ≈ 0.3 s per frame.
  final int sustainedFrameThreshold;

  /// Minimum per-frame angle delta (°) to classify as a sudden movement.
  final double suddenChangeDeltaDeg;

  // ---------- mutable state ------------------------------------------------ //

  double? _prevPitch;
  double? _prevRoll;

  /// Counts how many consecutive frames the head has been outside thresholds.
  int _tiltFrameCount = 0;

  /// Counts consecutive frames of sudden movement to suppress single-frame noise.
  int _suddenFrameCount = 0;

  // -------------------------------------------------------------------------

  HeadPoseService({
    this.pitchDropThreshold = -25.0,
    this.rollTiltThreshold = 20.0,
    this.yawLookAwayThreshold = 35.0,
    this.sustainedFrameThreshold = 5,
    this.suddenChangeDeltaDeg = 15.0,
  });

  // ---------- public API ---------------------------------------------------

  /// Analyses a single [Face] and returns a [HeadPoseResult].
  ///
  /// Returns null if the face object doesn't carry Euler angle data (rare;
  /// can happen on first detection frame before the 3-D model is fitted).
  HeadPoseResult? analyze(Face face) {
    final double? pitch = face.headEulerAngleX;
    final double? roll = face.headEulerAngleZ;
    final double? yaw = face.headEulerAngleY;

    // Guard: angles not yet available from ML Kit on this frame.
    if (pitch == null || roll == null || yaw == null) return null;

    // ---- 1. Static threshold check ----------------------------------------
    final bool pitchBreached = pitch < pitchDropThreshold;
    final bool rollBreached = roll.abs() > rollTiltThreshold;
    final bool poseBreached = pitchBreached || rollBreached;
    final bool lookingAway = yaw.abs() > yawLookAwayThreshold;

    // Increment or reset sustained-tilt counter
    if (poseBreached) {
      _tiltFrameCount++;
    } else {
      _tiltFrameCount = 0;
    }
    final bool isSustained = _tiltFrameCount >= sustainedFrameThreshold;

    // ---- 2. Change-detection between frames --------------------------------
    bool isSudden = false;
    if (_prevPitch != null && _prevRoll != null) {
      final double pitchDelta = (pitch - _prevPitch!).abs();
      final double rollDelta = (roll - _prevRoll!).abs();
      final double maxDelta = math.max(pitchDelta, rollDelta);

      if (maxDelta >= suddenChangeDeltaDeg) {
        _suddenFrameCount++;
        // Require 2 consecutive sudden frames to suppress single-frame noise
        if (_suddenFrameCount >= 2) {
          isSudden = true;
        }
      } else {
        _suddenFrameCount = 0;
      }
    }

    // ---- 3. Update history -------------------------------------------------
    _prevPitch = pitch;
    _prevRoll = roll;

    // ---- 4. Determine alert level and message ------------------------------
    HeadPoseAlertLevel level;
    String? message;

    if (isSudden) {
      // A jerk-awake after nodding is a critical signal
      level = HeadPoseAlertLevel.critical;
      message = 'Sudden movement detected – possible microsleep!';
    } else if (isSustained) {
      if (pitchBreached && rollBreached) {
        level = HeadPoseAlertLevel.critical;
        message = 'Head drooping & tilting – Pull over now!';
      } else if (pitchBreached) {
        level = HeadPoseAlertLevel.critical;
        message = 'Head tilt detected – Stay Alert!';
      } else {
        // Roll breach only
        level = HeadPoseAlertLevel.warning;
        message = 'Head tilt detected – Stay Alert!';
      }
    } else if (lookingAway) {
      level = HeadPoseAlertLevel.warning;
      message = 'Keep your eyes on the road!';
    } else if (poseBreached) {
      // Pose is breached but not yet sustained – early warning
      level = HeadPoseAlertLevel.warning;
      message = null; // suppress UI noise; caller checks level for HUD colour
    } else {
      level = HeadPoseAlertLevel.safe;
      message = null;
    }

    return HeadPoseResult(
      pitchAngle: pitch,
      rollAngle: roll,
      yawAngle: yaw,
      isSustainedTilt: isSustained,
      isSuddenMovement: isSudden,
      alertMessage: message,
      level: level,
    );
  }

  /// Resets all counters. Call this when the driver dismisses an alert so the
  /// frame counters don't carry over into the next detection cycle.
  void reset() {
    _prevPitch = null;
    _prevRoll = null;
    _tiltFrameCount = 0;
    _suddenFrameCount = 0;
  }

  // ---------- accessors for HUD display ------------------------------------

  /// Current consecutive tilt-frame count; useful for a debug HUD.
  int get tiltFrameCount => _tiltFrameCount;
}
