import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../core/config/app_config.dart';
import 'federated_learning_service.dart';
import 'fl_sample_collector.dart';

class ObstacleDetectionService {
  Interpreter? _interpreter;
  List<String> _labels = const [];
  bool _labelsLoadedFromModelMetadata = false;
  bool _debugFrameSaved = false;
  int _diagnosticFrameCount = 0;
  _DetectorKind _detectorKind = _DetectorKind.unknown;
  TensorType _inputType = TensorType.float32;
  int _inputSize = 320;
  static const _debugImageChannel = MethodChannel(
    'smart_vision_app/debug_images',
  );

  // Demo threshold: high enough to suppress weak false positives, low enough
  // for EfficientDet Lite0 to keep detecting common indoor obstacles.
  static const double _confidenceThreshold = 0.35;
  static const double _iouThreshold = 0.50;

  // How strongly the FL global prior boosts per-class scores.
  // A value of 0.10 means a class with global_weight=0.44 gets a +0.044 boost,
  // enough to lift a near-threshold detection (e.g. 0.41 → 0.454) over the line.
  static const double _kFlPriorStrength = 0.10;

  // Classes that warrant a danger-level alert.
  static const _dangerousClasses = {
    'person',
    'car',
    'motorcycle',
    'bus',
    'truck',
    'bicycle',
    'traffic light',
    'stop sign',
  };

  bool get isReady => _interpreter != null;
  double get lastBestScore => _lastBestScore;
  String get lastBestLabel => _lastBestLabel;

  double _lastBestScore = 0;
  String _lastBestLabel = 'object';

  // ── Initialisation ────────────────────────────────────────────────────────

  // Minimum expected model size in bytes. Re-extract if cached file is smaller.
  static const _minModelBytes = 1024 * 1024; // 1 MB
  // Bump this version string whenever the model file changes or the TFLite
  // runtime is upgraded — forces a re-extract on the next launch.
  static const _modelVersion =
      'v6'; // bumped to force extraction after model swaps

  Future<void> initialize() async {
    if (_interpreter != null) return;
    try {
      final appDir = await getApplicationSupportDirectory();
      // Version suffix forces a fresh extract whenever _modelVersion changes.
      final assetName = AppConfig.obstacleModelAsset.split('/').last;
      final modelFile = File('${appDir.path}/${_modelVersion}_$assetName');

      // Extract the asset the first time, or whenever the cached file looks
      // truncated/corrupt (e.g. after a failed previous write).
      final needsExtract =
          !modelFile.existsSync() || modelFile.lengthSync() < _minModelBytes;

      if (needsExtract) {
        debugPrint('[TFLite] Extracting model to ${modelFile.path}');
        final modelData = await rootBundle.load(AppConfig.obstacleModelAsset);
        final bytes = modelData.buffer.asUint8List(
          modelData.offsetInBytes,
          modelData.lengthInBytes,
        );
        _validateTfliteBytes(bytes);
        final tempFile = File('${modelFile.path}.tmp');
        await tempFile.writeAsBytes(bytes, flush: true);
        if (modelFile.existsSync()) await modelFile.delete();
        await tempFile.rename(modelFile.path);
        debugPrint('[TFLite] Wrote ${bytes.length} bytes');
      } else {
        _validateTfliteBytes(await modelFile.readAsBytes());
        debugPrint(
          '[TFLite] Cache hit: ${modelFile.path} '
          '(${modelFile.lengthSync()} bytes)',
        );
      }

      debugPrint('[TFLite] Loading from file: ${modelFile.path}');
      final options = InterpreterOptions()..threads = 1;
      _interpreter = Interpreter.fromFile(modelFile, options: options);
      debugPrint('[TFLite] Standard CPU interpreter enabled (1 thread)');
      _logTensorInfo();
      _configureModelContract();
      final labelLoadResult = await _loadLabels();
      _labels = labelLoadResult.labels;
      _labelsLoadedFromModelMetadata = labelLoadResult.fromModelMetadata;
      debugPrint('[TFLite] Interpreter ready ✓');
    } on FileSystemException catch (e) {
      throw ObstacleDetectionException(
        'Could not write model to device storage: $e',
      );
    } on ArgumentError catch (e) {
      throw ObstacleDetectionException('TFLite rejected the model file: $e');
    } on FlutterError catch (e) {
      throw ObstacleDetectionException(
        'Asset bundle error — ensure assets/ml/ is in pubspec.yaml: $e',
      );
    } catch (e) {
      throw ObstacleDetectionException(
        'Unable to initialise obstacle model: $e',
      );
    }
  }

  static void _validateTfliteBytes(Uint8List bytes) {
    if (bytes.length < _minModelBytes) {
      throw ArgumentError('Model asset is too small (${bytes.length} bytes).');
    }

    final isElf =
        bytes.length > 4 &&
        bytes[0] == 0x7f &&
        bytes[1] == 0x45 &&
        bytes[2] == 0x4c &&
        bytes[3] == 0x46;
    if (isElf) {
      throw ArgumentError(
        'Model asset is an ELF native library, not a TFLite model. '
        'Replace assets/ml/Yolo-v8-Detection.tflite with a real YOLOv8 .tflite FlatBuffer export.',
      );
    }

    final hasTfl3 =
        bytes.length > 8 &&
        bytes[4] == 0x54 &&
        bytes[5] == 0x46 &&
        bytes[6] == 0x4c &&
        bytes[7] == 0x33;
    if (!hasTfl3) {
      throw ArgumentError('Model asset does not contain the TFL3 signature.');
    }
  }

  // ── Inference ─────────────────────────────────────────────────────────────

