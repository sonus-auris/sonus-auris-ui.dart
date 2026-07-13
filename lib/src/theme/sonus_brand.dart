// The Sonus Auris logo mark widget (green square, ear glyph, orange dot).
import 'package:flutter/material.dart';

import 'sonus_theme.dart';

/// The Sonus Auris app mark: a rounded green-gradient square with a white ear
/// glyph and the brand's orange dot — a Flutter echo of the site's SVG logo.
class SonusLogoMark extends StatelessWidget {
  const SonusLogoMark({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              gradient: SonusColors.markGradient,
              borderRadius: BorderRadius.circular(size * 0.28),
            ),
            child: Icon(
              Icons.hearing,
              color: SonusColors.paper,
              size: size * 0.62,
            ),
          ),
          Positioned(
            right: -size * 0.04,
            top: -size * 0.04,
            child: Container(
              width: size * 0.30,
              height: size * 0.30,
              decoration: const BoxDecoration(
                color: SonusColors.orange500,
                shape: BoxShape.circle,
                boxShadow: kSonusShadowSm,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Logo mark + "Sonus Auris / AUDIO DASHCAM" lockup, used in the app bar.
class SonusWordmark extends StatelessWidget {
  const SonusWordmark({super.key, this.markSize = 32});

  final double markSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SonusLogoMark(size: markSize),
        const SizedBox(width: 11),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Sonus Auris',
              style: TextStyle(
                fontFamily: kSonusFontFamily,
                color: SonusColors.ink,
                fontWeight: FontWeight.w800,
                fontSize: 18,
                height: 1.05,
                letterSpacing: -0.3,
              ),
            ),
            Text(
              'AUDIO DASHCAM',
              style: TextStyle(
                fontFamily: kSonusFontFamily,
                color: SonusColors.inkSoft,
                fontWeight: FontWeight.w700,
                fontSize: 9,
                height: 1.1,
                letterSpacing: 1.6,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Small uppercase pill label ("eyebrow") matching the site's `.eyebrow`.
class SonusEyebrow extends StatelessWidget {
  const SonusEyebrow(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: SonusColors.green50,
        border: Border.all(color: SonusColors.green200),
        borderRadius: BorderRadius.circular(999),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: SonusColors.green700),
            const SizedBox(width: 6),
          ],
          Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontFamily: kSonusFontFamily,
              color: SonusColors.green700,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// The brand's primary CTA: an orange-gradient pill (matches `.btn-primary`).
/// Use for the single most prominent action on a screen.
class SonusGradientButton extends StatelessWidget {
  const SonusGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final button = DecoratedBox(
      decoration: BoxDecoration(
        gradient: enabled
            ? SonusColors.ctaGradient
            : const LinearGradient(
                colors: [Color(0xFFE7D2BE), Color(0xFFDCBFA6)],
              ),
        borderRadius: BorderRadius.circular(999),
        boxShadow: enabled ? kSonusShadowMd : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 15),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                ],
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: kSonusFontFamily,
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
