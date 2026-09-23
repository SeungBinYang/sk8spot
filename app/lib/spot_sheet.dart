import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth.dart';
import 'env.dart';
import 'spot.dart';
import 'spot_register.dart' show pickAndPreparePhoto;

/// 공유 딥링크로 들어온 스팟을 상세 시트로 연다. `main.dart`의 딥링크 수신부에서
/// 호출한다 — 스팟이 그새 지워지거나 감춰졌으면 조용히 안내만 하고 끝낸다.
Future<void> openSharedSpot(BuildContext context, int spotId) async {
  SpotPin? pin;
  try {
    pin = await SpotRepo.pinById(spotId);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('공유 스팟을 불러오지 못했어요')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  if (pin == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('스팟을 찾을 수 없어요')),
    );
    return;
  }
  await showSpotDetail(context, pin);
}

/// 마커 탭 → 미리보기 시트. 지도를 덮지 않는 높이로 띄운다.
Future<void> showSpotPreview(BuildContext context, SpotPin pin) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Grabber(),
            const SizedBox(height: 12),
            _StatusBadge(status: pin.status, needsVerify: pin.needsVerify,
                openReports: pin.openReports),
            Text(pin.name,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(pin.type.label,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  showSpotDetail(context, pin);
                },
                child: const Text('자세히 보기'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 상세 — 정보를 나열하지 않고 **판단 순서대로** 배치한다.
/// 1) 지금 갈 수 있나 → 2) 어떻게 생겼나 → 3) 내가 탈 수 있나
/// → 4) 쫓겨나나 → 5) 언제 갈까 → 6) 어떻게 가나
Future<void> showSpotDetail(BuildContext context, SpotPin pin) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => _SpotDetailBody(pin: pin, scroll: scroll),
    ),
  );
}

class _SpotDetailBody extends StatefulWidget {
  const _SpotDetailBody({required this.pin, required this.scroll});
  final SpotPin pin;
  final ScrollController scroll;

  @override
  State<_SpotDetailBody> createState() => _SpotDetailBodyState();
}

class _SpotDetailBodyState extends State<_SpotDetailBody> {
  late final Future<SpotDetail> _future = SpotRepo.detail(widget.pin.id);
  Future<List<String>>? _photosFuture;
  late Future<bool> _favoriteFuture = SpotRepo.isFavorite(widget.pin.id);
  bool _favoriteBusy = false;

  Future<List<String>> get _photos =>
      _photosFuture ??= SpotRepo.photoUrls(widget.pin.id);