  /// Full YOLOv8n pipeline on a live [CameraImage] (YUV420 format, Android).
  ///
  /// Pre-processing (YUV→RGB, resize 640×640, normalise) runs in a background
  /// isolate via [compute] so the UI thread is never blocked.
  /// TFLite inference then runs on the calling thread (interpreters are
  /// single-threaded resources and cannot be shared across isolates).
  Future<List<DetectedObstacle>> detectFromCamera(
    CameraImage frame, {
    int sensorOrientation = 0,
  }) async {
    final totalWatch = Stopwatch()..start();
    await initialize();
    if (_interpreter == null) return const [];

    // Requires 3 YUV420 planes; bail out for other formats (e.g. BGRA on iOS).
    if (frame.planes.length < 3) return const [];

    final debugImagePath = _debugFrameSaved
        ? null
        : await _nextDebugFramePath();
    if (debugImagePath != null) _debugFrameSaved = true;

    // Step 1: YUV420 → RGB → upright 640×640 → Float32 [1*640*640*3].
    // Copy plane bytes immediately — the camera driver may recycle the buffer.
    final preprocessWatch = Stopwatch()..start();
    final preprocessed = await compute(
      _preprocessFrame,
      _FrameArgs(
        yBytes: Uint8List.fromList(frame.planes[0].bytes),
        uBytes: Uint8List.fromList(frame.planes[1].bytes),
        vBytes: Uint8List.fromList(frame.planes[2].bytes),
        srcWidth: frame.width,
        srcHeight: frame.height,
        yRowStride: frame.planes[0].bytesPerRow,
        uvRowStride: frame.planes[1].bytesPerRow,
        uvPixelStride: frame.planes[1].bytesPerPixel ?? 1,
        inputSize: _inputSize,
        sensorOrientation: sensorOrientation,
        debugImagePath: debugImagePath,
        normalize: _inputType == TensorType.float32,
        preserveAspectRatio: _detectorKind == _DetectorKind.yolo,
      ),
    );
    preprocessWatch.stop();
    if (preprocessed.debugImagePath != null) {
      final galleryUri = await _publishDebugImage(preprocessed.debugImagePath!);
      debugPrint(
        '[TFLite] Saved preprocessed detector input: '
        '${preprocessed.debugImagePath}',
      );
      if (galleryUri != null) {
        debugPrint('[TFLite] Published debug image to Gallery: $galleryUri');
      }
    }

    // Guard: dispose() may have closed the interpreter during the async gap.
    if (_interpreter == null) return const [];

    // Step 2: pass the flat typed buffer directly to TFLite. The interpreter
    // already knows the tensor shape from the model contract. Uint8List does
    // not support reshape(), and forcing a nested 4D list would add avoidable
    // allocations on the Samsung A06.
    final inputTensor = preprocessed.tensor;

    if (_detectorKind == _DetectorKind.ssd) {
      final detections = _runSsd(inputTensor, frame);
      totalWatch.stop();
      debugPrint(
        '[TFLite] Frame complete: preprocess=${preprocessWatch.elapsedMilliseconds}ms '
        'total=${totalWatch.elapsedMilliseconds}ms detections=${detections.length}',
      );
      return detections;
    }

    if (_detectorKind == _DetectorKind.yolo) {
      final rawOutput = _runYolo(inputTensor);
      _maybeCollectSample(frame, rawOutput);
      final detections = _postprocess(rawOutput);
      totalWatch.stop();
      debugPrint(
        '[TFLite] Frame complete: preprocess=${preprocessWatch.elapsedMilliseconds}ms '
        'total=${totalWatch.elapsedMilliseconds}ms detections=${detections.length}',
      );
      return detections;
    }

    throw const ObstacleDetectionException(
      'Unsupported object detection model. Use EfficientDet/SSD or YOLOv8 TFLite.',
    );
  }

  Future<String?> _nextDebugFramePath() async {
    try {
      final appDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      return '${appDir.path}/yolo_preprocessed_debug_$timestamp.jpg';
    } catch (_) {
      return null;
    }
  }

  Future<String?> _publishDebugImage(String sourcePath) async {
    try {
      final result = await _debugImageChannel.invokeMethod<String>(
        'saveToGallery',
        <String, Object?>{
          'sourcePath': sourcePath,
          'displayName':
              'smart_vision_yolo_debug_${DateTime.now().millisecondsSinceEpoch}.jpg',
        },
      );
      return result;
    } catch (e) {
      debugPrint('[TFLite] Could not publish debug image to Gallery: $e');
      return null;
    }
  }

  void _logTensorInfo() {
    if (_interpreter == null) return;
    for (final tensor in _interpreter!.getInputTensors()) {
      debugPrint(
        '[TFLite] Input: ${tensor.name} ${tensor.type} ${tensor.shape}',
      );
    }
    for (final tensor in _interpreter!.getOutputTensors()) {
      debugPrint(
        '[TFLite] Output: ${tensor.name} ${tensor.type} ${tensor.shape}',
      );
    }
  }

  void _configureModelContract() {
    if (_interpreter == null) return;

    final input = _interpreter!.getInputTensor(0);
    _inputType = input.type;
    final shape = input.shape;
    if (shape.length >= 4) {
      _inputSize = shape[1] == 1 ? shape[2] : shape[1];
    }

    final outputs = _interpreter!.getOutputTensors();
    final hasSsdOutputs =
        outputs.length >= 4 &&
        outputs.any((t) => t.shape.length == 3 && t.shape.last == 4);
    final firstOutputShape = outputs.isNotEmpty
        ? outputs.first.shape
        : const [];
    final hasYoloOutput =
        outputs.length == 1 &&
        firstOutputShape.length == 3 &&
        (firstOutputShape[1] > 4 || firstOutputShape[2] > 4);

    if (hasSsdOutputs) {
      _detectorKind = _DetectorKind.ssd;
    } else if (hasYoloOutput) {
      _detectorKind = _DetectorKind.yolo;
    } else {
      _detectorKind = _DetectorKind.unknown;
    }

    debugPrint(
      '[TFLite] Detector kind: $_detectorKind inputSize=$_inputSize inputType=$_inputType',
    );
  }

