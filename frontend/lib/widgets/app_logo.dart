import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Shattlecoach brand mark. Renders the master SVG asset at the requested
/// size; keep visual usage centralized here so swapping the asset is one edit.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});

  final double size;

  static const _asset = 'assets/logo/logo_v1.svg';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(_asset, width: size, height: size);
  }
}
