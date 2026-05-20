import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_colors.dart';
import '../../core/utils/tts_helper.dart';
import '../../core/utils/voice_enabled_mixin.dart';
import '../../l10n/app_localizations.dart';
import '../../services/scene_description_service.dart';
import '../../widgets/voice_bar.dart';

class SceneDescriptionScreen extends StatefulWidget {
  const SceneDescriptionScreen({super.key});

  @override
  State<SceneDescriptionScreen> createState() => _SceneDescriptionScreenState();
}

class _SceneDescriptionScreenState extends State<SceneDescriptionScreen>
    with VoiceEnabledMixin {
  XFile? _pickedImage;
  bool _describing = false;
  String? _description;

  final _picker = ImagePicker();

  bool get _imageSelected => _pickedImage != null;

  // ── VoiceEnabledMixin contract ─────────────────────────────────────────────

  @override
  String get screenWelcome => AppLocalizations.of(context)!.ttsSceneWelcome;

  @override
  Map<List<String>, VoidCallback> get voiceCommands => {
    ['camera', 'capture', 'كاميرا', 'التقاط']: _captureFromCamera,
    ['gallery', 'photo', 'معرض', 'صورة']: _pickFromGallery,
    ['retry', 'describe again', 'إعادة', 'وصف']: () {
      if (_imageSelected) _describeScene();
    },
    ['read', 'speak', 'aloud', 'اقرأ', 'قراءة']: _readAloud,
    ['back', 'home', 'رجوع', 'الرئيسية']: () => Navigator.pop(context),
  };

  @override
  void dispose() {
    TtsHelper.stop();
    super.dispose();
  }

  Future<void> _captureFromCamera() async {
    await stopVoiceListening();
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 90,
    );
    if (file == null || !mounted) return;
    setState(() {
      _pickedImage = file;
      _description = null;
    });
    // Announce and immediately begin description — no button press required.
    await _announceProcessing(captured: true);
    if (mounted) _describeScene();
  }

  Future<void> _pickFromGallery() async {
    await stopVoiceListening();
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null || !mounted) return;
    setState(() {
      _pickedImage = file;
      _description = null;
    });
    await _announceProcessing(captured: false);
    if (mounted) _describeScene();
  }

  Future<void> _announceProcessing({required bool captured}) {
    final isArabic = AppLocalizations.of(context)!.localeName == 'ar';
    final message = isArabic
        ? (captured
              ? 'تم التقاط الصورة بنجاح. جار المعالجة، الرجاء الانتظار قليلاً.'
              : 'تم اختيار الصورة بنجاح. جار المعالجة، الرجاء الانتظار قليلاً.')
        : (captured
              ? 'Image captured successfully. Processing. Please wait a moment.'
              : 'Image selected successfully. Processing. Please wait a moment.');
    return TtsHelper.speak(message);
  }

  Future<void> _describeScene() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_imageSelected) {
      TtsHelper.speak(l10n.ttsSceneNoImagePrompt);
      return;
    }
    setState(() => _describing = true);
    try {
      final result = await SceneDescriptionService.describe(
        File(_pickedImage!.path),
      );
      if (!mounted) return;
      setState(() {
        _describing = false;
        _description = result;
      });
      await TtsHelper.speak(result);
      await restartVoiceListeningSoon();
    } on SceneDescriptionException catch (e) {
      if (!mounted) return;
      setState(() {
        _describing = false;
        _description = e.message;
      });
      await TtsHelper.speak(e.message);
      await restartVoiceListeningSoon();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _describing = false);
      await TtsHelper.speak(l10n.errorOccurred);
      await restartVoiceListeningSoon();
    }
  }

  void _readAloud() {
    if (_description == null) return;
    TtsHelper.speak(_description!);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: VoiceBar(voice: this),
      appBar: AppBar(
        title: Text(
          l10n.sceneDescription,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _SubtitleText(),
              const SizedBox(height: 24),
              Semantics(
                label: 'Scene image preview',
                hint: _imageSelected
                    ? 'Double tap to describe scene'
                    : 'No image selected. Use buttons below to choose.',
                child: GestureDetector(
                  onDoubleTap: _describeScene,
                  child: _ScenePreview(pickedImage: _pickedImage),
                ),
              ),
              const SizedBox(height: 20),
              _ImageSourceRow(
                describing: _describing,
                onCamera: _captureFromCamera,
                onGallery: _pickFromGallery,
              ),
              const SizedBox(height: 28),
              _ResultCard(describing: _describing, description: _description),
              if (_description != null && !_describing) ...[
                const SizedBox(height: 12),
                _RetryButton(onPressed: _describeScene),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Subtitle ──────────────────────────────────────────────────────────────────

class _SubtitleText extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Text(
      AppLocalizations.of(context)!.sceneSubtitle,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 15,
        color: AppColors.textMuted,
        height: 1.5,
      ),
    );
  }
}

// ── Scene preview ─────────────────────────────────────────────────────────────

class _ScenePreview extends StatelessWidget {
  final XFile? pickedImage;
  const _ScenePreview({required this.pickedImage});

  @override
  Widget build(BuildContext context) {
    final hasImage = pickedImage != null;
    return Container(
      width: double.infinity,
      height: 220,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: hasImage ? const Color(0xFF6A1B9A) : const Color(0xFFDDDDDD),
          width: hasImage ? 2 : 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasImage
          ? Image.file(
              File(pickedImage!.path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _EmptyPreview(),
            )
          : _EmptyPreview(),
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.add_photo_alternate_outlined,
          size: 64,
          color: Color(0xFFBDBDBD),
        ),
        const SizedBox(height: 12),
        Text(
          AppLocalizations.of(context)!.noImageSelected,
          style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
        ),
      ],
    );
  }
}

