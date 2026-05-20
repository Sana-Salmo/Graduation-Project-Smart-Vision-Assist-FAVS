import 'package:flutter/material.dart';
import '../../core/constants/app_routes.dart';
import '../../l10n/app_localizations.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () =>
              Navigator.pushReplacementNamed(context, AppRoutes.home),
          child: Text(AppLocalizations.of(context)!.getStarted),
        ),
      ),
    );
  }
}
