import 'dart:math' as math;

import 'spot.dart';

/// 클러스터링 — 카카오 SDK에 내장 기능이 없어 직접 구현한다.
/// Phase 1 스파이크에서 실기기 검증됨 (마커 1000개, 갱신 최대 190ms).
///
/// 지리 좌표를 줌 레벨에 맞춘 격자로 버킷팅한다. 화면 좌표로 묶으면
/// 마커마다 async 투영 호출이 필요해 수백 개 단위에서 못 쓴다.
class Cluster {
  Cluster({
    required this.key,
    required this.lat,
    required this.lng,
    required this.members,
  });

  final String key;
  final double lat;
  final double lng;
  final List<SpotPin> members;

  int get count => members.length;
  bool get isSingle => count == 1;
  SpotPin get single => members.first;
}

/// 목표 셀 크기 ≈ 화면상 60px.
/// 웹 머케이터에서 월드 폭이 256 * 2^zoom px 이므로 1px ≈ 360/(256*2^zoom) 도.
///
/// ponytail: 위/경도에 같은 격자폭을 쓴다 → 고위도에서 셀이 가로로 찌그러진다.
///           수도권(위도 37도) 한정 MVP에는 무해. 전국 확장 시 cos(lat) 보정.
///
/// 스파이크에서는 112.5(≈80px)를 썼는데 실기기에서 셀당 20~45개로 과밀했다.
/// 실제 스팟 밀도로 재확인이 필요하다 → spike/README.md
double cellSizeDeg(double zoom) => 84.0 / math.pow(2, zoom);

List<Cluster> clusterize(List<SpotPin> spots, double zoom) {
  final cell = cellSizeDeg(zoom);
  final buckets = <String, List<SpotPin>>{};

  for (final s in spots) {
    final gx = (s.lng / cell).floor();
    final gy = (s.lat / cell).floor();
    (buckets['$gx:$gy'] ??= []).add(s);
  }

  return [
    for (final e in buckets.entries)
      Cluster(
        key: e.key,
        // 셀 중심이 아니라 실제 스팟들의 무게중심에 찍는다.
        lat: e.value.map((s) => s.lat).reduce((a, b) => a + b) / e.value.length,
        lng: e.value.map((s) => s.lng).reduce((a, b) => a + b) / e.value.length,
        members: e.value,
      ),
  ];
}
