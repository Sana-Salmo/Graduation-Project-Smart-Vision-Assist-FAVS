import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'settings_service.dart';

/// Confidence window for FL data collection.
///
/// Frames where the model is uncertain (above noise, below threshold) are
/// useful local examples because they represent cases the current model is not
/// fully confident about.
const double _kConfidenceLow = 0.05;
const double _kConfidenceHigh = 0.50;

/// Maximum locally stored samples and the demo round threshold.
const int kFlRoundSampleThreshold = 200;
const String _kLocalUpdateFileName = 'fl_local_update.json';

/// Handles privacy-preserving FL sample collection and update upload.
///
/// Raw camera frames and local JPEGs stay on-device. Firebase receives only a
/// compact mathematical update JSON generated from the local embeddings.
class FlSampleCollector {
  FlSampleCollector._();
  static final FlSampleCollector instance = FlSampleCollector._();

  Directory? _sampleDir;
  Future<File?>? _localUpdateFuture;
  final _sampleCountController = StreamController<int>.broadcast();

  Stream<int> get sampleCountStream => _sampleCountController.stream;

  Future<Directory> _dir() async {
    if (_sampleDir != null) return _sampleDir!;
    final base = await getApplicationDocumentsDirectory();
    _sampleDir = Directory('${base.path}/fl_samples')
      ..createSync(recursive: true);
    return _sampleDir!;
  }

  bool shouldSample(double confidence) {
    return sampleSkipReason(confidence) == null;
  }

  String? sampleSkipReason(double confidence) {
    if (!SettingsService.federatedLearningEnabled) {
      return 'Federated Learning is disabled';
    }
    if (confidence < _kConfidenceLow) {
      return 'confidence ${confidence.toStringAsFixed(3)} is below $_kConfidenceLow';
    }
    if (confidence > _kConfidenceHigh) {
      return 'confidence ${confidence.toStringAsFixed(3)} is above $_kConfidenceHigh';
    }
    return null;
  }

  Future<void> saveSample({
    required CameraImage frame,
    required Float32List embedding,
    required double confidence,
    required int topClassIdx,
  }) async {
    final skipReason = sampleSkipReason(confidence);
    if (skipReason != null) {
      debugPrint('[FL] Frame skipped because: $skipReason');
      return;
    }

    final snapshot = _CameraFrameSnapshot.fromCameraImage(frame);
    if (snapshot.planes.length < 3) {
      debugPrint('[FL] Frame skipped because: camera frame is not YUV420');
      return;
    }

    try {
      final dir = await _dir();
      await _enforceCapFifo(dir);

      final ts = DateTime.now().millisecondsSinceEpoch;
      final stem = 'frame_${ts}_conf${confidence.toStringAsFixed(2)}';

      await _saveJpeg(snapshot, dir, stem);
      await File('${dir.path}/$stem.json').writeAsString(
        jsonEncode({
          'timestamp': ts,
          'confidence': confidence,
          'top_class_idx': topClassIdx,
          'feature_vector': embedding.toList(),
        }),
        flush: true,
      );

      final count = await getSampleCount();
      debugPrint('[FL] Frame saved. New count: $count');
      _sampleCountController.add(count);
      if (count >= kFlRoundSampleThreshold) {
        unawaited(buildLocalUpdate(reason: 'threshold_reached'));
      }
    } catch (e) {
      debugPrint('[FL] Frame skipped because: storage write failed: $e');
    }
  }

  Future<int> getSampleCount() async {
    final dir = await _dir();
    return dir.listSync().whereType<File>().where(_isSampleJson).length;
  }

  Future<bool> hasReadyLocalUpdate() async {
    final dir = await _dir();
    return File('${dir.path}/$_kLocalUpdateFileName').exists();
  }

  Future<void> clearSamples() async {
    final dir = await _dir();
    for (final entity in dir.listSync()) {
      await entity.delete();
    }
    _sampleCountController.add(0);
  }

