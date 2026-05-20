import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Smart Vision Assist'**
  String get appName;

  /// No description provided for @getStarted.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get getStarted;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @emergency.
  ///
  /// In en, this message translates to:
  /// **'Emergency'**
  String get emergency;

  /// No description provided for @obstacleDetection.
  ///
  /// In en, this message translates to:
  /// **'Obstacle Detection'**
  String get obstacleDetection;

  /// No description provided for @readText.
  ///
  /// In en, this message translates to:
  /// **'Read Text'**
  String get readText;

  /// No description provided for @sceneDescription.
  ///
  /// In en, this message translates to:
  /// **'Scene Description'**
  String get sceneDescription;

  /// No description provided for @navigation.
  ///
  /// In en, this message translates to:
  /// **'Navigation'**
  String get navigation;

  /// No description provided for @homeTagline.
  ///
  /// In en, this message translates to:
  /// **'Your AI-powered vision companion'**
  String get homeTagline;

  /// No description provided for @captureImage.
  ///
  /// In en, this message translates to:
  /// **'Capture Image'**
  String get captureImage;

  /// No description provided for @chooseImage.
  ///
  /// In en, this message translates to:
  /// **'Choose Image'**
  String get chooseImage;

  /// No description provided for @noImageSelected.
  ///
  /// In en, this message translates to:
  /// **'No image selected'**
  String get noImageSelected;

  /// No description provided for @readAloud.
  ///
  /// In en, this message translates to:
  /// **'Read Aloud'**
  String get readAloud;

  /// No description provided for @cameraNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Camera not available'**
  String get cameraNotAvailable;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @voiceSpeed.
  ///
  /// In en, this message translates to:
  /// **'Voice Speed'**
  String get voiceSpeed;

  /// No description provided for @alertVolume.
  ///
  /// In en, this message translates to:
  /// **'Alert Volume'**
  String get alertVolume;

  /// No description provided for @emergencyContact.
  ///
  /// In en, this message translates to:
  /// **'Emergency Contact'**
  String get emergencyContact;

  /// No description provided for @accessibilityMode.
  ///
  /// In en, this message translates to:
  /// **'Accessibility Mode'**
  String get accessibilityMode;

  /// No description provided for @accessibilityModeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Larger text and high-contrast visuals'**
  String get accessibilityModeSubtitle;

  /// No description provided for @contactName.
  ///
  /// In en, this message translates to:
  /// **'Contact Name'**
  String get contactName;

  /// No description provided for @phoneNumber.
  ///
  /// In en, this message translates to:
  /// **'Phone Number'**
  String get phoneNumber;

  /// No description provided for @emergencyTitle.
  ///
  /// In en, this message translates to:
  /// **'Emergency Help'**
  String get emergencyTitle;

  /// No description provided for @emergencySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Press Send Alert to notify your trusted contact instantly.'**
  String get emergencySubtitle;

  /// No description provided for @emergencyNoContactSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add an emergency contact in Settings before using this screen.'**
  String get emergencyNoContactSubtitle;

  /// No description provided for @sendAlert.
  ///
  /// In en, this message translates to:
  /// **'Send Alert'**
  String get sendAlert;

  /// No description provided for @alertSentLabel.
  ///
  /// In en, this message translates to:
  /// **'Alert Sent'**
  String get alertSentLabel;

  /// No description provided for @callContact.
  ///
  /// In en, this message translates to:
  /// **'Call Contact'**
  String get callContact;

  /// No description provided for @trustedContact.
  ///
  /// In en, this message translates to:
  /// **'Trusted Contact'**
  String get trustedContact;

  /// No description provided for @alertSent.
  ///
  /// In en, this message translates to:
  /// **'Alert sent to your emergency contact.'**
  String get alertSent;

  /// No description provided for @callInitiated.
  ///
  /// In en, this message translates to:
  /// **'Calling your emergency contact…'**
  String get callInitiated;

  /// No description provided for @statusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready to Alert'**
  String get statusReady;

  /// No description provided for @systemStatus.
  ///
  /// In en, this message translates to:
  /// **'System Status'**
  String get systemStatus;

  /// No description provided for @noContactSaved.
  ///
  /// In en, this message translates to:
  /// **'No emergency contact saved yet.'**
  String get noContactSaved;

  /// No description provided for @addInSettings.
  ///
  /// In en, this message translates to:
  /// **'Add in Settings'**
  String get addInSettings;

  /// No description provided for @noContactError.
  ///
  /// In en, this message translates to:
  /// **'No emergency contact saved. Go to Settings to add one.'**
  String get noContactError;

  /// No description provided for @couldNotOpenSms.
  ///
  /// In en, this message translates to:
  /// **'Could not open SMS app.'**
  String get couldNotOpenSms;

  /// No description provided for @couldNotOpenDialer.
  ///
  /// In en, this message translates to:
  /// **'Could not open dialer.'**
  String get couldNotOpenDialer;

  /// No description provided for @updateContactHint.
  ///
  /// In en, this message translates to:
  /// **'Update your emergency contact anytime in Settings.'**
  String get updateContactHint;

  /// No description provided for @ocrSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Capture or choose an image to extract and read text aloud.'**
  String get ocrSubtitle;

  /// No description provided for @scanText.
  ///
  /// In en, this message translates to:
  /// **'Scan Text'**
  String get scanText;

  /// No description provided for @scannedResult.
  ///
  /// In en, this message translates to:
  /// **'Scanned Result'**
  String get scannedResult;

  /// No description provided for @noTextYet.
  ///
  /// In en, this message translates to:
  /// **'No text scanned yet.'**
  String get noTextYet;

  /// No description provided for @noTextYetHint.
  ///
  /// In en, this message translates to:
  /// **'Choose or capture an image and analysis will start automatically.'**
  String get noTextYetHint;

  /// No description provided for @noTextFound.
  ///
  /// In en, this message translates to:
  /// **'No readable text found in this image.'**
  String get noTextFound;

  /// No description provided for @scanningProgress.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get scanningProgress;

  /// No description provided for @sceneSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Capture or choose an image and let AI describe the scene for you.'**
  String get sceneSubtitle;

  /// No description provided for @describeScene.
  ///
  /// In en, this message translates to:
  /// **'Describe Scene'**
  String get describeScene;

  /// No description provided for @sceneResult.
  ///
  /// In en, this message translates to:
  /// **'Scene Description'**
  String get sceneResult;

  /// No description provided for @noSceneYet.
  ///
  /// In en, this message translates to:
  /// **'No scene described yet.'**
  String get noSceneYet;

  /// No description provided for @noSceneYetHint.
  ///
  /// In en, this message translates to:
  /// **'Choose or capture an image and analysis will start automatically.'**
  String get noSceneYetHint;

  /// No description provided for @analysingScene.
  ///
  /// In en, this message translates to:
  /// **'Analysing scene…'**
  String get analysingScene;

  /// No description provided for @analysingProgress.
  ///
  /// In en, this message translates to:
  /// **'Analysing…'**
  String get analysingProgress;

  /// No description provided for @navSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your destination for real-time guided safe navigation.'**
  String get navSubtitle;

  /// No description provided for @destinationHint.
  ///
  /// In en, this message translates to:
  /// **'Enter destination…'**
  String get destinationHint;

  /// No description provided for @startGuidance.
  ///
  /// In en, this message translates to:
  /// **'Start Guidance'**
  String get startGuidance;

  /// No description provided for @stopGuidance.
  ///
  /// In en, this message translates to:
  /// **'Stop Guidance'**
  String get stopGuidance;

  /// No description provided for @calculatingRoute.
  ///
  /// In en, this message translates to:
  /// **'Calculating route…'**
  String get calculatingRoute;

  /// No description provided for @startNewRoute.
  ///
  /// In en, this message translates to:
  /// **'Start New Route'**
  String get startNewRoute;

  /// No description provided for @currentInstruction.
  ///
  /// In en, this message translates to:
  /// **'Current Instruction'**
  String get currentInstruction;

  /// No description provided for @hazardAlerts.
  ///
  /// In en, this message translates to:
  /// **'Hazard Alerts'**
  String get hazardAlerts;

  /// No description provided for @noHazardsYet.
  ///
  /// In en, this message translates to:
  /// **'No hazards detected.'**
  String get noHazardsYet;

  /// No description provided for @noHazardsHint.
  ///
  /// In en, this message translates to:
  /// **'Hazards will appear here during active guidance.'**
  String get noHazardsHint;

  /// No description provided for @voiceGuidance.
  ///
  /// In en, this message translates to:
  /// **'Repeat Instruction'**
  String get voiceGuidance;

  /// No description provided for @arrivedLabel.
  ///
  /// In en, this message translates to:
  /// **'Arrived'**
  String get arrivedLabel;

  /// No description provided for @noFurtherHazards.
  ///
  /// In en, this message translates to:
  /// **'No further hazards.'**
  String get noFurtherHazards;

  /// No description provided for @scanningEnvironment.
  ///
  /// In en, this message translates to:
  /// **'Scanning environment…'**
  String get scanningEnvironment;

  /// No description provided for @stepOf.
  ///
  /// In en, this message translates to:
  /// **'Step {current} of {total}'**
  String stepOf(int current, int total);

  /// No description provided for @obstacleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Point the camera forward. Obstacles will be detected and announced.'**
  String get obstacleSubtitle;

  /// No description provided for @startDetection.
  ///
  /// In en, this message translates to:
  /// **'Start Detection'**
  String get startDetection;

  /// No description provided for @stopDetection.
  ///
  /// In en, this message translates to:
  /// **'Stop Detection'**
  String get stopDetection;

  /// No description provided for @detectionResult.
  ///
  /// In en, this message translates to:
  /// **'Detection Alerts'**
  String get detectionResult;

  /// No description provided for @noObstaclesYet.
  ///
  /// In en, this message translates to:
  /// **'No obstacles detected yet.'**
  String get noObstaclesYet;

  /// No description provided for @noObstaclesHint.
  ///
  /// In en, this message translates to:
  /// **'Tap Start Detection to begin scanning.'**
  String get noObstaclesHint;

  /// No description provided for @warningAlert.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get warningAlert;

  /// No description provided for @dangerAlert.
  ///
  /// In en, this message translates to:
  /// **'Danger'**
  String get dangerAlert;

  /// No description provided for @speakLastAlert.
  ///
  /// In en, this message translates to:
  /// **'Speak Last Alert'**
  String get speakLastAlert;

  /// No description provided for @scanningLabel.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get scanningLabel;

  /// No description provided for @ttsOcrWelcome.
  ///
  /// In en, this message translates to:
  /// **'Read Text screen. Choose or capture an image to scan.'**
  String get ttsOcrWelcome;

  /// No description provided for @ttsImageCapturedOcr.
  ///
  /// In en, this message translates to:
  /// **'Image captured.'**
  String get ttsImageCapturedOcr;

  /// No description provided for @ttsImageSelectedOcr.
  ///
  /// In en, this message translates to:
  /// **'Image selected.'**
  String get ttsImageSelectedOcr;

  /// No description provided for @ttsNoImagePrompt.
  ///
  /// In en, this message translates to:
  /// **'Please select or capture an image first.'**
  String get ttsNoImagePrompt;

  /// No description provided for @ttsSceneWelcome.
  ///
  /// In en, this message translates to:
  /// **'Scene Description screen. Choose or capture an image for AI to describe.'**
  String get ttsSceneWelcome;

  /// No description provided for @ttsImageCapturedScene.
  ///
  /// In en, this message translates to:
  /// **'Image captured.'**
  String get ttsImageCapturedScene;

  /// No description provided for @ttsImageSelectedScene.
  ///
  /// In en, this message translates to:
  /// **'Image selected.'**
  String get ttsImageSelectedScene;

  /// No description provided for @ttsSceneNoImagePrompt.
  ///
  /// In en, this message translates to:
  /// **'Please select or capture an image first.'**
  String get ttsSceneNoImagePrompt;

  /// No description provided for @ttsNavWelcome.
  ///
  /// In en, this message translates to:
  /// **'Navigation screen. Enter a destination and tap Start Guidance.'**
  String get ttsNavWelcome;

  /// No description provided for @ttsEnterDestFirst.
  ///
  /// In en, this message translates to:
  /// **'Please enter a destination first.'**
  String get ttsEnterDestFirst;

  /// No description provided for @ttsGuidanceStarted.
  ///
  /// In en, this message translates to:
  /// **'Guidance started to {dest}.'**
  String ttsGuidanceStarted(String dest);

  /// No description provided for @ttsGuidanceStopped.
  ///
  /// In en, this message translates to:
  /// **'Guidance stopped.'**
  String get ttsGuidanceStopped;

  /// No description provided for @ttsDetectionWelcome.
  ///
  /// In en, this message translates to:
  /// **'Obstacle Detection screen. Double tap the camera view or tap Start Detection.'**
  String get ttsDetectionWelcome;

  /// No description provided for @ttsDetectionStarted.
  ///
  /// In en, this message translates to:
  /// **'Detection started. Scanning for obstacles.'**
  String get ttsDetectionStarted;

  /// No description provided for @ttsDetectionStopped.
  ///
  /// In en, this message translates to:
  /// **'Detection stopped.'**
  String get ttsDetectionStopped;

  /// No description provided for @errorOccurred.
  ///
  /// In en, this message translates to:
  /// **'An error occurred. Please try again.'**
  String get errorOccurred;

  /// No description provided for @ttsHomeWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome. What would you like to do? Say: Navigation, Detection, Read Text, or Scene Description.'**
  String get ttsHomeWelcome;

  /// No description provided for @ttsListening.
  ///
  /// In en, this message translates to:
  /// **'Listening. Please say a command.'**
  String get ttsListening;

  /// No description provided for @ttsCommandNotUnderstood.
  ///
  /// In en, this message translates to:
  /// **'Sorry, I did not understand. Please try again.'**
  String get ttsCommandNotUnderstood;

  /// No description provided for @stopListening.
  ///
  /// In en, this message translates to:
  /// **'Stop listening'**
  String get stopListening;

  /// No description provided for @tapToSpeak.
  ///
  /// In en, this message translates to:
  /// **'Tap to speak'**
  String get tapToSpeak;

  /// No description provided for @listeningEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get listeningEllipsis;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
