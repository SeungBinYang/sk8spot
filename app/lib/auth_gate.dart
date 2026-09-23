import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth.dart';
import 'entry_screen.dart';
import 'map_home.dart';

/// 진입 화면 게이트. 단방향이다 — 한 번 통과하면(게스트 선택이든 로그인
/// 완료든) 세션 안에서는 다시 진입 화면으로 돌아가지 않는다. 나중에
/// 앱 안에서 로그아웃해도 되돌리지 않는다 — "지도가 0.2초라도 먼저"
/// 원칙에서 벗어나는 걸 딱 한 번으로만 제한한다.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late bool _pastGate = Auth.isLoggedIn;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    // 웹은 카카오 로그인이 전체 페이지 리다이렉트라, main()이 runApp 이후
    // 비동기로 완료시키는 로그인이 첫 프레임 이후에 뒤늦게 반영될 수 있다.
    // 모바일 딥링크도 같은 타이밍 문제가 있을 수 있어 함께 구독한다.
    _authSub = Auth.changes.listen((_) {
      if (!_pastGate && Auth.isLoggedIn && mounted) {
        setState(() => _pastGate = true);
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_pastGate) {
      return EntryScreen(onPassGate: () => setState(() => _pastGate = true));
    }
    // 지도는 다른 지도 앱들처럼 PC에서도 풀블리드로 둔다 — 좌우 여백을
    // 뭔가로 채우려 하면 시선만 뺏기고 부자연스러워진다.
    return const MapHome();
  }
}
