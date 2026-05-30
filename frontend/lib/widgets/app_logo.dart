import 'package:flutter/material.dart';

/// Shattlecoach brand mark. Renders the master asset inside a rounded-rect
/// (iOS app-icon style) with a drop shadow.
///
/// Uses the PNG render rather than the source SVG because the SVG embeds a
/// base64 raster pattern that flutter_svg does not draw reliably.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});

  final double size;

  static const _asset = 'assets/logo/logo_v1.png';

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.22;
    return Material(
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        _asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}
