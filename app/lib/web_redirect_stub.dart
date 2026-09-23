/// 네이티브 빌드에서는 호출되지 않는다 — 호출부가 kIsWeb으로 이미 막는다.
void redirectTo(String url) {
  throw UnsupportedError('redirectTo는 웹에서만 쓴다');
}
