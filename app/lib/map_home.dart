import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:kakao_map_sdk/kakao_map_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth.dart';
import 'cluster.dart';
import 'place_search.dart';
import 'spot.dart';
import 'spot_register.dart';
import 'spot_sheet.dart';

/// 지도 홈 — 앱의 루트. 하단 탭은 두지 않는다.
/// 지도가 전체 화면이고 나머지는 시트로 덮는다 (docs/SCREEN_STRUCTURE.md).
class MapHome extends StatefulWidget {
  const MapHome({super.key});

  @override
  State<MapHome> createState() => _MapHomeState();
}

class _MapHomeState extends State<MapHome> {
  // 스팟 밀집 기본 좌표. 앱 시작 시 위치 권한을 요청하지 않으므로
  // 여기서 지도를 먼저 띄운다 (docs/USER_FLOWS.md F1).
  static const _fallback = LatLng(37.5563, 126.9236); // 홍대
  static const _initialZoom = 13;
  static const _lastLatKey = 'last_map_lat';
  static const _lastLngKey = 'last_map_lng';
  static const _lastZoomKey = 'last_map_zoom';

  final _mapKey = GlobalKey();
  KakaoMapController? _c;

  final Map<String, Poi> _rendered = {};
  bool _renderInFlight = false;
  bool _renderPending = false;
  final Map<SpotType, PoiStyle> _typeStyles = {};
  PoiStyle? _clusterStyle;

  List<SpotPin> _spots = [];
  String? _filterType;
  List<SpotPin> get _visibleSpots => _filterType == null
      ? _spots
      : _spots.where((spot) => spot.type.name == _filterType).toList();

  Timer? _debounce;
  _Bbox? _lastQueried;
  bool _loading = false;

  /// 동시 조회 방지. `_loading`은 setState 뒤에 켜져서 레이스를 막지 못한다.
  bool _inFlight = false;
  bool _fetchPending = false;
  String? _error;
  bool _locating = false;
  bool _restoringCamera = true;

  /// 어느 수단으로 bbox를 얻었는지. 기기마다 다를 수 있어 로그로 남긴다.
  String _bboxSource = '-';

  /// 한 번이라도 조회에 성공했는가. false면 "스팟이 없다"고 단정할 수 없다.
  bool _everFetched = false;

  StreamSubscription<void>? _authSub;

