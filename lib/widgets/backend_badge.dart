import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../media/media_backend.dart';

/// Tiny badge for a [MediaBackend].
/// Plex and Jellyfin use SVG assets rendered in `currentColor`.
/// VIDYA uses a Material Symbol icon.
/// Pass [color] to override the tint; otherwise inherits from context.
class BackendBadge extends StatelessWidget {
  final MediaBackend backend;
  final double size;
  final Color? color;

  const BackendBadge({super.key, required this.backend, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    final tint =
        color ??
        DefaultTextStyle.of(context).style.color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;

    if (backend == MediaBackend.vidya) {
      return Icon(Symbols.school_rounded, size: size, color: tint);
    }

    final asset = switch (backend) {
      MediaBackend.plex => 'assets/plex_chevron.svg',
      MediaBackend.jellyfin => 'assets/jellyfin_icon.svg',
      MediaBackend.vidya => '', // unreachable — handled above
    };
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: tint),
    );
  }
}
