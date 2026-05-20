// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Smart Vision Assist';

  @override
  String get getStarted => 'Get Started';

  @override
  String get home => 'Home';

  @override
  String get settings => 'Settings';

  @override
  String get emergency => 'Emergency';

  @override
  String get obstacleDetection => 'Obstacle Detection';

  @override
  String get readText => 'Read Text';

  @override
  String get sceneDescription => 'Scene Description';

  @override
  String get navigation => 'Navigation';

  @override
  String get homeTagline => 'Your AI-powered vision companion';

  @override
  String get captureImage => 'Capture Image';

  @override
  String get chooseImage => 'Choose Image';

  @override
  String get noImageSelected => 'No image selected';

  @override
  String get readAloud => 'Read Aloud';

  @override
  String get cameraNotAvailable => 'Camera not available';

  @override
  String get language => 'Language';

  @override
  String get voiceSpeed => 'Voice Speed';

  @override
  String get alertVolume => 'Alert Volume';

  @override
  String get emergencyContact => 'Emergency Contact';

  @override
  String get accessibilityMode => 'Accessibility Mode';

  @override
  String get accessibilityModeSubtitle =>
      'Larger text and high-contrast visuals';

  @override
  String get contactName => 'Contact Name';

  @override
  String get phoneNumber => 'Phone Number';

  @override
  String get emergencyTitle => 'Emergency Help';

  @override
  String get emergencySubtitle =>
      'Press Send Alert to notify your trusted contact instantly.';

  @override
  String get emergencyNoContactSubtitle =>
      'Add an emergency contact in Settings before using this screen.';

  @override
  String get sendAlert => 'Send Alert';

  @override
  String get alertSentLabel => 'Alert Sent';

  @override
  String get callContact => 'Call Contact';

  @override
  String get trustedContact => 'Trusted Contact';

  @override
  String get alertSent => 'Alert sent to your emergency contact.';

  @override
  String get callInitiated => 'Calling your emergency contact…';

  @override
  String get statusReady => 'Ready to Alert';

  @override
  String get systemStatus => 'System Status';

  @override
  String get noContactSaved => 'No emergency contact saved yet.';

  @override
  String get addInSettings => 'Add in Settings';

  @override
  String get noContactError =>
      'No emergency contact saved. Go to Settings to add one.';

  @override
  String get couldNotOpenSms => 'Could not open SMS app.';

  @override
  String get couldNotOpenDialer => 'Could not open dialer.';

  @override
  String get updateContactHint =>
      'Update your emergency contact anytime in Settings.';

  @override
  String get ocrSubtitle =>
      'Capture or choose an image to extract and read text aloud.';

  @override
  String get scanText => 'Scan Text';

  @override
  String get scannedResult => 'Scanned Result';

  @override
  String get noTextYet => 'No text scanned yet.';

  @override
  String get noTextYetHint =>
      'Choose or capture an image and analysis will start automatically.';

  @override
  String get noTextFound => 'No readable text found in this image.';

  @override
  String get scanningProgress => 'Scanning…';

  @override
  String get sceneSubtitle =>
      'Capture or choose an image and let AI describe the scene for you.';

  @override
  String get describeScene => 'Describe Scene';

  @override
  String get sceneResult => 'Scene Description';

  @override
  String get noSceneYet => 'No scene described yet.';

  @override
  String get noSceneYetHint =>
      'Choose or capture an image and analysis will start automatically.';

  @override
  String get analysingScene => 'Analysing scene…';

  @override
  String get analysingProgress => 'Analysing…';

  @override
  String get navSubtitle =>
      'Enter your destination for real-time guided safe navigation.';

  @override
  String get destinationHint => 'Enter destination…';

  @override
  String get startGuidance => 'Start Guidance';

  @override
  String get stopGuidance => 'Stop Guidance';

  @override
  String get calculatingRoute => 'Calculating route…';

  @override
  String get startNewRoute => 'Start New Route';

  @override
  String get currentInstruction => 'Current Instruction';

  @override
  String get hazardAlerts => 'Hazard Alerts';

  @override
  String get noHazardsYet => 'No hazards detected.';

  @override
  String get noHazardsHint =>
      'Hazards will appear here during active guidance.';

  @override
  String get voiceGuidance => 'Repeat Instruction';

  @override
  String get arrivedLabel => 'Arrived';

  @override
  String get noFurtherHazards => 'No further hazards.';

  @override
  String get scanningEnvironment => 'Scanning environment…';

  @override
  String stepOf(int current, int total) {
    return 'Step $current of $total';
  }

  @override
  String get obstacleSubtitle =>
      'Point the camera forward. Obstacles will be detected and announced.';

  @override
  String get startDetection => 'Start Detection';

  @override
  String get stopDetection => 'Stop Detection';

  @override
  String get detectionResult => 'Detection Alerts';

  @override
  String get noObstaclesYet => 'No obstacles detected yet.';

  @override
  String get noObstaclesHint => 'Tap Start Detection to begin scanning.';

  @override
  String get warningAlert => 'Warning';

  @override
  String get dangerAlert => 'Danger';

  @override
  String get speakLastAlert => 'Speak Last Alert';

  @override
  String get scanningLabel => 'Scanning…';

  @override
  String get ttsOcrWelcome =>
      'Read Text screen. Choose or capture an image to scan.';

  @override
  String get ttsImageCapturedOcr => 'Image captured.';

  @override
  String get ttsImageSelectedOcr => 'Image selected.';

  @override
  String get ttsNoImagePrompt => 'Please select or capture an image first.';

  @override
  String get ttsSceneWelcome =>
      'Scene Description screen. Choose or capture an image for AI to describe.';

  @override
  String get ttsImageCapturedScene => 'Image captured.';

  @override
  String get ttsImageSelectedScene => 'Image selected.';

  @override
  String get ttsSceneNoImagePrompt =>
      'Please select or capture an image first.';

  @override
  String get ttsNavWelcome =>
      'Navigation screen. Enter a destination and tap Start Guidance.';

  @override
  String get ttsEnterDestFirst => 'Please enter a destination first.';

  @override
  String ttsGuidanceStarted(String dest) {
    return 'Guidance started to $dest.';
  }

  @override
  String get ttsGuidanceStopped => 'Guidance stopped.';

  @override
  String get ttsDetectionWelcome =>
      'Obstacle Detection screen. Double tap the camera view or tap Start Detection.';

  @override
  String get ttsDetectionStarted =>
      'Detection started. Scanning for obstacles.';

  @override
  String get ttsDetectionStopped => 'Detection stopped.';

  @override
  String get errorOccurred => 'An error occurred. Please try again.';

  @override
  String get ttsHomeWelcome =>
      'Welcome. What would you like to do? Say: Navigation, Detection, Read Text, or Scene Description.';

  @override
  String get ttsListening => 'Listening. Please say a command.';

  @override
  String get ttsCommandNotUnderstood =>
      'Sorry, I did not understand. Please try again.';

  @override
  String get stopListening => 'Stop listening';

  @override
  String get tapToSpeak => 'Tap to speak';

  @override
  String get listeningEllipsis => 'Listening…';
}