  @override
  void initState() {
    super.initState();
    // 카카오 로그인은 브라우저 리다이렉트/딥링크를 왕복한 뒤 비동기로
    // 완료된다. 그 시점에 프로필 아이콘을 갱신하려면 구독이 필요하다.
    _authSub = Auth.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  // ── 지도 준비 ────────────────────────────────────────────────

  Future<void> _onMapReady(KakaoMapController c) async {
    _c = c;

    // 아이콘은 한 번만 굽고 재사용한다. 마커마다 구우면 수백 번
    // 래스터라이즈가 일어나 그대로 멈춘다.
    for (final t in SpotType.values) {
      if (!mounted) return;
      final img = await KImage.fromWidget(
        _MarkerIcon(type: t),
        const Size(_markerW, _markerH),
        context: context,
      );
      _typeStyles[t] = PoiStyle(icon: img, applyDpScale: false);
    }
    if (!mounted) return;
    final bubble = await KImage.fromWidget(
      const _ClusterBubble(),
      const Size(_bubbleSize, _bubbleSize),
      context: context,
    );
    _clusterStyle = PoiStyle(
      icon: bubble,
      applyDpScale: false,
      anchor: const KPoint(0.5, 0.5),
      textStyle: const [
        PoiTextStyle(
          size: 20,
          color: Colors.white,
          stroke: 1,
          strokeColor: Colors.black38,
        ),
      ],
    );

    await _restoreCamera();
    _restoringCamera = false;
    await _fetch();
  }

  Future<void> _restoreCamera() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble(_lastLatKey);
      final lng = prefs.getDouble(_lastLngKey);
      final zoom = prefs.getInt(_lastZoomKey);
      if (lat == null ||
          lng == null ||
          zoom == null ||
          !lat.isFinite ||
          !lng.isFinite ||
          lat.abs() > 90 ||
          lng.abs() > 180 ||
          zoom < 1 ||
          zoom > 21) {
        return;
      }
      await _c?.moveCamera(
        CameraUpdate.newCenterPosition(LatLng(lat, lng), zoomLevel: zoom),
      );
    } catch (_) {
      // 저장 정보가 없어도 기본 좌표에서 바로 사용할 수 있다.
    }
  }

  Future<void> _rememberCamera() async {
    final c = _c;
    if (c == null || _restoringCamera) return;
    try {
      final pos = await c.getCameraPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_lastLatKey, pos.position.latitude);
      await prefs.setDouble(_lastLngKey, pos.position.longitude);
      await prefs.setInt(_lastZoomKey, pos.zoomLevel);
    } catch (_) {
      // 지도 사용은 저장소 상태와 무관하게 계속된다.
    }
  }

  // ── bbox 계산 ───────────────────────────────────────────────
  //
  // Phase 1 스파이크에서 getBounds()가 카메라 중심을 포함하지 않는 bbox를
  // 돌려줬다 (약 6km 어긋남). 그래서 화면 네 모서리를 fromScreenPoint로
  // 직접 역변환하는 방식을 1순위로 쓴다. getBounds는 대조용으로만 읽는다.

  /// 셋 다 실패할 수는 없게 단계적으로 내려간다.
  /// 단일 경로로 뒀더니 웹에서 fromScreenPoint가 null을 반환해 조회가
  /// 한 번도 나가지 않았고, 화면엔 "스팟이 없어요"라는 틀린 메시지가 떴다.
  Future<_Bbox?> _viewportBbox() async {
    final c = _c;
    if (c == null) return null;

    // 1순위: 화면 모서리 역변환. Phase 1에서 getBounds가 어긋났기 때문.
    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      try {
        final corners = await Future.wait([
          c.fromScreenPoint(0, 0),
          c.fromScreenPoint(box.size.width.round(), box.size.height.round()),
        ]);
        final a = corners[0], b = corners[1];
        if (a != null && b != null && (a.latitude != b.latitude)) {
          _bboxSource = 'fromScreenPoint';
          return _Bbox.of(a.latitude, a.longitude, b.latitude, b.longitude);
        }
      } catch (_) {
        /* 다음 수단으로 */
      }
    }

    // 2순위: 플러그인이 주는 bounds.
    try {
      if (!mounted) return null;
      final b = await c.getBounds(context);
      if (b != null) {
        _bboxSource = 'getBounds';
        return _Bbox.of(
          b.sw.latitude,
          b.sw.longitude,
          b.ne.latitude,
          b.ne.longitude,
        );
      }
    } catch (_) {
      /* 다음 수단으로 */
    }

    // 3순위: 카메라 위치 + 줌으로 직접 계산. 정확하진 않지만 빈 지도보다 낫다.
    try {
      final pos = await c.getCameraPosition();
      final size = box?.size ?? const Size(400, 800);
      // 웹 머케이터: 월드 폭 = 256 * 2^zoom px
      final degPerPx = 360.0 / (256 * math.pow(2, pos.zoomLevel));
      final halfLng = size.width / 2 * degPerPx;
      final halfLat =
          size.height /
          2 *
          degPerPx *
          math.cos(pos.position.latitude * math.pi / 180);
      _bboxSource = 'cameraEstimate';
      return _Bbox.of(
        pos.position.latitude - halfLat,
        pos.position.longitude - halfLng,
        pos.position.latitude + halfLat,
        pos.position.longitude + halfLng,
      );
    } catch (_) {
      return null;
    }
  }

  // ── 조회 ────────────────────────────────────────────────────

  void _onCameraStopped() {
    unawaited(_rememberCamera());
    // 지도를 빠르게 움직이면 요청이 폭주한다. 멈춘 뒤 400ms 기다린다.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _fetch);
  }

  Future<void> _fetch() async {
    final c = _c;
    // 가드를 첫 await 앞에서 동기적으로 건다.
    // await 뒤에 두면 onMapReady와 onCameraMoveEnd가 겹칠 때 여러 호출이
    // 전부 통과해 같은 쿼리가 3번씩 나간다.
    if (c == null) return;
    if (_inFlight) {
      _fetchPending = true;
      return;
    }
    _inFlight = true;
    try {
      do {
        _fetchPending = false;
        await _fetchInner();
      } while (_fetchPending && mounted);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _fetchInner() async {
    final bbox = await _viewportBbox();
    if (!mounted) return;
    if (bbox == null) {
      // 조용히 빠져나가면 빈 지도가 영원히 남는다. 원인을 드러낸다.
      setState(() => _error = '지도 영역을 계산하지 못했어요');
      return;
    }

    // 조금 움직인 정도로는 다시 부르지 않는다.
    if (_lastQueried != null && _lastQueried!.covers(bbox)) {
      await _render(); // 줌이 바뀌면 캐시 영역 안에서도 클러스터를 다시 계산한다.
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 화면보다 20% 넓게 요청해 소폭 이동 시 재요청을 줄인다.
      final padded = bbox.inflated(0.2);
      final spots = await SpotRepo.inBbox(
        minLng: padded.minLng,
        minLat: padded.minLat,
        maxLng: padded.maxLng,
        maxLat: padded.maxLat,
      );
      if (!mounted) return;
      _lastQueried = padded;
      _spots = spots;
      _everFetched = true;
      debugPrint(
        '[sk8spot] bbox=$_bboxSource spots=${spots.length} '
        '(${padded.minLat.toStringAsFixed(4)},${padded.minLng.toStringAsFixed(4)})'
        '~(${padded.maxLat.toStringAsFixed(4)},${padded.maxLng.toStringAsFixed(4)})',
      );
      await _render();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      // 실패해도 기존 마커를 지우지 않는다. 지우면 지도가 비어 보인다.
      setState(() {
        _loading = false;
        _error = '스팟을 불러오지 못했어요';
      });
    }
  }

  // ── 마커 렌더 ────────────────────────────────────────────────

  Future<void> _render() async {
    if (_renderInFlight) {
      _renderPending = true;
      return;
    }
    _renderInFlight = true;
    try {
      do {
        _renderPending = false;
        await _renderInner();
      } while (_renderPending && mounted);
    } finally {
      _renderInFlight = false;
    }
  }

  Future<void> _renderInner() async {
    final c = _c;
    if (c == null || _clusterStyle == null) return;

    final pos = await c.getCameraPosition();
    if (!mounted) return;
    final clusters = clusterize(_visibleSpots, pos.zoomLevel.toDouble());
    // 셀 주소만 같아도 구성원이나 개수가 바뀔 수 있다. 내용까지 key에 넣어
    // 숫자와 탭 대상을 오래된 클러스터에서 가져오지 않게 한다.
    String renderKey(Cluster cl) {
      final ids = cl.members.map((s) => s.id).toList()..sort();
      return '${cl.key}|${ids.join(',')}';
    }

    final want = {for (final cl in clusters) renderKey(cl): cl};
    final layer = c.labelLayer;

    // 전체를 지우고 다시 그리면 지도가 깜빡인다. key 기준으로 diff 한다.
    for (final key in _rendered.keys.toList()) {
      if (!want.containsKey(key)) {
        final poi = _rendered.remove(key);
        if (poi != null) await layer.removePoi(poi);
      }
    }
    for (final cl in clusters) {
      final key = renderKey(cl);
      if (_rendered.containsKey(key)) continue;
      final style = cl.isSingle ? _typeStyles[cl.single.type]! : _clusterStyle!;
      _rendered[key] = await layer.addPoi(
        LatLng(cl.lat, cl.lng),
        style: style,
        text: cl.isSingle ? null : '${cl.count}',
        onClick: () => _onClusterTap(cl),
      );
    }
  }

  Future<void> _onClusterTap(Cluster cl) async {
    final c = _c;
    if (c == null) return;

    if (cl.isSingle) {
      // 상세로 바로 넘기지 않고 미리보기 시트를 거친다.
      // 탐색 중인 사용자는 여러 스팟을 빠르게 훑는다.
      await showSpotPreview(context, cl.single);
      return;
    }
    final pos = await c.getCameraPosition();
    await c.moveCamera(
      CameraUpdate.newCenterPosition(
        LatLng(cl.lat, cl.lng),
        zoomLevel: pos.zoomLevel + 2,
      ),
      animation: const CameraAnimation(300),
    );
    _onCameraStopped();
  }

  // ── 내 위치 ─────────────────────────────────────────────────
  //
  // 앱 실행 시에는 권한을 요청하지 않는다. 이 버튼을 누를 때만 요청한다.
  // 맥락 없이 뜨는 권한 팝업은 거부당한다.

  Future<void> _goToMyLocation() async {
    final c = _c;
    if (c == null || _locating) return;
    setState(() => _locating = true);

    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _toast('위치 권한이 없어요. 지도를 움직여 스팟을 찾아보세요');
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _toast('기기의 위치 서비스가 꺼져 있어요');
        return;
      }

      // 지도 이동용이라 최고 정확도는 필요 없다. 백그라운드 위치도 쓰지 않는다.
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      await c.moveCamera(
        CameraUpdate.newCenterPosition(
          LatLng(p.latitude, p.longitude),
          zoomLevel: 15,
        ),
        animation: const CameraAnimation(400),
      );
      _onCameraStopped();
    } catch (_) {
      _toast('현재 위치를 가져오지 못했어요');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _setFilter(String? type) async {
    if (_filterType == type) return;
    setState(() => _filterType = type);
    await _render();
  }

  Future<void> _openPlaceSearch() async {
    final place = await showPlaceSearch(context);
    final c = _c;
    if (place == null || c == null || !mounted) return;
    await c.moveCamera(
      CameraUpdate.newCenterPosition(
        LatLng(place.lat, place.lng),
        zoomLevel: 15,
      ),
      animation: const CameraAnimation(400),
    );
    _onCameraStopped();
  }

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;

    return Scaffold(
      body: Stack(
        children: [
          KakaoMap(
            key: _mapKey,
            option: const KakaoMapOption(
              position: _fallback,
              zoomLevel: _initialZoom,
              mapType: MapType.normal,
            ),
            onMapReady: _onMapReady,
            onCameraMoveEnd: (_, _) => _onCameraStopped(),
            onMapError: (e) => debugPrint('### 카카오 지도 오류: $e'),
          ),

          if (_loading)
            Positioned(
              top: topPad,
              left: 0,
              right: 0,
              child: const LinearProgressIndicator(minHeight: 2),
            ),

          Positioned(
            top: topPad + 10,
            left: 12,
            right: 12,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _FilterChips(
                      selected: _filterType,
                      onChanged: _setFilter,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _MapIconButton(icon: Icons.search, onTap: _openPlaceSearch),
                const SizedBox(width: 8),
                // 하단 탭을 두지 않으므로 내 정보는 여기로 들어간다.
                _MapIconButton(
                  icon: Auth.isLoggedIn ? Icons.person : Icons.person_outline,
                  onTap: () => showMySheet(context),
                ),
              ],
            ),
          ),

          if (_error != null)
            Positioned(
              top: topPad + 58,
              left: 12,
              right: 12,
              child: _Banner(
                text: _error!,
                actionLabel: '다시 시도',
                onAction: () {
                  _lastQueried = null;
                  _fetch();
                },
              ),
            )
          // 조회에 성공한 적이 있을 때만 "없다"고 말한다.
          else if (!_loading && _everFetched && _visibleSpots.isEmpty)
            Positioned(
              top: topPad + 58,
              left: 12,
              right: 12,
              child: const _Banner(text: '이 주변엔 아직 스팟이 없어요'),
            ),

          Positioned(
            right: 16,
            bottom: 92 + MediaQuery.paddingOf(context).bottom,
            child: FloatingActionButton(
              heroTag: 'loc',
              onPressed: _locating ? null : _goToMyLocation,
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              child: _locating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
            ),
          ),

          // 스팟 등록 — 로그인 벽은 지도 앞이 아니라 여기, 쓰기 행동 앞에 둔다.
          Positioned(
            right: 16,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
            child: FloatingActionButton(
              heroTag: 'add',
              onPressed: () async {
                // 등록 흐름이 끝나고 지도로 돌아오면 바로 새 스팟이 보이게
                // 강제로 다시 조회한다. 안 하면 지도를 한 번 더 움직여야 보인다.
                await startSpotRegistration(context);
                _lastQueried = null;
                _fetch();
              },
              child: const Icon(Icons.add),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 값 객체 ───────────────────────────────────────────────────

class _Bbox {
  const _Bbox({
    required this.minLng,
    required this.minLat,
    required this.maxLng,
    required this.maxLat,
  });

  final double minLng, minLat, maxLng, maxLat;

  /// 두 모서리 순서에 상관없이 만든다.
  factory _Bbox.of(double lat1, double lng1, double lat2, double lng2) => _Bbox(
    minLng: math.min(lng1, lng2),
    minLat: math.min(lat1, lat2),
    maxLng: math.max(lng1, lng2),
    maxLat: math.max(lat1, lat2),
  );

  _Bbox inflated(double ratio) {
    final dx = (maxLng - minLng) * ratio / 2;
    final dy = (maxLat - minLat) * ratio / 2;
    return _Bbox(
      minLng: minLng - dx,
      minLat: minLat - dy,
      maxLng: maxLng + dx,
      maxLat: maxLat + dy,
    );
  }

  /// 새 화면이 이미 받아둔 영역 안에 완전히 들어가면 재요청하지 않는다.
  bool covers(_Bbox o) =>
      minLng <= o.minLng &&
      minLat <= o.minLat &&
      maxLng >= o.maxLng &&
      maxLat >= o.maxLat;
}

// ── 위젯 ──────────────────────────────────────────────────────

const _markerW = 28.0;
const _markerH = 34.0;
const _bubbleSize = 38.0;

class _MarkerIcon extends StatelessWidget {
  const _MarkerIcon({required this.type});
  final SpotType type;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Container(
      width: _markerW,
      height: _markerH,
      decoration: BoxDecoration(
        color: type.color,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(14),
          topRight: Radius.circular(14),
          bottomLeft: Radius.circular(14),
          bottomRight: Radius.circular(2),
        ),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Icon(type.icon, size: 15, color: Colors.white),
    ),
  );
}

class _ClusterBubble extends StatelessWidget {
  const _ClusterBubble();

  @override
  Widget build(BuildContext context) => Container(
    width: _bubbleSize,
    height: _bubbleSize,
    decoration: BoxDecoration(
      color: const Color(0xFF1F2937),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2.5),
    ),
  );
}

/// MVP 필터는 칩 3개가 전부다. 스팟이 200개일 때 난이도 필터를 걸면
/// 결과가 3개 남는다 — 필터는 데이터가 많을 때만 유용하다.
/// 지도 위 필터/검색/프로필의 공통 톤. 브랜드(진입 화면·앱 아이콘)와 맞춘
/// 어두운 바탕 + 네온 그린 강조 — 기본 Material 흰 배경은 알록달록한
/// 지도 위에서 존재감이 없었다.
const _kMapChromeDark = Color(0xFF14161B);
const _kMapChromeAccent = Color(0xFFD7E94A);

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onChanged});
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    const options = [(null, '전체'), ('skatepark', '파크'), ('street', '스트리트')];
    return Row(
      children: [
        for (final (value, label) in options)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label),
              selected: selected == value,
              onSelected: (_) => onChanged(value),
              backgroundColor: _kMapChromeDark,
              selectedColor: _kMapChromeAccent,
              showCheckmark: false,
              side: BorderSide.none,
              labelStyle: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected == value ? _kMapChromeDark : Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

class _MapIconButton extends StatelessWidget {
  const _MapIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: _kMapChromeDark,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.actionLabel, this.onAction});
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 2,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    ),
  );
}