  List<Float32List> _runYolo(Object inputTensor) {
    final shape = _interpreter!.getOutputTensor(0).shape;
    if (shape.length != 3) {
      throw ObstacleDetectionException('Unsupported YOLO output shape: $shape');
    }

    final dim1 = shape[1];
    final dim2 = shape[2];

    if (dim1 <= 256 && dim2 > dim1) {
      final output = [List.generate(dim1, (_) => Float32List(dim2))];
      _interpreter!.run(inputTensor, output);
      return output[0];
    }

    if (dim2 <= 256 && dim1 > dim2) {
      final output = [List.generate(dim1, (_) => Float32List(dim2))];
      _interpreter!.run(inputTensor, output);
      final transposed = List.generate(dim2, (_) => Float32List(dim1));
      for (int anchor = 0; anchor < dim1; anchor++) {
        for (int channel = 0; channel < dim2; channel++) {
          transposed[channel][anchor] = output[0][anchor][channel];
        }
      }
      return transposed;
    }

    throw ObstacleDetectionException('Unsupported YOLO output shape: $shape');
  }

  List<DetectedObstacle> _runSsd(Object inputTensor, CameraImage frame) {
    final tensors = _interpreter!.getOutputTensors();
    final outputs = <int, Object>{};
    final inferenceWatch = Stopwatch()..start();

    int? boxesIndex;
    int? scoresIndex;
    int? classesIndex;
    int? countIndex;
    final vectorIndexes = <int>[];

    for (int i = 0; i < tensors.length; i++) {
      final shape = tensors[i].shape;
      final name = tensors[i].name.toLowerCase();
      outputs[i] = _allocateOutput(shape);

      if (shape.length == 3 && shape.last == 4) {
        boxesIndex = i;
      } else if (shape.length == 1 && shape.first == 1) {
        countIndex = i;
      } else if (shape.length == 2) {
        vectorIndexes.add(i);
        if (name.contains('score')) scoresIndex = i;
        if (name.contains('class')) classesIndex = i;
      }
    }

    debugPrint('[SSD_DIAG] Running EfficientDet inference...');
    _interpreter!.runForMultipleInputs([inputTensor], outputs);
    inferenceWatch.stop();
    debugPrint(
      '[SSD_DIAG] EfficientDet inference finished in '
      '${inferenceWatch.elapsedMilliseconds}ms',
    );

    if (scoresIndex == null || classesIndex == null) {
      for (final index in vectorIndexes) {
        final values = _asVector(outputs[index]!);
        final maxValue = values.isEmpty ? 0.0 : values.reduce(_dmax);
        if (maxValue <= 1.01 && scoresIndex == null) {
          scoresIndex = index;
        } else {
          classesIndex ??= index;
        }
      }
    }

    if (boxesIndex == null || scoresIndex == null || classesIndex == null) {
      throw ObstacleDetectionException(
        'Unsupported SSD/EfficientDet outputs. Tensor shapes: '
        '${tensors.map((t) => '${t.name}:${t.shape}').join(', ')}',
      );
    }

    final boxes = _asBoxes(outputs[boxesIndex]!);
    final scores = _asVector(outputs[scoresIndex]!);
    final classes = _asVector(outputs[classesIndex]!);
    final countValues = countIndex == null
        ? Float32List(0)
        : _asVector(outputs[countIndex]!);
    final rawCount = countValues.isEmpty
        ? scores.length
        : countValues.first.round();
    final count = rawCount.clamp(0, scores.length).toInt();

    final detections = <DetectedObstacle>[];
    final embedding = Float32List(80);
    double bestScore = 0;
    String bestLabel = 'object';
    int bestClass = 0;
    int aboveThreshold = 0;

    for (int i = 0; i < count && i < boxes.length && i < classes.length; i++) {
      final score = scores[i];
      final classId = classes[i].round();
      final label = _labelForSsdClass(classId);
      final embeddingClass = _embeddingClassIndexForSsdClass(classId);
      if (embeddingClass >= 0 &&
          embeddingClass < embedding.length &&
          score > embedding[embeddingClass]) {
        embedding[embeddingClass] = score;
      }

      if (score > bestScore) {
        bestScore = score;
        bestLabel = label;
        bestClass = embeddingClass >= 0 ? embeddingClass : classId;
      }
      if (score < _confidenceThreshold) continue;
      aboveThreshold++;

      final box = boxes[i];
      final left = box.length >= 4 ? box[1].clamp(0.0, 1.0).toDouble() : 0.0;
      final top = box.length >= 4 ? box[0].clamp(0.0, 1.0).toDouble() : 0.0;
      final right = box.length >= 4 ? box[3].clamp(0.0, 1.0).toDouble() : 1.0;
      final bottom = box.length >= 4 ? box[2].clamp(0.0, 1.0).toDouble() : 1.0;
      final centerX = (left + right) / 2;
      final direction = centerX < 0.4
          ? 'Left'
          : centerX > 0.6
          ? 'Right'
          : 'Centre';
      final boxH = bottom - top;
      final estDistance = boxH > 0.01
          ? '~${(1.8 / boxH).toStringAsFixed(0)} m'
          : '? m';
      final danger = _dangerousClasses.contains(label.toLowerCase());

      detections.add(
        DetectedObstacle(
          label: label,
          direction: direction,
          isDanger: danger,
          distance: estDistance,
          tip: danger ? 'Stop immediately' : 'Proceed with care',
          confidence: score,
          left: left,
          top: top,
          right: right,
          bottom: bottom,
        ),
      );
    }

    _lastBestScore = bestScore;
    _lastBestLabel = bestLabel;
    _maybeSaveFlSample(
      frame: frame,
      embedding: embedding,
      confidence: bestScore,
      topClassIdx: bestClass,
      source: 'ssd',
    );
    _logSsdDiagnostics(
      count: count,
      aboveThreshold: aboveThreshold,
      bestLabel: bestLabel,
      bestScore: bestScore,
      detections: detections,
    );
    return detections.take(5).toList(growable: false);
  }

