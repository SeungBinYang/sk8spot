import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// 진입 화면의 배경 비디오(웹 전용). 유튜브 iframe을 raw HTML로 붙이고
/// blur·스케일은 DOM 스타일로, dark overlay는 그 위에 얹는 평범한 Flutter
/// 위젯으로 처리한다 — BackdropFilter는 platform view(iframe) 뒤를
/// 블러하지 못하므로(브라우저가 따로 합성하는 DOM이라) iframe 자체에 CSS
/// blur를 건다.
Widget buildVideoBackground({required String youtubeId}) {
  if (web.window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    // 모션 민감 사용자는 정적 배경(그라디언트)만 보되, 비디오는 아예 마운트하지 않는다.
    return const SizedBox.shrink();
  }
  return _YoutubeBackground(youtubeId: youtubeId);
}

class _YoutubeBackground extends StatefulWidget {
  const _YoutubeBackground({required this.youtubeId});
  final String youtubeId;

  @override
  State<_YoutubeBackground> createState() => _YoutubeBackgroundState();
}

class _YoutubeBackgroundState extends State<_YoutubeBackground> {
  late final String _viewType = 'entry-yt-bg-${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final id = widget.youtubeId;
      final iframe = web.HTMLIFrameElement()
        ..src =
            'https://www.youtube.com/embed/$id'
            '?autoplay=1&mute=1&loop=1&playlist=$id'
            '&controls=0&showinfo=0&modestbranding=1&rel=0'
            '&iv_load_policy=3&playsinline=1&disablekb=1&fs=0'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.transform = 'scale(1.15)'
        ..style.filter = 'blur(18px)'
        ..style.opacity = '0'
        ..style.transition = 'opacity 500ms ease'
        ..style.pointerEvents = 'none'
        ..allow = 'autoplay; encrypted-media';
      // 로딩 실패/차단 시엔 onload가 끝내 안 불려 opacity 0(=아래 정적
      // fallback이 그대로 보임)으로 남는다 — 별도 에러 처리가 필요 없다.
      iframe.onload = (() {
        iframe.style.opacity = '1';
      }).toJS;

      return web.HTMLDivElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.overflow = 'hidden'
        ..appendChild(iframe);
    });
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: 1280,
          height: 720,
          child: HtmlElementView(viewType: _viewType),
        ),
      ),
    ),
  );
}
