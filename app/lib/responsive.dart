import 'package:flutter/material.dart';

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
