import 'web_redirect_stub.dart' if (dart.library.js_interop) 'web_redirect_web.dart' as impl;

/// 웹에서 카카오 로그인 페이지로 현재 탭을 이동시킨다 (auth.dart 전용).
void redirectTo(String url) => impl.redirectTo(url);