  Object _allocateOutput(List<int> shape) {
    if (shape.length == 3) {
      return List.generate(
        shape[0],
        (_) =>
            List.generate(shape[1], (_) => List<double>.filled(shape[2], 0.0)),
      );
    }
    if (shape.length == 2) {
      return List.generate(shape[0], (_) => List<double>.filled(shape[1], 0.0));
    }
    if (shape.length == 1) {
      return List<double>.filled(shape[0], 0.0);
    }
    return List<double>.filled(shape.fold<int>(1, (a, b) => a * b), 0.0);
  }

  Float32List _asVector(Object output) {
    if (output is Float32List) return output;
    if (output is List<num>) {
      return Float32List.fromList(output.map((v) => v.toDouble()).toList());
    }
    if (output is List && output.isNotEmpty && output.first is Float32List) {
      return output.first as Float32List;
    }
    if (output is List && output.isNotEmpty && output.first is List) {
      final first = output.first as List;
      return Float32List.fromList(
        first.map((v) => (v as num).toDouble()).toList(),
      );
    }
    return Float32List(0);
  }

  List<Float32List> _asBoxes(Object output) {
    if (output is List && output.isNotEmpty) {
      final batch = output.first;
      if (batch is List<Float32List>) return batch;
      if (batch is List) {
        return batch
            .whereType<List>()
            .map(
              (box) => Float32List.fromList(
                box.map((v) => (v as num).toDouble()).toList(),
              ),
            )
            .toList(growable: false);
      }
    }
    return const [];
  }

  void _logSsdDiagnostics({
    required int count,
    required int aboveThreshold,
    required String bestLabel,
    required double bestScore,
    required List<DetectedObstacle> detections,
  }) {
    _diagnosticFrameCount++;
    if (_diagnosticFrameCount > 5 && _diagnosticFrameCount % 10 != 0) return;
    debugPrint(
      '[SSD_DIAG] frame=$_diagnosticFrameCount threshold=$_confidenceThreshold '
      'count=$count aboveThreshold=$aboveThreshold best=$bestLabel '
      '${bestScore.toStringAsFixed(4)} returned=${detections.length}',
    );
    for (int i = 0; i < detections.length && i < 5; i++) {
      final d = detections[i];
      debugPrint(
        '[SSD_DIAG] det${i + 1} ${d.label} ${d.direction} ${d.distance}',
      );
    }
  }

  String _labelForSsdClass(int classId) {
    if (_labelsLoadedFromModelMetadata) {
      if (classId >= 0 && classId < _labels.length) {
        final label = _labels[classId];
        if (label != '???') return label;
      }

      final oneBasedClassId = classId - 1;
      if (oneBasedClassId >= 0 && oneBasedClassId < _labels.length) {
        final label = _labels[oneBasedClassId];
        if (label != '???') return label;
      }
    }

    // The TensorFlow Hub / Model Maker EfficientDet Lite exports commonly
    // return zero-based ids for the 90-class TF COCO map with reserved gaps.
    // Example: raw id 72 means TF COCO id 73 = laptop, while compact COCO-80
    // id 72 would incorrectly read as refrigerator.
    final tfOneBased = classId + 1;
    if (tfOneBased >= 0 && tfOneBased < _tfCocoLabels.length) {
      final label = _tfCocoLabels[tfOneBased];
      if (label != '???') return label;
    }

    if (classId >= 0 && classId < _tfCocoLabels.length) {
      final label = _tfCocoLabels[classId];
      if (label != '???') return label;
    }

    if (classId >= 0 && classId < _labels.length) return _labels[classId];

    final compactOneBased = classId - 1;
    if (compactOneBased >= 0 && compactOneBased < _labels.length) {
      return _labels[compactOneBased];
    }

    return 'Object';
  }

  // ── FL sample collection ──────────────────────────────────────────────────

  /// Single pass over raw inference output to derive a compact feature and
  /// determine whether the frame falls in the FL collection window.
  ///
  /// Builds an 80-dim class-activation embedding (per-class max score across
  /// all 8400 anchor positions). Disk I/O is fire-and-forget so inference is
  /// never blocked.
  void _maybeCollectSample(CameraImage frame, List<Float32List> raw) {
    double maxScore = 0;
    int maxClass = 0;
    final embedding = Float32List(80);

    final anchorCount = raw.first.length;
    final channelCount = raw.length;
    if (channelCount <= 4) {
      debugPrint('[FL] Frame skipped because: YOLO output has no class scores');
      return;
    }

    for (int i = 0; i < anchorCount; i++) {
      for (int c = 4; c < channelCount; c++) {
        final score = raw[c][i];
        final classIdx = c - 4;
        if (classIdx < embedding.length && score > embedding[classIdx]) {
          embedding[classIdx] = score;
        }
        if (score > maxScore) {
          maxScore = score;
          maxClass = classIdx;
        }
      }
    }

    _maybeSaveFlSample(
      frame: frame,
      embedding: embedding,
      confidence: maxScore,
      topClassIdx: maxClass,
      source: 'yolo',
    );
  }

