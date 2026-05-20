import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads the FedAvg-aggregated global class-activation weights from
/// Firestore and caches them on-device for offline use.
///
/// The global weights are an 80-dim Float32 vector produced by the Python
/// aggregation server (fl_server/aggregator.py).  Each element represents the
/// average uncertain-detection strength for the corresponding COCO class
/// across all contributing devices.
///
/// Usage:
///   await FederatedLearningService.instance.initialize();   // on app start
///   final weights = FederatedLearningService.instance.globalWeights;  // nullable
class FederatedLearningService {
  FederatedLearningService._();
  static final FederatedLearningService instance = FederatedLearningService._();

  static const _globalModelCollection = 'fl_global_model';
  static const _globalModelDoc = 'current';
  static const _cacheFileName = 'fl_global_weights.json';
  static const _expectedDim = 80;

  Float32List? _globalWeights;
  DateTime? _lastUpdated;
  String? _lastRoundId;

  /// The aggregated 80-dim class-activation prior, or null if not yet loaded.
  Float32List? get globalWeights => _globalWeights;

  /// When the weights were last successfully refreshed from Firebase.
  DateTime? get lastUpdated => _lastUpdated;

  /// The round ID of the currently loaded weights (for logging/debugging).
  String? get lastRoundId => _lastRoundId;

  bool get isLoaded => _globalWeights != null;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Loads cached weights immediately (synchronous path), then refreshes from
  /// Firebase in the background.  Safe to call multiple times.
  Future<void> initialize() async {
    await _loadFromCache();
    unawaited(refresh());
  }

  /// Downloads the latest global weights from Firestore.
  /// Updates the in-memory weights and local cache on success.
  /// Silently no-ops on network failure (cached weights remain active).
  Future<void> refresh() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection(_globalModelCollection)
          .doc(_globalModelDoc)
          .get();
      final json = snapshot.data();
      if (json == null) return;

      final parsed = _parseWeights(json);
      if (parsed == null) return;

      _globalWeights = parsed;
      _lastUpdated = DateTime.now();
      _lastRoundId = json['round_id'] as String?;

      await _saveToCache(json);
    } catch (_) {
      // Network unavailable or Storage not configured — cached weights stay.
    }
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  Float32List? _parseWeights(Map<String, dynamic> json) {
    final raw = json['global_weights'];
    if (raw is! List) return null;
    if (raw.length != _expectedDim) return null;

    final weights = Float32List(_expectedDim);
    for (int i = 0; i < _expectedDim; i++) {
      weights[i] = (raw[i] as num).toDouble();
    }
    return weights;
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_cacheFileName');
  }

  Future<void> _loadFromCache() async {
    try {
      final file = await _cacheFile();
      if (!file.existsSync()) return;

      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final parsed = _parseWeights(json);
      if (parsed == null) return;

      _globalWeights = parsed;
      _lastRoundId = json['round_id'] as String?;
      // Parse the ISO-8601 timestamp written by the Python server.
      final ts = json['updated_at'] as String?;
      if (ts != null) _lastUpdated = DateTime.tryParse(ts);
    } catch (_) {
      // Corrupted cache — will be overwritten on next successful refresh.
    }
  }

  Future<void> _saveToCache(Map<String, dynamic> json) async {
    try {
      final file = await _cacheFile();
      await file.writeAsString(jsonEncode(json));
    } catch (_) {
      // Non-fatal: cache write failure doesn't affect in-memory weights.
    }
  }
}
