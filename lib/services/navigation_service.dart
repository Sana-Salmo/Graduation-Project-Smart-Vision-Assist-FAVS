import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class NavigationService {
  static const _userAgent = 'smart_vision_app/1.0';

  Future<NavigationRoute> buildRoute(
    String destinationQuery, {
    String languageCode = 'en',
  }) async {
    final currentPosition = await _getCurrentPosition(languageCode);
    final destination = await _geocodeDestination(
      destinationQuery,
      languageCode: languageCode,
    );

    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/walking/'
      '${currentPosition.longitude},${currentPosition.latitude};'
      '${destination.longitude},${destination.latitude}'
      '?overview=false&steps=true&alternatives=false',
    );

    final response = await http.get(uri, headers: {'User-Agent': _userAgent});
    if (response.statusCode != 200) {
      throw NavigationException(
        _message(
          languageCode,
          en: 'Routing request failed with ${response.statusCode}.',
          ar: 'فشل طلب المسار برمز ${response.statusCode}.',
        ),
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = json['routes'] as List<dynamic>? ?? const [];
    if (routes.isEmpty) {
      throw NavigationException(
        _message(
          languageCode,
          en: 'No route was found for this destination.',
          ar: 'لم يتم العثور على مسار لهذه الوجهة.',
        ),
      );
    }

    final route = routes.first as Map<String, dynamic>;
    final legs = route['legs'] as List<dynamic>? ?? const [];
    final steps = <NavigationStep>[];

    for (final leg in legs.cast<Map<String, dynamic>>()) {
      final legSteps = leg['steps'] as List<dynamic>? ?? const [];
      for (final step in legSteps.cast<Map<String, dynamic>>()) {
        final instruction = _localizedInstructionFromStep(step, languageCode);
        if (instruction.isEmpty) continue;
        final distance = (step['distance'] as num?)?.toDouble() ?? 0;
        final maneuver = step['maneuver'] as Map<String, dynamic>? ?? const {};
        final location = maneuver['location'];
        double? maneuverLongitude;
        double? maneuverLatitude;
        if (location is List && location.length >= 2) {
          maneuverLongitude = (location[0] as num?)?.toDouble();
          maneuverLatitude = (location[1] as num?)?.toDouble();
        }
        steps.add(
          NavigationStep(
            instruction: instruction,
            distanceMeters: distance,
            distanceLabel: _localizedDistanceLabel(distance, languageCode),
            maneuverLatitude: maneuverLatitude,
            maneuverLongitude: maneuverLongitude,
          ),
        );
      }
    }

    if (steps.isEmpty) {
      throw NavigationException(
        _message(
          languageCode,
          en: 'No step-by-step directions were returned.',
          ar: 'لم يتم إرجاع إرشادات خطوة بخطوة.',
        ),
      );
    }

    return NavigationRoute(
      destinationName: destination.displayName,
      destinationLatitude: destination.latitude,
      destinationLongitude: destination.longitude,
      steps: steps,
      totalDistanceMeters: (route['distance'] as num?)?.toDouble() ?? 0,
      totalDurationSeconds: (route['duration'] as num?)?.toDouble() ?? 0,
    );
  }

  Future<Position> _getCurrentPosition(String languageCode) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw NavigationException(
        _message(
          languageCode,
          en: 'Location services are disabled.',
          ar: 'خدمات الموقع غير مفعلة.',
        ),
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw NavigationException(
        _message(
          languageCode,
          en: 'Location permission is required.',
          ar: 'إذن الموقع مطلوب.',
        ),
      );
    }

    return Geolocator.getCurrentPosition();
  }

  Future<_PlaceResult> _geocodeDestination(
    String destinationQuery, {
    required String languageCode,
  }) async {
    final candidates = _destinationCandidates(destinationQuery);
    for (final candidate in candidates) {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': candidate,
        'format': 'jsonv2',
        'limit': '1',
        'accept-language': languageCode,
      });

      final response = await http.get(
        uri,
        headers: {'User-Agent': _userAgent, 'Accept-Language': languageCode},
      );
      if (response.statusCode != 200) {
        throw NavigationException(
          _message(
            languageCode,
            en: 'Destination lookup failed with ${response.statusCode}.',
            ar: 'فشل البحث عن الوجهة برمز ${response.statusCode}.',
          ),
        );
      }

      final results = jsonDecode(response.body) as List<dynamic>;
      if (results.isEmpty) continue;

      final first = results.first as Map<String, dynamic>;
      return _PlaceResult(
        displayName: (first['display_name'] as String?) ?? candidate,
        latitude: double.parse(first['lat'].toString()),
        longitude: double.parse(first['lon'].toString()),
      );
    }

    throw NavigationException(
      _message(
        languageCode,
        en: 'Destination not found.',
        ar: 'لم يتم العثور على الوجهة.',
      ),
    );
  }

  List<String> _destinationCandidates(String query) {
    final normalized = _normalizeSearchText(query);
    final candidates = <String>[query.trim()];

    final alias = _placeAliases[normalized];
    if (alias != null) candidates.add(alias);

    if (normalized != query.trim().toLowerCase()) candidates.add(normalized);

    final reverseAlias = _placeAliases.entries
        .where((entry) => _normalizeSearchText(entry.value) == normalized)
        .map((entry) => entry.key);
    candidates.addAll(reverseAlias);

    return candidates
        .map((candidate) => candidate.trim())
        .where((candidate) => candidate.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  String _normalizeSearchText(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
        .replaceAll(RegExp(r'[إأآا]'), 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  String _localizedInstructionFromStep(
    Map<String, dynamic> step,
    String languageCode,
  ) {
    final maneuver = step['maneuver'] as Map<String, dynamic>? ?? const {};
    final type = (maneuver['type'] as String? ?? '').trim();
    final modifier = (maneuver['modifier'] as String? ?? '').trim();
    final name = (step['name'] as String? ?? '').trim();
    final arabic = languageCode == 'ar';
    final road = name.isEmpty
        ? ''
        : arabic
        ? ' \u0625\u0644\u0649 $name'
        : ' onto $name';

    switch (type) {
      case 'depart':
        if (arabic) {
          return name.isEmpty
              ? '\u0627\u0628\u062f\u0623 \u0627\u0644\u0645\u0634\u064a.'
              : '\u0627\u0628\u062f\u0623 \u0627\u0644\u0645\u0634\u064a \u0639\u0644\u0649 $name.';
        }
        return name.isEmpty ? 'Start walking.' : 'Start walking on $name.';
      case 'turn':
        if (arabic) {
          final direction = _arabicModifier(modifier);
          return direction.isEmpty
              ? '\u0627\u0646\u0639\u0637\u0641 \u0644\u0644\u0623\u0645\u0627\u0645$road.'
              : '\u0627\u0646\u0639\u0637\u0641 $direction$road.';
        }
        return modifier.isEmpty ? 'Turn ahead$road.' : 'Turn $modifier$road.';
      case 'new name':
        if (arabic) {
          return name.isEmpty
              ? '\u062a\u0627\u0628\u0639 \u0644\u0644\u0623\u0645\u0627\u0645.'
              : '\u062a\u0627\u0628\u0639 \u0639\u0644\u0649 $name.';
        }
        return name.isEmpty ? 'Continue forward.' : 'Continue on $name.';
      case 'continue':
        if (arabic) {
          return name.isEmpty
              ? '\u062a\u0627\u0628\u0639 \u0645\u0628\u0627\u0634\u0631\u0629.'
              : '\u062a\u0627\u0628\u0639 \u0645\u0628\u0627\u0634\u0631\u0629 \u0639\u0644\u0649 $name.';
        }
        return name.isEmpty
            ? 'Continue straight.'
            : 'Continue straight on $name.';
      case 'fork':
        if (arabic) {
          final direction = _arabicModifier(modifier);
          return direction.isEmpty
              ? '\u062a\u0627\u0628\u0639 \u0639\u0646\u062f \u0627\u0644\u062a\u0641\u0631\u0639.'
              : '\u0627\u0628\u0642 $direction \u0639\u0646\u062f \u0627\u0644\u062a\u0641\u0631\u0639.';
        }
        return modifier.isEmpty
            ? 'Keep to the fork.'
            : 'Keep $modifier at the fork.';
      case 'roundabout':
      case 'rotary':
        if (arabic) {
          return '\u0627\u062f\u062e\u0644 \u0627\u0644\u062f\u0648\u0627\u0631${road.isEmpty ? '' : road}.';
        }
        return 'Enter the roundabout${road.isEmpty ? '' : road}.';
      case 'arrive':
        return arabic
            ? '\u0644\u0642\u062f \u0648\u0635\u0644\u062a \u0625\u0644\u0649 \u0648\u062c\u0647\u062a\u0643.'
            : 'You have arrived at your destination.';
      case 'end of road':
        if (arabic) {
          final direction = _arabicModifier(modifier);
          return direction.isEmpty
              ? '\u0639\u0646\u062f \u0646\u0647\u0627\u064a\u0629 \u0627\u0644\u0637\u0631\u064a\u0642\u060c \u062a\u0627\u0628\u0639.'
              : '\u0639\u0646\u062f \u0646\u0647\u0627\u064a\u0629 \u0627\u0644\u0637\u0631\u064a\u0642\u060c \u0627\u0646\u0639\u0637\u0641 $direction.';
        }
        return modifier.isEmpty
            ? 'At the end of the road, continue.'
            : 'At the end of the road, turn $modifier.';
      case 'merge':
        if (arabic) {
          final direction = _arabicModifier(modifier);
          return direction.isEmpty
              ? '\u0627\u0646\u062f\u0645\u062c \u0641\u064a \u0627\u0644\u0637\u0631\u064a\u0642.'
              : '\u0627\u0646\u062f\u0645\u062c $direction.';
        }
        return modifier.isEmpty ? 'Merge ahead.' : 'Merge $modifier.';
      default:
        if (arabic) {
          return name.isEmpty
              ? '\u062a\u0627\u0628\u0639 \u0625\u0644\u0649 \u0627\u0644\u062c\u0632\u0621 \u0627\u0644\u062a\u0627\u0644\u064a.'
              : '\u062a\u0627\u0628\u0639 \u0639\u0644\u0649 $name.';
        }
        return name.isEmpty
            ? 'Proceed to the next segment.'
            : 'Proceed on $name.';
    }
  }

  String _arabicModifier(String modifier) {
    switch (modifier.toLowerCase()) {
      case 'left':
        return '\u064a\u0633\u0627\u0631\u0627\u064b';
      case 'right':
        return '\u064a\u0645\u064a\u0646\u0627\u064b';
      case 'slight left':
        return '\u0642\u0644\u064a\u0644\u0627\u064b \u0625\u0644\u0649 \u0627\u0644\u064a\u0633\u0627\u0631';
      case 'slight right':
        return '\u0642\u0644\u064a\u0644\u0627\u064b \u0625\u0644\u0649 \u0627\u0644\u064a\u0645\u064a\u0646';
      case 'sharp left':
        return '\u0628\u062d\u062f\u0629 \u0625\u0644\u0649 \u0627\u0644\u064a\u0633\u0627\u0631';
      case 'sharp right':
        return '\u0628\u062d\u062f\u0629 \u0625\u0644\u0649 \u0627\u0644\u064a\u0645\u064a\u0646';
      case 'straight':
        return '\u0645\u0628\u0627\u0634\u0631\u0629';
      case 'uturn':
      case 'u-turn':
        return '\u0644\u0644\u062e\u0644\u0641';
      default:
        return modifier;
    }
  }

  String _localizedDistanceLabel(double meters, String languageCode) {
    if (meters >= 1000) {
      final unit = languageCode == 'ar' ? '\u0643\u0645' : 'km';
      return '${(meters / 1000).toStringAsFixed(1)} $unit';
    }
    final unit = languageCode == 'ar' ? '\u0645' : 'm';
    return '${meters.round()} $unit';
  }

  String legacyInstructionFromStep(
    Map<String, dynamic> step,
    String languageCode,
  ) {
    final maneuver = step['maneuver'] as Map<String, dynamic>? ?? const {};
    final type = (maneuver['type'] as String? ?? '').trim();
    final modifier = (maneuver['modifier'] as String? ?? '').trim();
    final name = (step['name'] as String? ?? '').trim();
    final arabic = languageCode == 'ar';

    final road = name.isEmpty
        ? ''
        : arabic
        ? ' إلى $name'
        : ' onto $name';

    switch (type) {
      case 'depart':
        if (arabic) {
          return name.isEmpty ? 'ابدأ المشي.' : 'ابدأ المشي على $name.';
        }
        return name.isEmpty ? 'Start walking.' : 'Start walking on $name.';
      case 'turn':
        if (arabic) {
          final direction = _localizedModifier(modifier, languageCode);
          return direction.isEmpty
              ? 'انعطف للأمام$road.'
              : 'انعطف $direction$road.';
        }
        return modifier.isEmpty ? 'Turn ahead$road.' : 'Turn $modifier$road.';
      case 'new name':
        if (arabic) return name.isEmpty ? 'تابع للأمام.' : 'تابع على $name.';
        return name.isEmpty ? 'Continue forward.' : 'Continue on $name.';
      case 'continue':
        if (arabic) {
          return name.isEmpty ? 'تابع مباشرة.' : 'تابع مباشرة على $name.';
        }
        return name.isEmpty
            ? 'Continue straight.'
            : 'Continue straight on $name.';
      case 'fork':
        if (arabic) {
          final direction = _localizedModifier(modifier, languageCode);
          return direction.isEmpty
              ? 'تابع عند التفرع.'
              : 'ابق $direction عند التفرع.';
        }
        return modifier.isEmpty
            ? 'Keep to the fork.'
            : 'Keep $modifier at the fork.';
      case 'roundabout':
      case 'rotary':
        if (arabic) return 'ادخل الدوار${road.isEmpty ? '' : road}.';
        return 'Enter the roundabout${road.isEmpty ? '' : road}.';
      case 'arrive':
        if (arabic) return 'لقد وصلت إلى وجهتك.';
        return 'You have arrived at your destination.';
      case 'end of road':
        if (arabic) {
          final direction = _localizedModifier(modifier, languageCode);
          return direction.isEmpty
              ? 'عند نهاية الطريق، تابع.'
              : 'عند نهاية الطريق، انعطف $direction.';
        }
        return modifier.isEmpty
            ? 'At the end of the road, continue.'
            : 'At the end of the road, turn $modifier.';
      case 'merge':
        if (arabic) {
          final direction = _localizedModifier(modifier, languageCode);
          return direction.isEmpty ? 'اندمج في الطريق.' : 'اندمج $direction.';
        }
        return modifier.isEmpty ? 'Merge ahead.' : 'Merge $modifier.';
      default:
        if (arabic) {
          return name.isEmpty ? 'تابع إلى الجزء التالي.' : 'تابع على $name.';
        }
        return name.isEmpty
            ? 'Proceed to the next segment.'
            : 'Proceed on $name.';
    }
  }

  String _localizedModifier(String modifier, String languageCode) {
    if (languageCode != 'ar') return modifier;
    switch (modifier.toLowerCase()) {
      case 'left':
        return 'يساراً';
      case 'right':
        return 'يميناً';
      case 'slight left':
        return 'قليلاً إلى اليسار';
      case 'slight right':
        return 'قليلاً إلى اليمين';
      case 'sharp left':
        return 'بحدة إلى اليسار';
      case 'sharp right':
        return 'بحدة إلى اليمين';
      case 'straight':
        return 'مباشرة';
      case 'uturn':
      case 'u-turn':
        return 'للخلف';
      default:
        return modifier;
    }
  }

  String legacyDistanceLabel(double meters, String languageCode) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} ${languageCode == 'ar' ? 'كم' : 'km'}';
    }
    return '${meters.round()} ${languageCode == 'ar' ? 'م' : 'm'}';
  }

  static String _message(
    String languageCode, {
    required String en,
    required String ar,
  }) {
    return languageCode == 'ar' ? ar : en;
  }
}