  void _maybeSaveFlSample({
    required CameraImage frame,
    required Float32List embedding,
    required double confidence,
    required int topClassIdx,
    required String source,
  }) {
    final skipReason = FlSampleCollector.instance.sampleSkipReason(confidence);
    if (skipReason != null) {
      debugPrint('[FL] Frame skipped because: $skipReason ($source)');
      return;
    }

    unawaited(
      FlSampleCollector.instance.saveSample(
        frame: frame,
        embedding: embedding,
        confidence: confidence,
        topClassIdx: topClassIdx,
      ),
    );
  }

  int _embeddingClassIndexForSsdClass(int classId) {
    if (classId >= 0 && classId < 80) return classId;
    final tfOneBased = classId - 1;
    if (tfOneBased >= 0 && tfOneBased < 80) return tfOneBased;
    return -1;
  }

  // ── Post-processing ───────────────────────────────────────────────────────

  /// Decodes YOLOv8 output `[84][8400]`, applies confidence filtering, and
  /// runs greedy NMS.  Returns up to 5 highest-confidence detections.
  List<DetectedObstacle> _postprocess(List<Float32List> raw) {
    final detections = <_RawDetection>[];
    final prior = FederatedLearningService.instance.globalWeights;
    final topSignals = <_ScoreSignal>[];

    final anchorCount = raw.first.length;
    final channelCount = raw.length;
    double bestScore = 0;
    int bestClass = 0;
    int aboveThresholdCount = 0;

    for (int i = 0; i < anchorCount; i++) {
      // Find the class with the highest score, optionally boosted by the FL prior.
      double maxScore = 0;
      int maxClass = 0;
      for (int c = 4; c < channelCount; c++) {
        final classIdx = c - 4;
        final score =
            raw[c][i] +
            (prior != null && classIdx < prior.length
                ? prior[classIdx] * _kFlPriorStrength
                : 0.0);
        if (score > maxScore) {
          maxScore = score;
          maxClass = classIdx;
        }
      }
      if (maxScore > bestScore) {
        bestScore = maxScore;
        bestClass = maxClass;
      }

      // YOLOv8 outputs cx, cy, w, h in the 640-pixel coordinate space.
      final cx = raw[0][i] / _inputSize;
      final cy = raw[1][i] / _inputSize;
      final bw = raw[2][i] / _inputSize;
      final bh = raw[3][i] / _inputSize;

      final label = maxClass < _labels.length ? _labels[maxClass] : 'Object';
      _recordTopSignal(
        topSignals,
        _ScoreSignal(
          label: label,
          score: maxScore,
          cx: cx,
          cy: cy,
          width: bw,
          height: bh,
        ),
      );

      if (maxScore < _confidenceThreshold) continue;
      aboveThresholdCount++;

      detections.add(
        _RawDetection(
          label: label,
          score: maxScore,
          left: (cx - bw / 2).clamp(0.0, 1.0).toDouble(),
          top: (cy - bh / 2).clamp(0.0, 1.0).toDouble(),
          right: (cx + bw / 2).clamp(0.0, 1.0).toDouble(),
          bottom: (cy + bh / 2).clamp(0.0, 1.0).toDouble(),
        ),
      );
    }

    _lastBestScore = bestScore;
    _lastBestLabel = bestClass < _labels.length ? _labels[bestClass] : 'object';

    // Greedy NMS: keep highest-confidence boxes that don't overlap too much.
    detections.sort((a, b) => b.score.compareTo(a.score));
    final kept = <_RawDetection>[];
    for (final det in detections) {
      if (kept.every((k) => _iou(det, k) < _iouThreshold)) {
        kept.add(det);
      }
    }

    _logYoloDiagnostics(
      rawShape: '[$channelCount, $anchorCount]',
      bestScore: bestScore,
      bestClass: bestClass,
      candidateCount: detections.length,
      aboveThresholdCount: aboveThresholdCount,
      keptCount: kept.length,
      topSignals: topSignals,
    );

    // Convert raw detections to domain objects (direction + estimated distance).
    return kept.take(5).map((d) {
      final direction = d.centerX < 0.4
          ? 'Left'
          : d.centerX > 0.6
          ? 'Right'
          : 'Centre';

      // Rough distance estimate: a 1.8 m tall object filling H% of the frame
      // is approximately 1.8/H metres away (pinhole camera approximation).
      final boxH = d.bottom - d.top;
      final estDistance = boxH > 0.01
          ? '~${(1.8 / boxH).toStringAsFixed(0)} m'
          : '? m';

      final danger = _dangerousClasses.contains(d.label.toLowerCase());
      return DetectedObstacle(
        label: d.label,
        direction: direction,
        isDanger: danger,
        distance: estDistance,
        tip: danger ? 'Stop immediately' : 'Proceed with care',
        confidence: d.score,
        left: d.left,
        top: d.top,
        right: d.right,
        bottom: d.bottom,
      );
    }).toList();
  }

  static double _iou(_RawDetection a, _RawDetection b) {
    final ix = (_dmin(a.right, b.right) - _dmax(a.left, b.left))
        .clamp(0.0, 1.0)
        .toDouble();
    final iy = (_dmin(a.bottom, b.bottom) - _dmax(a.top, b.top))
        .clamp(0.0, 1.0)
        .toDouble();
    final intersection = ix * iy;
    final aArea = (a.right - a.left) * (a.bottom - a.top);
    final bArea = (b.right - b.left) * (b.bottom - b.top);
    final union = aArea + bArea - intersection;
    return union == 0 ? 0 : intersection / union;
  }

  static double _dmin(double a, double b) => a < b ? a : b;
  static double _dmax(double a, double b) => a > b ? a : b;

  void _recordTopSignal(List<_ScoreSignal> topSignals, _ScoreSignal signal) {
    if (topSignals.length < 5) {
      topSignals.add(signal);
      topSignals.sort((a, b) => b.score.compareTo(a.score));
      return;
    }

    if (signal.score <= topSignals.last.score) return;
    topSignals[topSignals.length - 1] = signal;
    topSignals.sort((a, b) => b.score.compareTo(a.score));
  }