  Future<void> _toggleFavorite(bool current) async {
    if (!await requireLogin(context, '즐겨찾기하려면')) return;
    if (!mounted || _favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    try {
      if (current) {
        await SpotRepo.removeFavorite(widget.pin.id);
      } else {
        await SpotRepo.addFavorite(widget.pin.id);
      }
      if (mounted) {
        setState(() {
          _favoriteFuture = Future.value(!current);
          _favoriteBusy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _favoriteBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('즐겨찾기를 바꾸지 못했어요')),
        );
      }
    }
  }

  /// 공개 랜딩이 배포되면 HTTPS 주소로 공유한다. 그 전에는 설치 앱용 스킴이다.
  Future<void> _share(String name) async {
    final id = widget.pin.id;
    final base = Uri.tryParse(spotShareBaseUrl);
    final uri = base != null && base.scheme == 'https' && base.host.isNotEmpty
        ? base.replace(queryParameters: {'id': '$id'}).toString()
        : 'com.skatespot.sk8spot://spot/$id';
    await SharePlus.instance.share(
      ShareParams(text: '$name — 스케이트 스팟\n$uri'),
    );
  }

  Future<void> _addPhoto() async {
    if (!await requireLogin(context, '사진을 추가하려면')) return;
    if (!mounted) return;
    final bytes = await pickAndPreparePhoto(context);
    if (bytes == null || !mounted) return;
    try {
      await SpotRepo.uploadPhoto(
          spotId: widget.pin.id, bytes: bytes, isCover: false);
      setState(() => _photosFuture = SpotRepo.photoUrls(widget.pin.id));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('사진을 올리지 못했어요')),
        );
      }
    }
  }

  Future<void> _openDirections() async {
    final p = widget.pin;
    // 길찾기를 직접 만들지 않는다. 외부 지도 앱에 넘긴다.
    final uri = Uri.parse(
      'https://map.kakao.com/link/to/${Uri.encodeComponent(p.name)},${p.lat},${p.lng}',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('지도 앱을 열지 못했어요')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SpotDetail>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('정보를 불러오지 못했어요'),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator(),
            ),
          );
        }
        final d = snap.data!;
        return Column(
          children: [
            Expanded(
              child: ListView(
                controller: widget.scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  const _Grabber(),
                  const SizedBox(height: 12),

                  // 1) 지금 갈 수 있나 — 사진보다 위에 둔다
                  _StatusBadge(
                    status: d.status,
                    needsVerify: widget.pin.needsVerify,
                    openReports: d.openReports,
                  ),
                  if (d.status == SpotStatus.noSkating)
                    const _Warning('이 앱은 이곳의 이용을 권장하지 않습니다.'),
                  if (d.isPrivateProperty)
                    const _Warning('사유지입니다. 관리자 허가가 필요합니다.'),

                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(d.name,
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text(d.type.label,
                                style: TextStyle(color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                      FutureBuilder<bool>(
                        future: _favoriteFuture,
                        builder: (context, favSnap) {
                          final fav = favSnap.data ?? false;
                          return IconButton(
                            onPressed: _favoriteBusy
                                ? null
                                : () => _toggleFavorite(fav),
                            icon: Icon(
                              fav ? Icons.favorite : Icons.favorite_border,
                              color: fav ? const Color(0xFFDC2626) : null,
                            ),
                            tooltip: '즐겨찾기',
                          );
                        },
                      ),
                      IconButton(
                        onPressed: () => _share(d.name),
                        icon: const Icon(Icons.share_outlined),
                        tooltip: '공유',
                      ),
                    ],
                  ),

                  // 2) 어떻게 생겼나
                  const SizedBox(height: 16),
                  FutureBuilder<List<String>>(
                    future: _photos,
                    builder: (context, photoSnap) => _PhotoCarousel(
                      urls: photoSnap.data ?? const [],
                      onAddPhoto: _addPhoto,
                    ),
                  ),

                  // 3) 내가 탈 수 있나
                  const SizedBox(height: 20),
                  if (d.obstacles.isNotEmpty) _Chips(labels: d.obstacles),
                  _Row(icon: Icons.trending_up, label: '난이도', value: d.difficulty),
                  _Row(icon: Icons.texture, label: '바닥', value: d.surface),

                  // 4) 쫓겨나나 — 이 앱의 핵심 필드
                  _Row(icon: Icons.report, label: '제지 위험', value: d.kickout),
                  _Row(icon: Icons.schedule, label: '추천 시간', value: d.bestTime),

                  // 5) 언제 갈까
                  _Row(
                    icon: Icons.lightbulb_outline,
                    label: '조명·야간',
                    value: _lighting(d),
                  ),
                  _Row(
                    icon: Icons.home_outlined,
                    label: '환경',
                    value: _environment(d),
                  ),

                  if (d.description != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F7F8),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(d.description!,
                          style: const TextStyle(fontSize: 14, height: 1.5)),
                    ),
                  ],

                  const SizedBox(height: 16),
                  Text(
                    '마지막 확인: ${_ago(d.lastVerifiedAt)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () =>
                            showReportSheet(context, widget.pin.id),
                        icon: const Icon(Icons.flag_outlined, size: 18),
                        label: const Text('정보 제보'),
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8)),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: () =>
                            showAbuseReportSheet(context, widget.pin.id),
                        icon: const Icon(Icons.outlined_flag, size: 18),
                        label: const Text('신고'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey.shade600,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _openDirections,
                    icon: const Icon(Icons.directions),
                    label: const Text('길찾기'),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String? _lighting(SpotDetail d) {
    final parts = <String>[
      if (d.hasLighting == true) '조명 있음' else if (d.hasLighting == false) '조명 없음',
      if (d.nightOk == true) '야간 가능' else if (d.nightOk == false) '야간 불가',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String? _environment(SpotDetail d) {
    final parts = <String>[
      if (d.isIndoor == true) '실내' else if (d.isIndoor == false) '실외',
      if (d.isFree == true) '무료' else if (d.isFree == false) '유료',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _ago(DateTime? t) {
    if (t == null) return '정보 없음';
    final days = DateTime.now().difference(t).inDays;
    if (days <= 0) return '오늘';
    if (days < 7) return '$days일 전';
    if (days < 60) return '${(days / 7).floor()}주 전';
    return '${(days / 30).floor()}개월 전';
  }
}

// ── 조각들 ────────────────────────────────────────────────────

class _Grabber extends StatelessWidget {
  const _Grabber();
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

/// 상태 배지. 정상이 기본이므로 active + 최근 확인이면 줄 자체를 그리지 않는다.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.status,
    required this.needsVerify,
    required this.openReports,
  });

  final SpotStatus status;
  final bool needsVerify;
  final int openReports;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      SpotStatus.active when openReports > 0 =>
        ('최근 제보가 있어요 ($openReports건)', const Color(0xFFCA8A04)),
      SpotStatus.active when needsVerify =>
        ('정보 확인 필요 · 오래 확인되지 않았어요', const Color(0xFF6B7280)),
      SpotStatus.active => (null, null),
      _ => (status.badge, status.color),
    };
    if (text == null || color == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFFDC2626),
                fontWeight: FontWeight.w600)),
      );
}

