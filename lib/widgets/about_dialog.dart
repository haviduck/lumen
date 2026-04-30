import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class AboutDialog extends StatelessWidget {
  const AboutDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          color: const Color(0xFF14171D),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF272C36), width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x80000000),
              blurRadius: 40,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 36),

            // Logo mark
            Image.asset(
              'assets/images/lumen_logo.png',
              width: 64,
              height: 64,
              filterQuality: FilterQuality.high,
            ),

            const SizedBox(height: 10),

            // App name
            const Text(
              'Lumen',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w200,
                color: DuckColors.pearlWhite,
                letterSpacing: 4,
              ),
            ),

            const SizedBox(height: 18),

            // Divider
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 40),
              height: 1,
              color: const Color(0xFF272C36),
            ),

            const SizedBox(height: 24),

            // Description
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'The other IDEs didn\'t fit my sloppy, ADHD-riddled way of life. '
                'I needed proper old-school backups via zip, Syncthing, and a '
                'simple way to add Ollama LLMs without becoming homeless.\n\n'
                'Hope it fits your needs as well. If not \u2014 suck it.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.fgMuted,
                  height: 1.65,
                ),
              ),
            ),

            const SizedBox(height: 28),

            // Divider
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 40),
              height: 1,
              color: const Color(0xFF272C36),
            ),

            const SizedBox(height: 20),

            // Author
            const Text(
              'Carl Martin Haug',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: DuckColors.fgPrimary,
                letterSpacing: 0.5,
              ),
            ),

            const SizedBox(height: 4),

            const Text(
              'calleduck@gmail.com',
              style: TextStyle(fontSize: 11.5, color: DuckColors.fgMuted),
            ),

            const SizedBox(height: 24),

            // Close button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SizedBox(
                width: double.infinity,
                height: 34,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFF1E2229),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: const BorderSide(
                        color: Color(0xFF272C36),
                        width: 1,
                      ),
                    ),
                  ),
                  child: const Text(
                    'Close',
                    style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
