import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'env.dart';
import 'favorites.dart';

/// 인증. 로그인 벽은 지도 앞이 아니라 **쓰기 행동 앞**에 둔다.
/// 열람은 전부 비회원으로 가능하다. (docs/USER_FLOWS.md)
///
/// Supabase의 내장 `signInWithOAuth(kakao)`를 쓰지 않는다.
/// 그건 항상 `account_email` + `profile_image` 스코프를 강제로 얹는데,
/// 카카오 이메일 동의항목은 **비즈니스 인증(본인인증)** 없이는 열리지 않아
/// `KOE205 / invalid_scope: account_email`로 로그인이 통째로 막힌다.
/// 이메일은 이 앱에서 애초에 쓰지 않는다 — 저장도 안 한다 (docs/DATA_MODEL.md).
///
/// 그래서 OIDC(openid 스코프)로 직접 인가 코드를 받고,
/// `kakao-oidc` Edge Function에서 code를 id_token으로 교환한 뒤
/// `signInWithIdToken`으로 세션을 만든다. client_secret은 그 함수 밖으로
/// 나가지 않는다. → supabase/functions/kakao-oidc, ARCHITECTURE.md
class Auth {
  static SupabaseClient get _db => Supabase.instance.client;

  static Session? get session => _db.auth.currentSession;
  static bool get isLoggedIn => session != null;
  static String? get userId => _db.auth.currentUser?.id;
  static Stream<AuthState> get changes => _db.auth.onAuthStateChange;

  /// 웹은 카카오 로그인 콘솔에 등록된 현재 origin, 모바일은 커스텀 스킴 딥링크.
  static String get _redirectUri =>
      kIsWeb ? Uri.base.origin : 'com.skatespot.sk8spot://login-callback';

  /// 모바일에서만 유효하다. 외부 브라우저를 열어도 앱 프로세스는 살아있어
  /// 이 값이 남는다.
  ///
  /// ponytail: 웹은 전체 페이지 리다이렉트라 왕복하면 Dart 메모리가 통째로
  /// 날아가 여기 넣어둔 값이 사라진다 — 그래서 웹 경로는 state 검증을 생략한다.
  /// 인가 코드가 1회용·단기 만료라 실사용 리스크는 낮다. 정식 CSRF 방어가
  /// 필요해지면 sessionStorage에 저장해서 리다이렉트를 넘겨야 한다.
  static String? _pendingState;

  static String _randomToken() {
    final rnd = Random.secure();
    return base64UrlEncode(List<int>.generate(24, (_) => rnd.nextInt(256)))
        .replaceAll('=', '');
  }

  static Future<void> signInWithKakao() async {
    final state = _randomToken();
    _pendingState = state;

    final uri = Uri.https('kauth.kakao.com', '/oauth/authorize', {
      'client_id': kakaoRestApiKey,
      'redirect_uri': _redirectUri,
      'response_type': 'code',
      'scope': 'openid profile_nickname', // account_email은 일부러 뺀다
      'state': state,
    });

    // 웹은 현재 탭을 그대로 카카오로 보낸다(_self) — 새 탭이면 로그인 후
    // 원래 탭이 그대로 남아 상태가 꼬인다. 모바일은 외부 브라우저를 연다.
    await launchUrl(
      uri,
      webOnlyWindowName: kIsWeb ? '_self' : null,
      mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
    );
  }

  /// 앱 시작 시(웹 — 리다이렉트로 돌아온 URL) 또는 딥링크 수신 시(모바일)
  /// 호출한다. `code`가 있으면 로그인을 마무리하고 true를 반환한다.
  static Future<bool> completeKakaoLogin(Uri uri) async {
    final code = uri.queryParameters['code'];
    if (code == null) return false;

    final returnedState = uri.queryParameters['state'];
    if (_pendingState != null && returnedState != _pendingState) {
      return false; // 모바일 한정 검증. 웹은 _pendingState가 애초에 비어 있다.
    }
    _pendingState = null;

    final res = await _db.functions.invoke('kakao-oidc', body: {
      'code': code,
      'redirect_uri': _redirectUri,
    });
    final data = res.data as Map<String, dynamic>?;
    final idToken = data?['id_token'] as String?;
    if (idToken == null) return false;

    await _db.auth.signInWithIdToken(
      provider: OAuthProvider.kakao,
      idToken: idToken,
      accessToken: data?['access_token'] as String?,
    );
    return true;
  }

  static Future<void> signOut() => _db.auth.signOut();

