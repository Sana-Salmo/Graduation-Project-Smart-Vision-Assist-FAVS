import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/app_colors.dart';
import '../../core/utils/tts_helper.dart';
import '../../core/utils/voice_enabled_mixin.dart';
import '../../l10n/app_localizations.dart';
import '../../services/ocr_service.dart';
import '../../widgets/voice_bar.dart';

class OcrScreen extends StatefulWidget {
  const OcrScreen({super.key});

  @override
  State<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends State<OcrScreen> with VoiceEnabledMixin {
  XFile? _pickedImage;
  bool _scanning = false;
  String? _scannedText;

  final _picker = ImagePicker();

  bool get _imageSelected => _pickedImage != null;

  // ── VoiceEnabledMixin contract ─────────────────────────────────────────────

  @override
  String get screenWelcome => AppLocalizations.of(context)!.ttsOcrWelcome;

  @override
  Map<List<String>, VoidCallback> get voiceCommands => {
    ['camera', 'capture', 'كاميرا', 'التقاط']: _captureFromCamera,
    ['gallery', 'photo', 'معرض', 'صورة']: _pickFromGallery,
    ['retry', 'scan again', 'إعادة', 'مسح']: () {
      if (_imageSelected) _scanText();
    },
    ['read', 'speak', 'aloud', 'اقرأ', 'قراءة']: _readAloud,
    ['back', 'home', 'رجوع', 'الرئيسية']: () => Navigator.pop(context),
  };

  // initState is provided by VoiceEnabledMixin (speaks screenWelcome).

  @override
  void dispose() {
    TtsHelper.stop();
    super.dispose(); // calls mixin dispose → voiceService.stopListening()
  }

  Future<void> _captureFromCamera() async {
    await stopVoiceListening();
    // Capture l10n strings before the async gap.
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: CameraDevice.rear,
      imageQuality: 90,
    );
    if (file == null || !mounted) return;
    setState(() {
      _pickedImage = file;
      _scannedText = null;
    });
    // Announce and immediately begin extraction — no button press required.
    await _announceProcessing(captured: true);
    if (mounted) _scanText();
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
      _scannedText = null;
    });
    await _announceProcessing(captured: false);
    if (mounted) _scanText();
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

  Future<void> _scanText() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_imageSelected) {
      TtsHelper.speak(l10n.ttsNoImagePrompt);
      return;
    }
    setState(() => _scanning = true);
    try {
      final result = await OcrService.extractText(File(_pickedImage!.path));
      if (!mounted) return;
      final text = result.isEmpty ? l10n.noTextFound : result;
      setState(() {
        _scanning = false;
        _scannedText = text;
      });
      await TtsHelper.speak(text);
      await restartVoiceListeningSoon();
    } on OcrException catch (e) {
      if (!mounted) return;
      final msg = e.message == 'empty' ? l10n.noTextFound : e.message;
      setState(() {
        _scanning = false;
        if (e.message != 'empty') _scannedText = msg;
      });
      await TtsHelper.speak(msg);
      await restartVoiceListeningSoon();
      if (!mounted) return;
      if (e.message != 'empty') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _scanning = false);
      await TtsHelper.speak(l10n.errorOccurred);
      await restartVoiceListeningSoon();
    }
  }

  void _readAloud() {
    if (_scannedText == null) return;
    TtsHelper.speak(_scannedText!);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      bottomNavigationBar: VoiceBar(voice: this),
      appBar: AppBar(
        title: Text(
          l10n.readText,
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
                label: 'Image preview',
                hint: _imageSelected
                    ? 'Double tap to scan text'
                    : 'No image selected. Use buttons below to choose.',
                child: GestureDetector(
                  onDoubleTap: _scanText,
                  child: _ImagePreview(pickedImage: _pickedImage),
                ),
              ),
              const SizedBox(height: 20),
              _ImageSourceRow(
                scanning: _scanning,
                onCamera: _captureFromCamera,
                onGallery: _pickFromGallery,
              ),
              const SizedBox(height: 28),
              _ResultCard(scanning: _scanning, scannedText: _scannedText),
              // Retry is only shown after a result (or error) so the user can
              // re-scan without picking the image again.
              if (_scannedText != null && !_scanning) ...[
                const SizedBox(height: 12),
                _RetryButton(onPressed: _scanText),
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
      AppLocalizations.of(context)!.ocrSubtitle,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 15,
        color: AppColors.textMuted,
        height: 1.5,
      ),
    );
  }
}

// ── Image preview ─────────────────────────────────────────────────────────────

class _ImagePreview extends StatelessWidget {
  final XFile? pickedImage;
  const _ImagePreview({required this.pickedImage});

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
          color: hasImage ? AppColors.primary : const Color(0xFFDDDDDD),
          width: hasImage ? 2 : 1.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasImage
          ? Image.file(
              File(pickedImage!.path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _EmptyImagePlaceholder(),
            )
          : _EmptyImagePlaceholder(),
    );
  }
}

class _EmptyImagePlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.image_outlined, size: 64, color: Color(0xFFBDBDBD)),
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
  final bool scanning;
  final VoidCallback onCamera;
  final VoidCallback onGallery;

  const _ImageSourceRow({
    required this.scanning,
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
              onPressed: scanning ? null : onCamera,
              icon: const Icon(Icons.camera_alt_rounded, size: 20),
              label: Text(
                l10n.captureImage,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: const BorderSide(color: AppColors.primary, width: 1.5),
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
              onPressed: scanning ? null : onGallery,
              icon: const Icon(Icons.photo_library_rounded, size: 20),
              label: Text(
                l10n.chooseImage,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: const BorderSide(color: AppColors.primary, width: 1.5),
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

// ── Scan Text button ──────────────────────────────────────────────────────────

// ── Retry button (shown after result or error) ────────────────────────────────

class _RetryButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _RetryButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Retry text extraction',
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
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 12),
            side: const BorderSide(color: AppColors.primary),
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
  final bool scanning;
  final String? scannedText;

  const _ResultCard({required this.scanning, required this.scannedText});

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
                Icons.text_snippet_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.scannedResult,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          if (scanning)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: CircularProgressIndicator(),
              ),
            )
          else if (scannedText != null)
            Text(
              scannedText!,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textDark,
                height: 1.6,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 8),
                Icon(
                  Icons.text_fields_rounded,
                  size: 40,
                  color: Colors.grey.shade300,
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.noTextYet,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.noTextYetHint,
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
