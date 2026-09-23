import 'package:flutter/widgets.dart';

import 'entry_video_background_stub.dart'
    if (dart.library.js_interop) 'entry_video_background_web.dart' as impl;

/// 진입 화면과 PC 와이드 레이아웃 여백에서 공유하는 배경 영상 ID.
/// https://www.youtube.com/watch?v=cW9OABECQkU
const kEntryYoutubeId = 'cW9OABECQkU';

/// 진입 화면 배경 비디오. 웹에서만 실제로 렌더링되고(§3), 네이티브는
/// 빈 위젯을 돌려준다 — 호출부는 플랫폼을 신경 쓰지 않아도 된다.
class EntryVideoBackground extends StatelessWidget {
  const EntryVideoBackground({super.key, required this.youtubeId});

  final String youtubeId;

  @override
  Widget build(BuildContext context) =>
      impl.buildVideoBackground(youtubeId: youtubeId);
}
