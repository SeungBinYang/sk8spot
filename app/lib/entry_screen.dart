import 'package:flutter/material.dart';

import 'auth.dart';
import 'entry_video_background.dart';
import 'responsive.dart';

/// 진입 화면 — 로그인 / 비로그인 시작 중 하나를 고르는 첫 화면.
///
/// 지도 앱은 원래 스플래시·진입 화면을 두지 않는다(docs/USER_FLOWS.md,
/// SCREEN_STRUCTURE.md — "지도가 0.2초라도 먼저"). 데모용으로 이 화면을
/// 앞에 둔 뒤에도 그 원칙을 최대한 지키기 위해, 이 화면은 앱 세션당 딱
/// 한 번만 보인다 — 이미 로그인돼 있거나 한 번 통과하면 다시 뜨지 않는다
/// (`auth_gate.dart` 참조). "비로그인으로 시작하기"는 실제 로그인 벽이
/// 아니라 그냥 안내 화면일 뿐이라는 게 핵심이다.
class EntryScreen extends StatelessWidget {
  const EntryScreen({super.key, required this.onPassGate});

  final VoidCallback onPassGate;

  Future<void> _login(BuildContext context) async {
    final ok = await requireLogin(context, '더 다양한 기능을 쓰려면');
    if (ok) onPassGate();
    // 취소/"나중에 하기"면 그냥 이 화면에 남는다 — 자동으로 게스트 처리하지 않는다.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
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
          Container(color: Colors.black.withValues(alpha: 0.45)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ResponsiveCenter(child: _EntryCard(onLogin: () => _login(context), onGuest: onPassGate)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.onLogin, required this.onGuest});

  final VoidCallback onLogin;
  final VoidCallback onGuest;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
      decoration: BoxDecoration(
        color: const Color(0xFF14161B),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 32, spreadRadius: 2),
        ],
      ),
      child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/branding/logo-mark-sticker.png', height: 84),
              const SizedBox(height: 20),
              const Text(
                'Skate Spot',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '스케이터가 직접 등록하고 함께 갱신하는\n스케이트 스팟 지도',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: onLogin,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF111827),
                ),
                child: const Text('로그인', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onGuest,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.6)),
                ),
                child: const Text(
                  '비로그인으로 시작하기',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '지도를 보는 건 로그인 없이도 계속 할 수 있어요',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
              ),
            ],
          ),
    );
  }
}
