import 'package:flutter/widgets.dart';

/// 네이티브(모바일) 빌드용 자리표시자. 이 앱엔 비디오 플러그인이 없고
/// 지금 필요한 건 웹 데모라 네이티브는 정적 배경으로만 대체한다 — 의도된 범위.
Widget buildVideoBackground({required String youtubeId}) =>
    const SizedBox.shrink();
