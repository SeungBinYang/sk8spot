import 'package:web/web.dart' as web;

/// 현재 탭을 그대로 이동시킨다. `window.open(url, '_self')`(url_launcher가
/// 쓰는 경로)는 브라우저의 user-activation 판정에 따라 조용히 막힐 수 있다 —
/// 카카오 로그인 버튼이 스피너만 돌다 "로그인이 완료되지 않았어요"로 끝나는
/// 원인이었다. `location.href` 직접 대입은 팝업이 아니라 같은 탭의 평범한
/// 이동이라 그 판정 대상이 아니다.
void redirectTo(String url) {
  web.window.location.href = url;
}