  /// 프로필은 DB 트리거가 가입 시 자동으로 만든다.
  /// 앱이 만들면 "로그인은 됐는데 프로필이 없는" 상태가 생긴다.
  static Future<Map<String, dynamic>?> myProfile() async {
    if (!isLoggedIn) return null;
    final rows = await _db.rpc('my_profile') as List;
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first as Map);
  }

  static Future<void> setNickname(String nickname) =>
      _db.rpc('set_my_nickname', params: {'p_nickname': nickname});

  /// 스팟은 지우지 않는다. 작성자만 익명화한다.
  static Future<void> deleteAccount() async {
    await _db.rpc('delete_my_account');
    await signOut();
  }
}

/// 쓰기 행동 앞에서 호출한다. 로그인되어 있으면 즉시 true.
///
/// ```dart
/// if (!await requireLogin(context, '스팟을 등록하려면')) return;
/// ```
///
/// 모바일은 로그인 후 이 함수가 true를 반환해 **중단된 행동이 이어진다.**
/// 웹은 OAuth가 페이지 전체를 리다이렉트하므로 앱이 재시작되고,
/// 사용자가 행동을 다시 눌러야 한다. (웹은 개발용이라 그대로 둔다)
Future<bool> requireLogin(BuildContext context, String reason) async {
  if (Auth.isLoggedIn) return true;

  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _LoginSheet(reason: reason),
  );
  return ok ?? false;
}

/// 전체 화면 로그인 페이지를 만들지 않는다. 하단 시트로 띄우고
/// 완료 후 원래 행동을 이어간다.
class _LoginSheet extends StatefulWidget {
  const _LoginSheet({required this.reason});
  final String reason;

  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _kakao() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Auth.signInWithKakao();

      // 모바일: 딥링크로 돌아오면 세션이 생긴다. 잠깐 기다렸다 확인한다.
      for (var i = 0; i < 40 && !Auth.isLoggedIn; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted) return;
      if (Auth.isLoggedIn) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _busy = false;
          _error = '로그인이 완료되지 않았어요';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '로그인에 실패했어요';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '${widget.reason} 로그인이 필요해요',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '지도를 보는 건 로그인 없이도 계속 할 수 있어요.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 20),

            FilledButton(
              onPressed: _busy ? null : _kakao,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFEE500),
                foregroundColor: const Color(0xFF191600),
                minimumSize: const Size.fromHeight(48),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('카카오로 계속하기',
                      style: TextStyle(fontWeight: FontWeight.w700)),
            ),

            // Apple 로그인은 iOS 심사 요건이라 붙여야 하지만,
            // 개발 환경이 Windows라 검증할 수 없다 → OPEN_DECISIONS 11
            const SizedBox(height: 8),

            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
            ],

            const SizedBox(height: 4),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('나중에 하기'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 내 정보 — 독립 화면을 만들지 않는다. 설정할 게 몇 개 없다.
Future<void> showMySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _MySheet(),
  );
}

class _MySheet extends StatefulWidget {
  const _MySheet();
  @override
  State<_MySheet> createState() => _MySheetState();
}

class _MySheetState extends State<_MySheet> {
  late final Future<Map<String, dynamic>?> _future = Auth.myProfile();

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('탈퇴할까요?'),
        content: const Text(
          '등록한 스팟은 지도에 남고 작성자만 익명 처리됩니다.\n'
          '다른 스케이터들이 쓰던 정보라 삭제하지 않아요.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('탈퇴', style: TextStyle(color: Color(0xFFDC2626))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Auth.deleteAccount();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!Auth.isLoggedIn) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('로그인하면 스팟을 등록하고 제보할 수 있어요',
                  style: TextStyle(fontSize: 15)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await requireLogin(context, '스팟을 등록하려면');
                },
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46)),
                child: const Text('로그인'),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: FutureBuilder<Map<String, dynamic>?>(
        future: _future,
        builder: (context, snap) {
          final p = snap.data;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: const Color(0xFFEFF2F7),
                      child: Text((p?['nickname'] as String? ?? '?')
                          .characters
                          .first),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p?['nickname'] as String? ?? '불러오는 중…',
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700)),
                          Text('등록한 스팟 ${p?['spot_count'] ?? 0}개',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.favorite_border, size: 20),
                  title: const Text('즐겨찾기', style: TextStyle(fontSize: 15)),
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FavoritesPage()),
                    );
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.logout, size: 20),
                  title: const Text('로그아웃', style: TextStyle(fontSize: 15)),
                  onTap: () async {
                    await Auth.signOut();
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_remove_outlined,
                      size: 20, color: Color(0xFFDC2626)),
                  title: const Text('탈퇴',
                      style: TextStyle(fontSize: 15, color: Color(0xFFDC2626))),
                  onTap: _confirmDelete,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
