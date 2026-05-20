class ObjectLabelLocalizer {
  ObjectLabelLocalizer._();

  static const Map<String, String> _arObjects = {
    'person': 'شخص',
    'bicycle': 'دراجة',
    'car': 'سيارة',
    'motorcycle': 'دراجة نارية',
    'airplane': 'طائرة',
    'bus': 'حافلة',
    'train': 'قطار',
    'truck': 'شاحنة',
    'boat': 'قارب',
    'traffic light': 'إشارة مرور',
    'fire hydrant': 'صنبور إطفاء',
    'stop sign': 'علامة توقف',
    'parking meter': 'عداد مواقف',
    'bench': 'مقعد',
    'bird': 'طائر',
    'cat': 'قطة',
    'dog': 'كلب',
    'horse': 'حصان',
    'sheep': 'خروف',
    'cow': 'بقرة',
    'elephant': 'فيل',
    'bear': 'دب',
    'zebra': 'حمار وحشي',
    'giraffe': 'زرافة',
    'backpack': 'حقيبة ظهر',
    'umbrella': 'مظلة',
    'handbag': 'حقيبة يد',
    'tie': 'ربطة عنق',
    'suitcase': 'حقيبة سفر',
    'frisbee': 'قرص طائر',
    'skis': 'زلاجات',
    'snowboard': 'لوح تزلج',
    'sports ball': 'كرة',
    'kite': 'طائرة ورقية',
    'baseball bat': 'مضرب بيسبول',
    'baseball glove': 'قفاز بيسبول',
    'skateboard': 'لوح تزلج',
    'surfboard': 'لوح ركوب أمواج',
    'tennis racket': 'مضرب تنس',
    'bottle': 'زجاجة',
    'wine glass': 'كأس',
    'cup': 'كوب',
    'fork': 'شوكة',
    'knife': 'سكين',
    'spoon': 'ملعقة',
    'bowl': 'وعاء',
    'banana': 'موزة',
    'apple': 'تفاحة',
    'sandwich': 'شطيرة',
    'orange': 'برتقالة',
    'broccoli': 'بروكلي',
    'carrot': 'جزرة',
    'hot dog': 'هوت دوغ',
    'pizza': 'بيتزا',
    'donut': 'دونات',
    'cake': 'كعكة',
    'chair': 'كرسي',
    'couch': 'أريكة',
    'potted plant': 'نبتة',
    'bed': 'سرير',
    'dining table': 'طاولة طعام',
    'toilet': 'مرحاض',
    'tv': 'تلفاز',
    'laptop': 'حاسوب محمول',
    'mouse': 'فأرة حاسوب',
    'remote': 'جهاز تحكم',
    'keyboard': 'لوحة مفاتيح',
    'cell phone': 'هاتف',
    'microwave': 'ميكروويف',
    'oven': 'فرن',
    'toaster': 'محمصة',
    'sink': 'حوض',
    'refrigerator': 'ثلاجة',
    'book': 'كتاب',
    'clock': 'ساعة',
    'vase': 'مزهرية',
    'scissors': 'مقص',
    'teddy bear': 'دمية',
    'hair drier': 'مجفف شعر',
    'toothbrush': 'فرشاة أسنان',
    'pole': 'عمود',
    'stairs': 'درج',
    'object': 'جسم',
  };

  static String object(String label, {required bool arabic}) {
    if (!arabic) return label;
    return _arObjects[label.toLowerCase().trim()] ?? label;
  }

  static String direction(String direction, {required bool arabic}) {
    if (!arabic) return direction;
    switch (direction.toLowerCase().trim()) {
      case 'left':
        return 'يسار';
      case 'right':
        return 'يمين';
      case 'centre':
      case 'center':
        return 'الوسط';
      default:
        return direction;
    }
  }

  static String tip(String tip, {required bool arabic}) {
    if (!arabic) return tip;
    switch (tip.toLowerCase().trim()) {
      case 'stop immediately':
        return 'توقف فوراً';
      case 'proceed with care':
        return 'تابع بحذر';
      default:
        return tip;
    }
  }

  static String alertSentence({
    required String label,
    required String direction,
    required String distance,
    required String tip,
    required bool arabic,
    bool warning = false,
  }) {
    final objectLabel = object(label, arabic: arabic);
    final localizedDirection = ObjectLabelLocalizer.direction(
      direction,
      arabic: arabic,
    );
    final localizedTip = ObjectLabelLocalizer.tip(tip, arabic: arabic);
    final tipPart = localizedTip.trim().isEmpty ? '' : ' $localizedTip.';
    if (arabic) {
      final prefix = warning ? 'تحذير! ' : '';
      return '$prefix$objectLabel. $localizedDirection. $distance.$tipPart';
    }
    final prefix = warning ? 'Warning! ' : '';
    return '$prefix$label. $direction. $distance.$tipPart';
  }
}