  void _logYoloDiagnostics({
    required String rawShape,
    required double bestScore,
    required int bestClass,
    required int candidateCount,
    required int aboveThresholdCount,
    required int keptCount,
    required List<_ScoreSignal> topSignals,
  }) {
    _diagnosticFrameCount++;
    // Log the first few frames, then every tenth frame. This keeps Logcat useful
    // without spamming the Samsung A06 while we diagnose model blindness.
    if (_diagnosticFrameCount > 5 && _diagnosticFrameCount % 10 != 0) return;

    final bestLabel = bestClass < _labels.length
        ? _labels[bestClass]
        : 'object';
    debugPrint(
      '[YOLO_DIAG] frame=$_diagnosticFrameCount raw=$rawShape '
      'threshold=$_confidenceThreshold best=$bestLabel '
      '${bestScore.toStringAsFixed(4)} candidates=$candidateCount '
      'aboveThreshold=$aboveThresholdCount afterNms=$keptCount',
    );
    for (int i = 0; i < topSignals.length; i++) {
      final s = topSignals[i];
      debugPrint(
        '[YOLO_DIAG] top${i + 1} ${s.label} '
        'score=${s.score.toStringAsFixed(4)} '
        'cx=${s.cx.toStringAsFixed(2)} cy=${s.cy.toStringAsFixed(2)} '
        'w=${s.width.toStringAsFixed(2)} h=${s.height.toStringAsFixed(2)}',
      );
    }
  }

  // ── Demo / fallback ───────────────────────────────────────────────────────

  /// Hard-coded demo obstacles used when the camera is unavailable (emulator).
  List<DetectedObstacle> demoObstacles() => [
    _buildDemoObstacle('Pole', 'Centre', true, '~2 m'),
    _buildDemoObstacle('Car', 'Right', true, '~8 m'),
    _buildDemoObstacle('Person', 'Left', false, '~3 m'),
    _buildDemoObstacle('Stairs', 'Centre', true, '~4 m'),
  ];

  DetectedObstacle _buildDemoObstacle(
    String label,
    String direction,
    bool isDanger,
    String distance,
  ) {
    final normalized = label.toLowerCase();
    final resolvedLabel = _labels.firstWhere(
      (item) => item.toLowerCase() == normalized,
      orElse: () => label,
    );
    return DetectedObstacle(
      label: resolvedLabel,
      direction: direction,
      isDanger: isDanger,
      distance: distance,
      tip: isDanger ? 'Stop immediately' : 'Proceed with care',
    );
  }

  Future<void> dispose() async {
    _interpreter?.close();
    _interpreter = null;
    _debugFrameSaved = false;
    _diagnosticFrameCount = 0;
  }

  // ── Label loading ─────────────────────────────────────────────────────────

  Future<_LabelLoadResult> _loadLabels() async {
    final metadataLabels = await _loadLabelsFromModelMetadata();
    if (metadataLabels.isNotEmpty) {
      debugPrint(
        '[TFLite] Loaded ${metadataLabels.length} labels from model metadata',
      );
      return _LabelLoadResult(labels: metadataLabels, fromModelMetadata: true);
    }

    try {
      final raw = await rootBundle.loadString(AppConfig.obstacleLabelsAsset);
      final labels = _parsePlainTextLabels(raw);
      debugPrint(
        '[TFLite] Loaded ${labels.length} labels from '
        '${AppConfig.obstacleLabelsAsset}',
      );
      return _LabelLoadResult(labels: labels, fromModelMetadata: false);
    } catch (_) {
      return const _LabelLoadResult(labels: [], fromModelMetadata: false);
    }
  }

  Future<List<String>> _loadLabelsFromModelMetadata() async {
    try {
      final modelData = await rootBundle.load(AppConfig.obstacleModelAsset);
      final modelBytes = modelData.buffer.asUint8List(
        modelData.offsetInBytes,
        modelData.lengthInBytes,
      );
      final associatedFiles = _readZipAssociatedFiles(modelBytes);

      final textLabelFiles = associatedFiles.entries.where((entry) {
        final name = entry.key.toLowerCase();
        return name.endsWith('.txt') &&
            (name.contains('label') ||
                name.contains('class') ||
                name.contains('name'));
      }).toList();
      textLabelFiles.sort((a, b) => a.key.compareTo(b.key));

      for (final entry in textLabelFiles) {
        final labels = _parsePlainTextLabels(utf8.decode(entry.value));
        if (labels.isNotEmpty) {
          debugPrint('[TFLite] Metadata label file: ${entry.key}');
          return labels;
        }
      }

      for (final entry in associatedFiles.entries) {
        if (!entry.key.toLowerCase().endsWith('.json')) continue;
        final labels = _parseLabelsFromMetadataJson(utf8.decode(entry.value));
        if (labels.isNotEmpty) {
          debugPrint('[TFLite] Metadata JSON label source: ${entry.key}');
          return labels;
        }
      }
    } catch (e) {
      debugPrint('[TFLite] Could not read labels from model metadata: $e');
    }

    return const [];
  }

  static List<String> _parsePlainTextLabels(String raw) {
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _parseLabelsFromMetadataJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) return const [];

    final names = decoded['names'];
    if (names is List) {
      return names
          .map((label) => label.toString().trim())
          .where((label) => label.isNotEmpty)
          .toList(growable: false);
    }

    if (names is Map) {
      final entries =
          names.entries
              .map(
                (entry) => MapEntry(
                  int.tryParse(entry.key.toString()),
                  entry.value.toString().trim(),
                ),
              )
              .where((entry) => entry.key != null && entry.value.isNotEmpty)
              .toList()
            ..sort((a, b) => a.key!.compareTo(b.key!));
      return entries.map((entry) => entry.value).toList(growable: false);
    }