const Map<String, String> _placeAliases = {
  'جده بارك': 'Jeddah Park',
  'جدة بارك': 'Jeddah Park',
  'jeddah park': 'Jeddah Park',
  'رد سي مول': 'Red Sea Mall',
  'red sea mall': 'Red Sea Mall',
  'العرب مول': 'Mall of Arabia Jeddah',
  'مول العرب': 'Mall of Arabia Jeddah',
  'mall of arabia': 'Mall of Arabia Jeddah',
  'جامعة جدة': 'University of Jeddah',
  'جامعه جده': 'University of Jeddah',
  'king abdulaziz university': 'King Abdulaziz University',
  'جامعة الملك عبدالعزيز': 'King Abdulaziz University',
};

class NavigationRoute {
  final String destinationName;
  final double destinationLatitude;
  final double destinationLongitude;
  final List<NavigationStep> steps;
  final double totalDistanceMeters;
  final double totalDurationSeconds;

  const NavigationRoute({
    required this.destinationName,
    required this.destinationLatitude,
    required this.destinationLongitude,
    required this.steps,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
  });
}

class NavigationStep {
  final String instruction;
  final double distanceMeters;
  final String distanceLabel;
  final double? maneuverLatitude;
  final double? maneuverLongitude;

  const NavigationStep({
    required this.instruction,
    required this.distanceMeters,
    required this.distanceLabel,
    required this.maneuverLatitude,
    required this.maneuverLongitude,
  });

  bool get hasManeuverLocation =>
      maneuverLatitude != null && maneuverLongitude != null;
}

class NavigationException implements Exception {
  final String message;
  const NavigationException(this.message);

  @override
  String toString() => 'NavigationException: $message';
}

class _PlaceResult {
  final String displayName;
  final double latitude;
  final double longitude;

  const _PlaceResult({
    required this.displayName,
    required this.latitude,
    required this.longitude,
  });
}
