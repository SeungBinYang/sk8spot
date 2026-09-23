import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kakao_map_sdk/kakao_map_sdk.dart';

import 'auth.dart';
import 'photo.dart';
import 'spot.dart';
import 'spot_sheet.dart';

/// 등록 진입점. FAB에서 호출한다.
/// 로그인 벽은 지도 앞이 아니라 여기 — 쓰기 행동 앞에 둔다.
Future<void> startSpotRegistration(BuildContext context) async {
  if (!await requireLogin(context, '스팟을 등록하려면')) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const _LocationPickPage()),
  );
}

// ─────────────────────────────────────────────────────────────
// 1단계: 위치 지정 — 중앙 고정 핀 + 반경 내 기존 스팟 실시간 감지
// ─────────────────────────────────────────────────────────────

class _LocationPickPage extends StatefulWidget {
  const _LocationPickPage();

  @override
  State<_LocationPickPage> createState() => _LocationPickPageState();
}

class _LocationPickPageState extends State<_LocationPickPage> {
  static const _seoul = LatLng(37.5666, 126.979);

  KakaoMapController? _c;
  Timer? _debounce;
  bool _checking = false;
  List<NearSpot> _nearby = [];

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onCameraStopped() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _checkNearby);
  }

  /// ponytail: 이 시점엔 아직 스팟 타입을 모르니 서버 기본 반경(50m)으로
  /// 확인한다. 최종 등록 시 create_spot이 타입별 정확한 반경으로 다시
  /// 판정하므로, 여기서는 "미리 알려주는" 역할이면 충분하다.
  Future<void> _checkNearby() async {
    final c = _c;
    if (c == null) return;
    setState(() => _checking = true);
    try {
      final pos = await c.getCameraPosition();
      final near = await SpotRepo.near(
        lng: pos.position.longitude,
        lat: pos.position.latitude,
        type: SpotType.street,
      );
      if (mounted) setState(() => _nearby = near);
    } catch (_) {
      // 조용히 무시 — 다음 카메라 정지에서 다시 시도된다.
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _confirmLocation() async {
    final c = _c;
    if (c == null) return;
    final pos = await c.getCameraPosition();
    if (!mounted) return;
    final here = pos.position;

    if (_nearby.isNotEmpty) {
      final result = await showModalBottomSheet<_DupChoice>(
        context: context,
        backgroundColor: Colors.white,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => _DuplicateSheet(candidates: _nearby),
      );
      if (!mounted || result == null) return;

      if (result.spot != null) {
        // "네, 이 스팟이에요" — 등록이 아니라 기여로 전환.
        await _addPhotoToExisting(context, result.spot!);
        return;
      }
      // "아니요, 다른 곳이에요" — 계속 진행.
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SpotFormPage(lat: here.latitude, lng: here.longitude),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('위치 지정')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          KakaoMap(
            option: const KakaoMapOption(
              position: _seoul,
              zoomLevel: 16,
              mapType: MapType.normal,
            ),
            onMapReady: (c) {
              _c = c;
              _checkNearby();
            },
            onCameraMoveEnd: (_, _) => _onCameraStopped(),
          ),
          const IgnorePointer(
            child: Padding(
              padding: EdgeInsets.only(bottom: 22),
              child: Icon(Icons.place, size: 44, color: Color(0xFFDC2626)),
            ),
          ),
          if (_nearby.isNotEmpty)
            Positioned(
              top: 12, left: 12, right: 12,
              child: Material(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '근처에 등록된 스팟이 ${_nearby.length}개 있어요. '
                    '"여기로 지정"을 누르면 확인할 수 있어요.',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF92400E)),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 16, right: 16,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _checking ? null : _confirmLocation,
                child: const Text('여기로 지정'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DupChoice {
  const _DupChoice(this.spot); // null이면 "다른 곳이에요"
  final NearSpot? spot;
}

/// "혹시 이 스팟인가요?" — 중복 등록을 막는 게 아니라 기여로 돌린다.
class _DuplicateSheet extends StatelessWidget {
  const _DuplicateSheet({required this.candidates});
  final List<NearSpot> candidates;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('혹시 이 스팟인가요?',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('가까운 곳에 이미 등록된 스팟이 있어요',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: candidates.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final s = candidates[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: s.type.color.withValues(alpha: 0.15),
                      child: Icon(s.type.icon, color: s.type.color, size: 18),
                    ),
                    title: Text(s.name),
                    subtitle: Text('${s.type.label} · ${s.distanceM.round()}m'),
                    trailing: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: () =>
                          Navigator.of(context).pop(_DupChoice(s)),
                      child: const Text('네, 맞아요', style: TextStyle(fontSize: 12.5)),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(const _DupChoice(null)),
                child: const Text('아니요, 다른 곳이에요'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 중복 확인에서 "네"를 고르면 여기로 온다 — 새 스팟을 만들지 않고
/// 기존 스팟에 사진만 보탠다.
Future<void> _addPhotoToExisting(BuildContext context, NearSpot spot) async {
  final bytes = await pickAndPreparePhoto(context);
  if (bytes == null || !context.mounted) return;

  try {
    await SpotRepo.uploadPhoto(spotId: spot.id, bytes: bytes, isCover: false);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('사진을 올리지 못했어요')),
      );
    }
    return;
  }
  if (!context.mounted) return;

  // 등록 흐름(위치 지정 페이지)을 닫고 지도로 돌아간 뒤 상세를 보여준다.
  Navigator.of(context).popUntil((r) => r.isFirst);
  await showSpotDetail(
    context,
    SpotPin(
      id: spot.id, name: spot.name, lat: spot.lat, lng: spot.lng,
      type: spot.type, status: SpotStatus.active,
      needsVerify: false, openReports: 0,
    ),
  );
}

/// 스팟 상세의 "사진 추가"에서도 재사용한다 (docs/MVP_SCOPE.md — Should).
Future<Uint8List?> pickAndPreparePhoto(BuildContext context) async {
  final picked = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    imageQuality: 90,
  );
  if (picked == null) return null;
  final raw = await picked.readAsBytes();
  try {
    return preparePhoto(raw);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('사진을 처리하지 못했어요')),
      );
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// 2단계: 정보 입력 — 필수 5개 + 접힌 선택 필드
// ─────────────────────────────────────────────────────────────

class _SpotFormPage extends StatefulWidget {
  const _SpotFormPage({required this.lat, required this.lng});
  final double lat;
  final double lng;

  @override
  State<_SpotFormPage> createState() => _SpotFormPageState();
}

class _SpotFormPageState extends State<_SpotFormPage> {
  final _nameCtrl = TextEditingController();
  final _bestTimeCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  Uint8List? _photo;
  SpotType _type = SpotType.street;
  final Set<String> _obstacles = {};
  String _difficulty = 'beginner';

  // 선택 필드 — 접어둔다. 처음 보이는 폼의 길이가 등록률을 결정한다.
  bool _showMore = false;
  String? _surface;
  String? _quality;
  bool? _indoor;
  bool? _free;
  bool? _lighting;
  bool? _nightOk;
  String? _kickout;
  bool _privateProperty = false;

  bool _submitting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _bestTimeCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (picked == null) return;
    final raw = await picked.readAsBytes();
    try {
      final prepared = preparePhoto(raw);
      if (mounted) setState(() => _photo = prepared);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('사진을 처리하지 못했어요')),
        );
      }
    }
  }

  bool get _canSubmit =>
      !_submitting &&
      _photo != null &&
      _nameCtrl.text.trim().isNotEmpty &&
      _obstacles.isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);

    try {
      final id = await SpotRepo.create(NewSpotInput(
        name: _nameCtrl.text.trim(),
        lat: widget.lat,
        lng: widget.lng,
        type: _type,
        obstacles: _obstacles.toList(),
        difficulty: _difficulty,
        surface: _surface,
        surfaceQuality: _quality,
        isIndoor: _indoor,
        isFree: _free,
        hasLighting: _lighting,
        nightOk: _nightOk,
        kickoutRisk: _kickout,
        bestTime: _bestTimeCtrl.text.trim().isEmpty ? null : _bestTimeCtrl.text.trim(),
        description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        isPrivateProperty: _privateProperty,
      ));

      await SpotRepo.uploadPhoto(spotId: id, bytes: _photo!, isCover: true);

      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      await showSpotDetail(
        context,
        SpotPin(
          id: id, name: _nameCtrl.text.trim(),
          lat: widget.lat, lng: widget.lng,
          type: _type, status: SpotStatus.active,
          needsVerify: false, openReports: 0,
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      // create_spot이 rate limit(P0001)을 초과하면 메시지가 여기로 온다.
      final msg = e.toString().contains('한도')
          ? '오늘 등록 한도를 넘었어요. 내일 다시 시도해주세요'
          : '등록하지 못했어요. 잠시 후 다시 시도해주세요';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('스팟 등록')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _PhotoPicker(photo: _photo, onTap: _pickPhoto),
          const SizedBox(height: 16),

          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: '스팟 이름', hintText: '예: 여의나루역 앞'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),

          const _Label('스팟 종류'),
          Wrap(
            spacing: 8,
            children: [
              for (final t in SpotType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          const SizedBox(height: 16),

          const _Label('장애물 종류 (하나 이상)'),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              for (final o in obstacleOptions)
                FilterChip(
                  label: Text(o.value),
                  selected: _obstacles.contains(o.key),
                  onSelected: (v) => setState(
                      () => v ? _obstacles.add(o.key) : _obstacles.remove(o.key)),
                ),
            ],
          ),
          const SizedBox(height: 16),

          const _Label('난이도'),
          Wrap(
            spacing: 8,
            children: [
              for (final d in difficultyOptions)
                ChoiceChip(
                  label: Text(d.value),
                  selected: _difficulty == d.key,
                  onSelected: (_) => setState(() => _difficulty = d.key),
                ),
            ],
          ),

          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() => _showMore = !_showMore),
            icon: Icon(_showMore ? Icons.expand_less : Icons.expand_more),
            label: Text(_showMore ? '추가 정보 접기' : '추가 정보 입력 (선택)'),
          ),

          if (_showMore) ...[
            const _Label('바닥 재질'),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                for (final s in surfaceOptions)
                  ChoiceChip(
                    label: Text(s.value),
                    selected: _surface == s.key,
                    onSelected: (_) =>
                        setState(() => _surface = _surface == s.key ? null : s.key),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const _Label('바닥 상태'),
            Wrap(
              spacing: 8,
              children: [
                for (final q in qualityOptions)
                  ChoiceChip(
                    label: Text(q.value),
                    selected: _quality == q.key,
                    onSelected: (_) =>
                        setState(() => _quality = _quality == q.key ? null : q.key),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const _Label('제지 위험도'),
            Wrap(
              spacing: 8,
              children: [
                for (final k in kickoutOptions)
                  ChoiceChip(
                    label: Text(k.value),
                    selected: _kickout == k.key,
                    onSelected: (_) =>
                        setState(() => _kickout = _kickout == k.key ? null : k.key),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _YesNoRow(label: '실내인가요?', value: _indoor,
                onChanged: (v) => setState(() => _indoor = v)),
            _YesNoRow(label: '무료인가요?', value: _free,
                onChanged: (v) => setState(() => _free = v)),
            _YesNoRow(label: '조명이 있나요?', value: _lighting,
                onChanged: (v) => setState(() => _lighting = v)),
            _YesNoRow(label: '야간에 이용 가능한가요?', value: _nightOk,
                onChanged: (v) => setState(() => _nightOk = v)),
            _YesNoRow(label: '사유지인가요?', value: _privateProperty,
                onChanged: (v) => setState(() => _privateProperty = v ?? false)),
            const SizedBox(height: 12),
            TextField(
              controller: _bestTimeCtrl,
              decoration: const InputDecoration(labelText: '이용하기 좋은 시간', hintText: '예: 평일 저녁'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              maxLength: 1000,
              maxLines: 4,
              decoration: const InputDecoration(labelText: '설명', alignLabelWithHint: true),
            ),
          ],

          const SizedBox(height: 20),
          FilledButton(
            onPressed: _canSubmit ? _submit : null,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _submitting
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('등록하기'),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      );
}

class _YesNoRow extends StatelessWidget {
  const _YesNoRow({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
            Switch(value: value ?? false, onChanged: onChanged),
          ],
        ),
      );
}

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({required this.photo, required this.onTap});
  final Uint8List? photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 180,
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F1F3),
            borderRadius: BorderRadius.circular(12),
            image: photo == null
                ? null
                : DecorationImage(image: MemoryImage(photo!), fit: BoxFit.cover),
          ),
          child: photo != null
              ? null
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, size: 28, color: Colors.grey.shade500),
                    const SizedBox(height: 6),
                    Text('사진 추가 (필수)',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                  ],
                ),
        ),
      );
}