/// 사진 캐러셀. 없으면 빈 상태 + "사진 추가"만 보인다.
/// 있으면 스와이프 + 우하단에 추가 버튼을 겹쳐 둔다 (기존 스팟에 기여하는 경로).
class _PhotoCarousel extends StatefulWidget {
  const _PhotoCarousel({required this.urls, required this.onAddPhoto});
  final List<String> urls;
  final VoidCallback onAddPhoto;

  @override
  State<_PhotoCarousel> createState() => _PhotoCarouselState();
}

class _PhotoCarouselState extends State<_PhotoCarousel> {
  final _page = PageController();
  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) {
      return InkWell(
        onTap: widget.onAddPhoto,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 170,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F1F3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_a_photo_outlined, size: 28, color: Colors.grey.shade400),
                const SizedBox(height: 6),
                Text('아직 사진이 없어요 · 눌러서 추가',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 200,
            child: PageView.builder(
              controller: _page,
              itemCount: widget.urls.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => Image.network(
                widget.urls[i],
                fit: BoxFit.cover,
                width: double.infinity,
                errorBuilder: (context, error, stack) => Container(
                  color: const Color(0xFFF1F1F3),
                  child: Icon(Icons.broken_image_outlined, color: Colors.grey.shade400),
                ),
              ),
            ),
          ),
        ),
        if (widget.urls.length > 1)
          Positioned(
            bottom: 8, left: 0, right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.urls.length; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: i == _index ? 0.95 : 0.5),
                    ),
                  ),
              ],
            ),
          ),
        Positioned(
          right: 8, top: 8,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            child: IconButton(
              onPressed: widget.onAddPhoto,
              icon: const Icon(Icons.add_a_photo_outlined, size: 18, color: Colors.white),
              tooltip: '사진 추가',
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 제보 · 신고
//
// 제보는 "정보가 바뀌었다", 신고는 "이건 있으면 안 된다" — 별개 경로다.
// 둘 다 로그인 벽은 쓰기 행동 앞에 둔다. (docs/USER_FLOWS.md F5)
// ─────────────────────────────────────────────────────────────

class _ReportOption {
  const _ReportOption(this.kind, this.icon, this.label, this.instant);
  final String kind;
  final IconData icon;
  final String label;
  /// true면 후속 화면 없이 즉시 제출한다 ("아직 있어요"는 서버가 즉시 반영한다).
  final bool instant;
}

const _reportOptions = [
  _ReportOption('still_there', Icons.check_circle_outline, '아직 있어요', true),
  _ReportOption('cant_skate', Icons.construction_outlined, '지금은 못 타요', false),
  _ReportOption('gone', Icons.delete_outline, '없어졌어요 / 철거', false),
  _ReportOption('wrong_info', Icons.edit_outlined, '정보가 틀려요', false),
];

Future<void> showReportSheet(BuildContext context, int spotId) async {
  if (!await requireLogin(context, '제보하려면')) return;
  if (!context.mounted) return;

  final picked = await showModalBottomSheet<_ReportOption>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Grabber(),
            const SizedBox(height: 8),
            for (final o in _reportOptions)
              ListTile(
                leading: Icon(o.icon),
                title: Text(o.label),
                onTap: () => Navigator.of(ctx).pop(o),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;

  if (picked.instant) {
    await SpotRepo.submitReport(spotId: spotId, kind: picked.kind);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('감사합니다! 최신 정보로 반영했어요')),
      );
    }
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ReportDetailSheet(spotId: spotId, option: picked),
  );
}