  /// Demo-safe local training: average 200 uncertain class-activation vectors.
  ///
  /// This produces one 80-dimensional local update, avoiding expensive
  /// backpropagation on the Helio G85 while preserving the FL story: local data
  /// influences the global model through a mathematical update, not images.
  Future<File?> buildLocalUpdate({String reason = 'manual'}) {
    if (!SettingsService.federatedLearningEnabled) {
      debugPrint(
        '[FL] Local update skipped because: Federated Learning is disabled',
      );
      return Future.value(null);
    }

    final inProgress = _localUpdateFuture;
    if (inProgress != null) {
      debugPrint('[FL] Local update build already running; waiting for it');
      return inProgress;
    }

    final future = _buildLocalUpdate(reason: reason);
    _localUpdateFuture = future;
    return future.whenComplete(() {
      _localUpdateFuture = null;
    });
  }

  Future<File?> _buildLocalUpdate({required String reason}) async {
    try {
      final dir = await _dir();
      final files =
          dir.listSync().whereType<File>().where(_isSampleJson).toList()..sort(
            (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
          );

      if (files.length < kFlRoundSampleThreshold) {
        debugPrint(
          '[FL] Local update skipped because: only ${files.length} / '
          '$kFlRoundSampleThreshold samples are available',
        );
        return null;
      }

      final sums = List<double>.filled(80, 0);
      final classCounts = List<int>.filled(80, 0);
      var sampleCount = 0;
      var confidenceSum = 0.0;

      for (final file in files.take(kFlRoundSampleThreshold)) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map<String, dynamic>) continue;
        final vector = raw['feature_vector'];
        if (vector is! List || vector.length < sums.length) continue;

        for (var i = 0; i < sums.length; i++) {
          sums[i] += (vector[i] as num).toDouble();
        }

        final classIdx = raw['top_class_idx'];
        if (classIdx is int && classIdx >= 0 && classIdx < classCounts.length) {
          classCounts[classIdx]++;
        }

        final confidence = raw['confidence'];
        if (confidence is num) confidenceSum += confidence.toDouble();
        sampleCount++;
      }

      if (sampleCount == 0) {
        debugPrint('[FL] Local update skipped because: no valid samples found');
        return null;
      }

      final update = {
        'schema_version': 1,
        'update_type': 'class_activation_average',
        'reason': reason,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'sample_count': sampleCount,
        'confidence_mean': confidenceSum / sampleCount,
        'local_weights': sums.map((value) => value / sampleCount).toList(),
        'class_counts': classCounts,
        'privacy': {
          'raw_images_uploaded': false,
          'per_frame_samples_uploaded': false,
          'local_jpegs_retained_on_device': true,
        },
      };

      final updateFile = File('${dir.path}/$_kLocalUpdateFileName');
      await updateFile.writeAsString(jsonEncode(update), flush: true);
      debugPrint('[FL] Local update built from $sampleCount samples');
      _sampleCountController.add(await getSampleCount());
      return updateFile;
    } catch (e) {
      debugPrint('[FL] Local update skipped because: build failed: $e');
      return null;
    }
  }

  /// Uploads only the compact local update to Firebase.
  Future<bool> uploadLocalUpdateToFirebase({
    bool rebuildIfNeeded = true,
  }) async {
    if (!SettingsService.federatedLearningEnabled) return false;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      debugPrint('[FL] Sync skipped because: user is not signed in');
      return false;
    }

    final dir = await _dir();
    var updateFile = File('${dir.path}/$_kLocalUpdateFileName');
    if (!await updateFile.exists() && rebuildIfNeeded) {
      debugPrint('[FL] No local update file yet; building before sync');
      updateFile = await buildLocalUpdate(reason: 'manual_sync') ?? updateFile;
    }
    if (!await updateFile.exists()) {
      debugPrint('[FL] Sync skipped because: local update file is missing');
      return false;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final rawUpdate = jsonDecode(await updateFile.readAsString());
    if (rawUpdate is! Map<String, dynamic>) {
      debugPrint('[FL] Sync skipped because: local update JSON is invalid');
      return false;
    }

    final docId = '${uid}_$timestamp';
    debugPrint(
      '[FL] Syncing local update to Firestore/fl_model_updates/$docId',
    );
    try {
      await FirebaseFirestore.instance
          .collection('fl_model_updates')
          .doc(docId)
          .set({
            ...rawUpdate,
            'uid': uid,
            'client_timestamp_ms': timestamp,
            'uploaded_at': FieldValue.serverTimestamp(),
            'source': 'android_app_firestore',
            'status': 'pending',
          }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      debugPrint(
        '[FL] Sync skipped because: Firestore update write failed '
        'code=${e.code} message=${e.message}',
      );
      return false;
    } catch (e) {
      debugPrint(
        '[FL] Sync skipped because: Firestore update write failed: $e',
      );
      return false;
    }

    debugPrint('[FL] Synced local update to Firestore/fl_model_updates/$docId');
    return true;
  }

  bool _isSampleJson(File file) {
    final name = file.uri.pathSegments.last;
    return name.endsWith('.json') && name != _kLocalUpdateFileName;
  }

  Future<void> _enforceCapFifo(Directory dir) async {
    final jsons = dir.listSync().whereType<File>().where(_isSampleJson).toList()
      ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));

    while (jsons.length >= kFlRoundSampleThreshold) {
      final oldest = jsons.removeAt(0);
      final stem = oldest.path.replaceAll('.json', '');
      await oldest.delete();
      final jpeg = File('$stem.jpg');
      if (await jpeg.exists()) await jpeg.delete();
    }
  }

  Future<void> _saveJpeg(
    _CameraFrameSnapshot frame,
    Directory dir,
    String stem,
  ) async {
    if (frame.planes.length < 3) return;
    final yBytes = frame.planes[0].bytes;
    final uBytes = frame.planes[1].bytes;
    final vBytes = frame.planes[2].bytes;
    final yRowStride = frame.planes[0].bytesPerRow;
    final uvRowStride = frame.planes[1].bytesPerRow;
    final uvPixelStride = frame.planes[1].bytesPerPixel ?? 1;
    final w = frame.width;
    final h = frame.height;

    final image = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final yIdx = y * yRowStride + x;
        final uvIdx = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;
        final yVal = yBytes[yIdx];
        final uVal = uBytes[uvIdx] - 128;
        final vVal = vBytes[uvIdx] - 128;
        final r = (yVal + 1.370705 * vVal).clamp(0, 255).toInt();
        final g = (yVal - 0.698001 * vVal - 0.337633 * uVal)
            .clamp(0, 255)
            .toInt();
        final b = (yVal + 1.732446 * uVal).clamp(0, 255).toInt();
        image.setPixelRgb(x, y, r, g, b);
      }
    }

    final resized = img.copyResize(image, width: 320, height: 320);
    final jpeg = img.encodeJpg(resized, quality: 70);
    await File('${dir.path}/$stem.jpg').writeAsBytes(jpeg, flush: true);
  }
}

class _CameraFrameSnapshot {
  final int width;
  final int height;
  final List<_PlaneSnapshot> planes;

  const _CameraFrameSnapshot({
    required this.width,
    required this.height,
    required this.planes,
  });

  factory _CameraFrameSnapshot.fromCameraImage(CameraImage frame) {
    return _CameraFrameSnapshot(
      width: frame.width,
      height: frame.height,
      planes: frame.planes
          .map(
            (plane) => _PlaneSnapshot(
              bytes: Uint8List.fromList(plane.bytes),
              bytesPerRow: plane.bytesPerRow,
              bytesPerPixel: plane.bytesPerPixel,
            ),
          )
          .toList(growable: false),
    );
  }
}

class _PlaneSnapshot {
  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;

  const _PlaneSnapshot({
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });
}