    return const [];
  }

  static Map<String, Uint8List> _readZipAssociatedFiles(Uint8List bytes) {
    final eocdOffset = _lastIndexOfSignature(bytes, 0x06054b50);
    if (eocdOffset < 0 || eocdOffset + 22 > bytes.length) return const {};

    final entryCount = _uint16(bytes, eocdOffset + 10);
    final centralDirectoryOffset = _uint32(bytes, eocdOffset + 16);
    if (centralDirectoryOffset <= 0 ||
        centralDirectoryOffset >= bytes.length ||
        entryCount <= 0) {
      return const {};
    }

    final files = <String, Uint8List>{};
    var cursor = centralDirectoryOffset;
    for (var i = 0; i < entryCount && cursor + 46 <= bytes.length; i++) {
      if (_uint32(bytes, cursor) != 0x02014b50) break;

      final compressionMethod = _uint16(bytes, cursor + 10);
      final compressedSize = _uint32(bytes, cursor + 20);
      final fileNameLength = _uint16(bytes, cursor + 28);
      final extraLength = _uint16(bytes, cursor + 30);
      final commentLength = _uint16(bytes, cursor + 32);
      final localHeaderOffset = _uint32(bytes, cursor + 42);
      final nameStart = cursor + 46;
      final nameEnd = nameStart + fileNameLength;
      if (nameEnd > bytes.length) break;

      final fileName = utf8.decode(bytes.sublist(nameStart, nameEnd));
      final fileBytes = _readZipFileData(
        bytes,
        localHeaderOffset,
        compressedSize,
        compressionMethod,
      );
      if (fileBytes != null) files[fileName] = fileBytes;

      cursor = nameEnd + extraLength + commentLength;
    }

    return files;
  }

  static Uint8List? _readZipFileData(
    Uint8List bytes,
    int localHeaderOffset,
    int compressedSize,
    int compressionMethod,
  ) {
    if (localHeaderOffset < 0 || localHeaderOffset + 30 > bytes.length) {
      return null;
    }
    if (_uint32(bytes, localHeaderOffset) != 0x04034b50) return null;

    final fileNameLength = _uint16(bytes, localHeaderOffset + 26);
    final extraLength = _uint16(bytes, localHeaderOffset + 28);
    final dataStart = localHeaderOffset + 30 + fileNameLength + extraLength;
    final dataEnd = dataStart + compressedSize;
    if (dataStart < 0 || dataEnd > bytes.length) return null;

    final compressed = bytes.sublist(dataStart, dataEnd);
    if (compressionMethod == 0) return Uint8List.fromList(compressed);
    if (compressionMethod == 8) {
      return Uint8List.fromList(ZLibDecoder(raw: true).convert(compressed));
    }

    return null;
  }

  static int _lastIndexOfSignature(Uint8List bytes, int signature) {
    for (var i = bytes.length - 4; i >= 0; i--) {
      if (_uint32(bytes, i) == signature) return i;
    }
    return -1;
  }

  static int _uint16(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  static int _uint32(Uint8List bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}

enum _DetectorKind { unknown, yolo, ssd }

class _LabelLoadResult {
  final List<String> labels;
  final bool fromModelMetadata;

  const _LabelLoadResult({
    required this.labels,
    required this.fromModelMetadata,
  });
}

const List<String> _tfCocoLabels = [
  '???',
  'person',
  'bicycle',
  'car',
  'motorcycle',
  'airplane',
  'bus',
  'train',
  'truck',
  'boat',
  'traffic light',
  'fire hydrant',
  '???',
  'stop sign',
  'parking meter',
  'bench',
  'bird',
  'cat',
  'dog',
  'horse',
  'sheep',
  'cow',
  'elephant',
  'bear',
  'zebra',
  'giraffe',
  '???',
  'backpack',
  'umbrella',
  '???',
  '???',
  'handbag',
  'tie',
  'suitcase',
  'frisbee',
  'skis',
  'snowboard',
  'sports ball',
  'kite',
  'baseball bat',
  'baseball glove',
  'skateboard',
  'surfboard',
  'tennis racket',
  'bottle',
  '???',
  'wine glass',
  'cup',
  'fork',
  'knife',
  'spoon',
  'bowl',
  'banana',
  'apple',
  'sandwich',
  'orange',
  'broccoli',
  'carrot',
  'hot dog',
  'pizza',
  'donut',
  'cake',
  'chair',
  'couch',
  'potted plant',
  'bed',
  '???',
  'dining table',
  '???',
  '???',
  'toilet',
  '???',
  'tv',
  'laptop',
  'mouse',
  'remote',
  'keyboard',
  'cell phone',
  'microwave',
  'oven',
  'toaster',
  'sink',
  'refrigerator',
  '???',
  'book',
  'clock',
  'vase',
  'scissors',
  'teddy bear',
  'hair drier',
  'toothbrush',
];

// ── Isolate helpers ───────────────────────────────────────────────────────────
//
// Must be top-level functions/classes so [compute] can send them to an isolate.

/// Converts a YUV420 camera frame to a flat Float32List [H*W*3] normalised to
/// [0.0, 1.0], then resizes to [inputSize × inputSize].
_PreprocessResult _preprocessFrame(_FrameArgs args) {
  // Build an RGB img.Image from the three YUV planes.
  final image = img.Image(width: args.srcWidth, height: args.srcHeight);

  for (int y = 0; y < args.srcHeight; y++) {
    for (int x = 0; x < args.srcWidth; x++) {
      final yIdx = y * args.yRowStride + x;
      final uvIdx = (y ~/ 2) * args.uvRowStride + (x ~/ 2) * args.uvPixelStride;

      final yVal = args.yBytes[yIdx];
      final uVal = args.uBytes[uvIdx] - 128;
      final vVal = args.vBytes[uvIdx] - 128;

      // ITU-R BT.601 YCbCr → RGB coefficients.
      final r = (yVal + 1.370705 * vVal).clamp(0, 255).toInt();
      final g = (yVal - 0.698001 * vVal - 0.337633 * uVal)
          .clamp(0, 255)
          .toInt();
      final b = (yVal + 1.732446 * uVal).clamp(0, 255).toInt();

      image.setPixelRgb(x, y, r, g, b);
    }
  }

  // Android camera streams are delivered in the sensor's native orientation.
  // On most portrait phones that means the raw frame is sideways. YOLO was
  // trained on upright images, so rotate before resizing or detections become
  // extremely weak even though the model loads correctly.
  final upright = switch (args.sensorOrientation) {
    90 => img.copyRotate(image, angle: 90),
    180 => img.copyRotate(image, angle: 180),
    270 => img.copyRotate(image, angle: -90),
    _ => image,
  };

  final img.Image resized;
  if (args.preserveAspectRatio) {
    // YOLO models are normally trained with letterbox resizing: preserve aspect
    // ratio, then pad to a square. Stretching the camera frame to 640x640 can
    // make familiar objects look unnatural and lower confidence dramatically.
    final scale = args.inputSize / _imax(upright.width, upright.height);
    final resizedWidth = (upright.width * scale)
        .round()
        .clamp(1, args.inputSize)
        .toInt();
    final resizedHeight = (upright.height * scale)
        .round()
        .clamp(1, args.inputSize)
        .toInt();
    final resizedContent = img.copyResize(
      upright,
      width: resizedWidth,
      height: resizedHeight,
      interpolation: img.Interpolation.linear,
    );
    resized = img.Image(width: args.inputSize, height: args.inputSize);
    img.fill(resized, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(
      resized,
      resizedContent,
      dstX: ((args.inputSize - resizedWidth) / 2).round(),
      dstY: ((args.inputSize - resizedHeight) / 2).round(),
    );
  } else {
    // EfficientDet/SSD TFLite examples use a direct square resize before
    // inference. This keeps more of the low-resolution camera frame available
    // to the model on budget devices.
    resized = img.copyResize(
      upright,
      width: args.inputSize,
      height: args.inputSize,
      interpolation: img.Interpolation.linear,
    );
  }

  if (args.debugImagePath != null) {
    try {
      File(
        args.debugImagePath!,
      ).writeAsBytesSync(img.encodeJpg(resized, quality: 92), flush: true);
    } catch (_) {
      // Debug capture is best-effort only; inference must never depend on it.
    }
  }

  // Pack into flat NHWC order (height, width, channels). EfficientDet-Lite0
  // metadata models use uint8 [0..255], YOLO exports usually use float [0..1].
  if (args.normalize) {
    final tensor = Float32List(args.inputSize * args.inputSize * 3);
    int idx = 0;
    for (int row = 0; row < args.inputSize; row++) {
      for (int col = 0; col < args.inputSize; col++) {
        final pixel = resized.getPixel(col, row);
        tensor[idx++] = pixel.r.toDouble() / 255.0;
        tensor[idx++] = pixel.g.toDouble() / 255.0;
        tensor[idx++] = pixel.b.toDouble() / 255.0;
      }
    }
    return _PreprocessResult(tensor, args.debugImagePath);
  }

  final tensor = Uint8List(args.inputSize * args.inputSize * 3);
  int idx = 0;
  for (int row = 0; row < args.inputSize; row++) {
    for (int col = 0; col < args.inputSize; col++) {
      final pixel = resized.getPixel(col, row);
      tensor[idx++] = pixel.r.toInt().clamp(0, 255).toInt();
      tensor[idx++] = pixel.g.toInt().clamp(0, 255).toInt();
      tensor[idx++] = pixel.b.toInt().clamp(0, 255).toInt();
    }
  }
  return _PreprocessResult(tensor, args.debugImagePath);
}

int _imax(int a, int b) => a > b ? a : b;

class _PreprocessResult {
  final Object tensor;
  final String? debugImagePath;

  const _PreprocessResult(this.tensor, this.debugImagePath);
}

class _FrameArgs {
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;
  final int srcWidth;
  final int srcHeight;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final int inputSize;
  final int sensorOrientation;
  final String? debugImagePath;
  final bool normalize;
  final bool preserveAspectRatio;

  const _FrameArgs({
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
    required this.srcWidth,
    required this.srcHeight,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.inputSize,
    required this.sensorOrientation,
    required this.debugImagePath,
    required this.normalize,
    required this.preserveAspectRatio,
  });
}

class _RawDetection {
  final String label;
  final double score;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get centerX => (left + right) / 2;

  const _RawDetection({
    required this.label,
    required this.score,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });
}

class _ScoreSignal {
  final String label;
  final double score;
  final double cx;
  final double cy;
  final double width;
  final double height;

  const _ScoreSignal({
    required this.label,
    required this.score,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
  });
}

// ── Public domain types ───────────────────────────────────────────────────────

class DetectedObstacle {
  final String label;
  final String direction;
  final bool isDanger;
  final String distance;
  final String tip;
  final double? confidence;
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;

  const DetectedObstacle({
    required this.label,
    required this.direction,
    required this.isDanger,
    required this.distance,
    required this.tip,
    this.confidence,
    this.left,
    this.top,
    this.right,
    this.bottom,
  });

  bool get hasBox =>
      left != null &&
      top != null &&
      right != null &&
      bottom != null &&
      right! > left! &&
      bottom! > top!;
}

class ObstacleDetectionException implements Exception {
  final String message;
  const ObstacleDetectionException(this.message);

  @override
  String toString() => 'ObstacleDetectionException: $message';
}