class _ReportDetailSheet extends StatefulWidget {
  const _ReportDetailSheet({required this.spotId, required this.option});
  final int spotId;
  final _ReportOption option;

  @override
  State<_ReportDetailSheet> createState() => _ReportDetailSheetState();
}

class _ReportDetailSheetState extends State<_ReportDetailSheet> {
  final _memoCtrl = TextEditingController();
  Uint8List? _photo;
  bool _submitting = false;

  @override
  void dispose() {
    _memoCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final bytes = await pickAndPreparePhoto(context);
    if (bytes != null && mounted) setState(() => _photo = bytes);
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      String? photoPath;
      if (_photo != null) {
        // 철거 증빙 사진은 스팟 사진첩이 아니라 제보 첨부용이라 storage_path만
        // spot_reports에 남긴다. spot_photos에는 넣지 않는다.
        photoPath =
            'reports/${widget.spotId}/${DateTime.now().microsecondsSinceEpoch}.jpg';
        await SpotRepo.uploadReportPhoto(photoPath, _photo!);
      }
      await SpotRepo.submitReport(
        spotId: widget.spotId,
        kind: widget.option.kind,
        memo: _memoCtrl.text.trim().isEmpty ? null : _memoCtrl.text.trim(),
        photoPath: photoPath,
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('제보 감사합니다. 확인 후 반영됩니다')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('제보를 접수하지 못했어요')),
        );
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final showPhoto = widget.option.kind == 'gone'; // 철거 증빙은 사진이 도움된다
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 16,
        bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.option.label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: _memoCtrl,
              maxLength: 300,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '한 줄 메모 (선택)',
                border: OutlineInputBorder(),
              ),
            ),
            if (showPhoto) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pickPhoto,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: Text(_photo == null ? '사진 첨부 (권장)' : '사진 첨부됨 ✓'),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('제보하기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _abuseReasons = ['허위 스팟', '부적절한 사진', '스팸·광고', '권리 침해', '기타'];

Future<void> showAbuseReportSheet(BuildContext context, int spotId) async {
  if (!await requireLogin(context, '신고하려면')) return;
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _AbuseReportSheet(spotId: spotId),
  );
}

class _AbuseReportSheet extends StatefulWidget {
  const _AbuseReportSheet({required this.spotId});
  final int spotId;

  @override
  State<_AbuseReportSheet> createState() => _AbuseReportSheetState();
}

class _AbuseReportSheetState extends State<_AbuseReportSheet> {
  final _memoCtrl = TextEditingController();
  String _reason = _abuseReasons.first;
  bool _submitting = false;

  @override
  void dispose() {
    _memoCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final memo = _memoCtrl.text.trim();
    try {
      await SpotRepo.submitReport(
        spotId: widget.spotId,
        kind: 'inappropriate',
        memo: memo.isEmpty ? '[$_reason]' : '[$_reason] $memo',
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('신고가 접수됐어요')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('신고를 접수하지 못했어요')),
        );
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 16,
        bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('신고 사유', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                for (final r in _abuseReasons)
                  ChoiceChip(
                    label: Text(r),
                    selected: _reason == r,
                    onSelected: (_) => setState(() => _reason = r),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _memoCtrl,
              maxLength: 300,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '자세한 내용 (선택)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
                child: _submitting
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('신고하기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({required this.labels});
  final List<String> labels;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final l in labels)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF2F7),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(l, style: const TextStyle(fontSize: 12.5)),
              ),
          ],
        ),
      );
}

/// 값이 없으면 줄 자체를 그리지 않는다.
/// "정보 없음"을 나열하면 스팟이 부실해 보인다.
class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: Colors.grey.shade500),
          const SizedBox(width: 10),
          SizedBox(
            width: 72,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value!,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
