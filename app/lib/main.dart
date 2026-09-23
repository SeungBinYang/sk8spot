import 'dart:async' show unawaited;

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:kakao_map_sdk/kakao_map_sdk.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth.dart';
import 'env.dart';
import 'map_home.dart';
import 'spot_sheet.dart' show openSharedSpot;

/// 앱 어디서든 화면을 열어야 하는 딥링크 처리부(main)가 위젯 트리 바깥에서
/// 실행되므로, BuildContext를 얻는 유일한 통로다.
final navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Future.wait([
    Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey),
    KakaoMapSdk.instance.initialize(kakaoAppKey),
  ]);

  runApp(const Sk8SpotApp());

  // 카카오 로그인 콜백 + 스팟 공유 딥링크. 둘 다 같은 커스텀 스킴으로 들어오고
  // host로 구분한다 (login-callback / spot). UI를 막지 않도록 runApp 뒤에 둔다.
  if (kIsWeb) {
    // 웹은 전체 페이지 리다이렉트라 앱이 새로 시작되고, 돌아온 URL의
    // 쿼리에 code가 실려 있다. 공유 링크는 모바일 전용이라 여기선 처리하지 않는다.
    unawaited(Auth.completeKakaoLogin(Uri.base));
  } else {
    // 모바일은 외부 브라우저/OS가 커스텀 스킴으로 앱을 다시 연다.
    final appLinks = AppLinks();
    appLinks.uriLinkStream.listen(_handleLink);
    final initial = await appLinks.getInitialLink();
    if (initial != null) unawaited(_handleLink(initial));
  }
}

Future<void> _handleLink(Uri uri) async {
  if (uri.host == 'login-callback') {
    unawaited(Auth.completeKakaoLogin(uri));
    return;
  }
  if (uri.host != 'spot') return;

  final id = int.tryParse(uri.pathSegments.isEmpty ? '' : uri.pathSegments.first);
  if (id == null) return;

  // 콜드 스타트 직후엔 첫 프레임이 아직 안 붙어 navigatorKey가 비어 있을 수
  // 있다. 짧게 기다렸다 재시도한다 (최대 1초).
  for (var i = 0; i < 10 && navigatorKey.currentContext == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final ctx = navigatorKey.currentContext;
  if (ctx != null) await openSharedSpot(ctx, id);
}

class Sk8SpotApp extends StatelessWidget {
  const Sk8SpotApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Skate Spot',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF111827)),
        ),
        // 스플래시도 온보딩도 두지 않는다. 지도가 0.2초라도 먼저 뜨는 게 낫다.
        home: const MapHome(),
      );
}
