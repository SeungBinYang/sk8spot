import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'responsive.dart';
import 'spot.dart';
import 'spot_sheet.dart';

/// 즐겨찾기 목록 — 별도 탭이 없으므로 "내 정보" 시트에서 진입하는 전체 화면이다.
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  late Future<List<SpotPin>> _future = SpotRepo.myFavorites();

  Future<void> _refresh() async {
    final next = SpotRepo.myFavorites();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('즐겨찾기')),
      body: ResponsiveCenter(
        child: FutureBuilder<List<SpotPin>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(child: Text('불러오지 못했어요'));
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final pins = snap.data!;
            if (pins.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: 0.6,
                      child: Image.asset(
                        'assets/branding/icon-flat-fullbleed.png',
                        height: 96,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('저장한 스팟이 없어요',
                        style: TextStyle(color: Colors.grey.shade600)),
                  ],
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: pins.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final p = pins[i];
                  return _FavoriteTile(
                    pin: p,
                    onTap: () async {
                      await showSpotDetail(context, p);
                      // 상세에서 즐겨찾기를 해제했을 수 있어 돌아오면 다시 불러온다.
                      if (mounted) unawaited(_refresh());
                    },
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FavoriteTile extends StatelessWidget {
  const _FavoriteTile({required this.pin, required this.onTap});
  final SpotPin pin;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x14000000)),
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: pin.type.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(pin.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(pin.type.label,
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                if (pin.status.badge != null)
                  Icon(Icons.info_outline, size: 16, color: pin.status.color),
              ],
            ),
          ),
        ),
      );
}
