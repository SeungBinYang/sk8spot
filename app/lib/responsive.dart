import 'package:flutter/material.dart';

import 'entry_video_background.dart';

/// PC 브라우저에서 시트·카드가 뷰포트 전체로 늘어나지 않도록 잡아주는 최대 폭.
/// 값 하나로 통일한다 — 화면별로 다르게 잡기 시작하면 끝이 없다.
const kResponsiveMaxWidth = 480.0;

/// 전체 화면 라우트(바텀시트가 아닌 것)의 본문을 가운데 폭 제한한다.
/// 바텀시트는 `showModalBottomSheet`의 내장 `constraints` 파라미터를 쓴다 —
/// 이 위젯이 필요한 건 `FavoritesPage`처럼 별도 라우트로 미는 화면뿐이다.
class ResponsiveCenter extends StatelessWidget {
  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = kResponsiveMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// 지도 홈(메인 콘텐츠)을 위한 프레임. 뷰포트가 지도 앱이 필요로 하는 폭보다
/// 넓어지면(PC 브라우저) 지도를 뷰포트 전체로 늘리는 대신 가운데로 폭을
/// 잡고, 좌우 여백엔 진입 화면과 같은 블러 영상 배경을 이어서 보여준다 —
/// 여백이 죽은 공간이 아니라 같은 톤의 배경이 되게.
class ResponsiveAppFrame extends StatelessWidget {
  const ResponsiveAppFrame({super.key, required this.child});

  final Widget child;

  static const _contentMaxWidth = 960.0;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= _contentMaxWidth) return child;

    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF111827), Colors.black],
            ),
          ),
        ),
        const EntryVideoBackground(youtubeId: kEntryYoutubeId),
        Container(color: Colors.black.withValues(alpha: 0.55)),
        Center(
          child: SizedBox(
            width: _contentMaxWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 48,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRect(child: child),
            ),
          ),
        ),
      ],
    );
  }
}
