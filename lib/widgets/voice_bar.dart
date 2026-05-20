import 'package:flutter/material.dart';

import '../core/constants/app_colors.dart';
import '../core/utils/voice_enabled_mixin.dart';

/// A persistent bottom bar that exposes the mic button for any screen that
/// uses [VoiceEnabledMixin].  Drop it into [Scaffold.bottomNavigationBar].
///
/// Example:
///   bottomNavigationBar: VoiceBar(voice: this),
class VoiceBar extends StatelessWidget {
  final VoiceEnabledMixin voice;

  const VoiceBar({super.key, required this.voice});

  @override
  Widget build(BuildContext context) {
    final listening = voice.voiceListening;
    final partial = voice.voicePartialResult;

    return SafeArea(
      top: false,
      child: Container(
        height: 72,
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: Colors.grey.shade200)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Mic button
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Semantics(
                button: true,
                label: listening ? 'Stop voice command' : 'Start voice command',
                child: GestureDetector(
                  onTap: voice.toggleVoiceListening,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: listening ? AppColors.error : AppColors.primary,
                      boxShadow: [
                        BoxShadow(
                          color:
                              (listening ? AppColors.error : AppColors.primary)
                                  .withValues(alpha: listening ? 0.40 : 0.25),
                          blurRadius: listening ? 14 : 6,
                          spreadRadius: listening ? 3 : 0,
                        ),
                      ],
                    ),
                    child: Icon(
                      listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(width: 12),

            // Status / partial-result text
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Text(
                  key: ValueKey(partial ?? listening.toString()),
                  partial != null && partial.isNotEmpty
                      ? partial
                      : listening
                      ? voice.listeningPrompt
                      : voice.voiceIdleHint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: listening ? AppColors.error : AppColors.textMuted,
                    fontStyle: partial != null && partial.isNotEmpty
                        ? FontStyle.normal
                        : FontStyle.italic,
                  ),
                ),
              ),
            ),

            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