// ── Image source row: Camera | Gallery ────────────────────────────────────────

class _ImageSourceRow extends StatelessWidget {
  final bool describing;
  final VoidCallback onCamera;
  final VoidCallback onGallery;

  const _ImageSourceRow({
    required this.describing,
    required this.onCamera,
    required this.onGallery,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            label: 'Capture image using camera',
            child: OutlinedButton.icon(
              onPressed: describing ? null : onCamera,
              icon: const Icon(Icons.camera_alt_rounded, size: 20),
              label: Text(
                l10n.captureImage,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF6A1B9A),
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: const BorderSide(color: Color(0xFF6A1B9A), width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Semantics(
            button: true,
            label: 'Choose image from gallery',
            child: OutlinedButton.icon(
              onPressed: describing ? null : onGallery,
              icon: const Icon(Icons.photo_library_rounded, size: 20),
              label: Text(
                l10n.chooseImage,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF6A1B9A),
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: const BorderSide(color: Color(0xFF6A1B9A), width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Describe button ───────────────────────────────────────────────────────────

// ── Retry button (shown after result or error) ────────────────────────────────

class _RetryButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _RetryButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Retry scene description',
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          label: const Text(
            'Retry',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF6A1B9A),
            padding: const EdgeInsets.symmetric(vertical: 12),
            side: const BorderSide(color: Color(0xFF6A1B9A)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Result card ───────────────────────────────────────────────────────────────

class _ResultCard extends StatelessWidget {
  final bool describing;
  final String? description;

  const _ResultCard({required this.describing, required this.description});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: Color(0xFF6A1B9A),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.sceneResult,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  color: Color(0xFF6A1B9A),
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          if (describing)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  children: [
                    const CircularProgressIndicator(color: Color(0xFF6A1B9A)),
                    const SizedBox(height: 14),
                    Text(
                      l10n.analysingScene,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (description != null)
            Text(
              description!,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textDark,
                height: 1.7,
              ),
            )
          else
            Column(
              children: [
                const SizedBox(height: 8),
                Icon(
                  Icons.image_search_rounded,
                  size: 42,
                  color: Colors.grey.shade300,
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.noSceneYet,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.noSceneYetHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
        ],
      ),
    );
  }
}
