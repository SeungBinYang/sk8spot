import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'env.dart';

// ─────────────────────────────────────────────────────────────
// enum — supabase/migrations/0001_schema.sql 과 값이 1:1로 맞아야 한다.
// DB에 없는 값이 오면 조용히 틀리지 않고 unknown으로 떨어진다.
// ─────────────────────────────────────────────────────────────

enum SpotType {
  skatepark('파크', Color(0xFF2563EB), Icons.skateboarding),
  street('스트리트', Color(0xFFDC2626), Icons.stairs),
  plazaPark('광장·공원', Color(0xFF16A34A), Icons.park),
  diy('DIY', Color(0xFFCA8A04), Icons.construction);

  const SpotType(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;

  static SpotType parse(String? raw) => switch (raw) {
        'skatepark' => SpotType.skatepark,
        'plaza_park' => SpotType.plazaPark,
        'diy' => SpotType.diy,
        _ => SpotType.street,
      };
}

enum SpotStatus {
  active(null, null),
  caution('제지 위험 / 이용 어려움 제보 다수', Color(0xFFCA8A04)),
  temporarilyClosed('공사 등으로 일시 이용 불가', Color(0xFFEA580C)),
  noSkating('스케이트 금지 구역으로 제보됨', Color(0xFFDC2626)),
  removed('철거됨', Color(0xFF6B7280)),
  hidden(null, null);

  const SpotStatus(this.badge, this.color);
  final String? badge;
  final Color? color;

  static SpotStatus parse(String? raw) => switch (raw) {
        'caution' => SpotStatus.caution,
        'temporarily_closed' => SpotStatus.temporarilyClosed,
        'no_skating' => SpotStatus.noSkating,
        'removed' => SpotStatus.removed,
        'hidden' => SpotStatus.hidden,
        _ => SpotStatus.active,
      };
}

const _obstacleLabels = {
  'stair': '계단', 'handrail': '핸드레일', 'flat_rail': '플랫레일',
  'ledge': '렛지', 'curb': '커브', 'bank': '뱅크',
  'manual_pad': '매뉴얼 패드', 'gap': '갭', 'quarter': '쿼터파이프',
  'hubba': '허바', 'flat': '플랫',
};

const _surfaceLabels = {
  'smooth_concrete': '매끈한 콘크리트', 'rough_concrete': '거친 콘크리트',
  'marble_tile': '대리석·타일', 'asphalt': '아스팔트', 'brick_tile': '보도블럭',
  'urethane': '우레탄', 'wood': '목재', 'metal': '철판', 'other': '기타',
};

const _qualityLabels = {'good': '좋음', 'fair': '보통', 'poor': '나쁨'};

const _difficultyLabels = {
  'beginner': '초급', 'intermediate': '중급', 'advanced': '상급',
};

/// 이 앱의 핵심 차별 필드. 일반 장소 앱에는 없다.
const _kickoutLabels = {
  'low': '거의 없음', 'medium': '보통', 'high': '높음',
  'banned': '명시적 금지', 'unknown': '정보 없음',
};

String? obstacleLabel(String k) => _obstacleLabels[k];
String? surfaceLabel(String? k) => k == null ? null : _surfaceLabels[k];
String? qualityLabel(String? k) => k == null ? null : _qualityLabels[k];
String? difficultyLabel(String? k) => k == null ? null : _difficultyLabels[k];
String? kickoutLabel(String? k) =>
    (k == null || k == 'unknown') ? null : _kickoutLabels[k];

// 등록 폼의 선택지 UI가 값↔라벨을 나열할 때 쓴다.
List<MapEntry<String, String>> get obstacleOptions => _obstacleLabels.entries.toList();
List<MapEntry<String, String>> get surfaceOptions => _surfaceLabels.entries.toList();
List<MapEntry<String, String>> get qualityOptions => _qualityLabels.entries.toList();
List<MapEntry<String, String>> get difficultyOptions => _difficultyLabels.entries.toList();
List<MapEntry<String, String>> get kickoutOptions => _kickoutLabels.entries
    .where((e) => e.key != 'unknown')
    .toList();

// ─────────────────────────────────────────────────────────────
// 지도 마커용 — spots_in_bbox RPC가 돌려주는 최소 필드
// ─────────────────────────────────────────────────────────────

class SpotPin {
  SpotPin({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.type,
    required this.status,
    required this.needsVerify,
    required this.openReports,
    this.coverPath,
  });

  final int id;
  final String name;
  final double lat;
  final double lng;
  final SpotType type;
  final SpotStatus status;

  /// 마지막 확인 후 180일 초과. 상태가 아니라 파생 배지다.
  final bool needsVerify;
  final int openReports;
  final String? coverPath;

  factory SpotPin.fromRow(Map<String, dynamic> r) => SpotPin(
        id: (r['id'] as num).toInt(),
        name: r['name'] as String,
        lat: (r['lat'] as num).toDouble(),
        lng: (r['lng'] as num).toDouble(),
        type: SpotType.parse(r['spot_type'] as String?),
        status: SpotStatus.parse(r['status'] as String?),
        needsVerify: r['needs_verify'] as bool? ?? false,
        openReports: (r['open_reports'] as num?)?.toInt() ?? 0,
        coverPath: r['cover_path'] as String?,
      );
}

/// 상세 화면용 전체 정보.
class SpotDetail {
  SpotDetail(this.row);
  final Map<String, dynamic> row;

  String get name => row['name'] as String;
  SpotType get type => SpotType.parse(row['spot_type'] as String?);
  SpotStatus get status => SpotStatus.parse(row['status'] as String?);
  String? get description => _trim(row['description'] as String?);
  String? get bestTime => _trim(row['best_time'] as String?);
  bool get isPrivateProperty => row['is_private_property'] as bool? ?? false;
  int get openReports => (row['open_report_count'] as num?)?.toInt() ?? 0;

  List<String> get obstacles => (row['obstacles'] as List?)
          ?.map((e) => obstacleLabel(e as String) ?? e.toString())
          .toList() ??
      const [];

  String? get difficulty => difficultyLabel(row['difficulty'] as String?);
  String? get kickout => kickoutLabel(row['kickout_risk'] as String?);

  String? get surface {
    final s = surfaceLabel(row['surface'] as String?);
    if (s == null) return null;
    final q = qualityLabel(row['surface_quality'] as String?);
    return q == null ? s : '$s ($q)';
  }

  bool? get isIndoor => row['is_indoor'] as bool?;
  bool? get isFree => row['is_free'] as bool?;
  bool? get hasLighting => row['has_lighting'] as bool?;
  bool? get nightOk => row['night_ok'] as bool?;

  DateTime? get lastVerifiedAt =>
      DateTime.tryParse(row['last_verified_at'] as String? ?? '');

  static String? _trim(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();
}

/// 중복 탐지 후보. spots_near RPC가 돌려주는 최소 필드.
class NearSpot {
  NearSpot({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.type,
    required this.distanceM,
    this.coverPath,
  });

  final int id;
  final String name;
  final double lat;
  final double lng;
  final SpotType type;
  final double distanceM;
  final String? coverPath;

  factory NearSpot.fromRow(Map<String, dynamic> r) => NearSpot(
        id: (r['id'] as num).toInt(),
        name: r['name'] as String,
        lat: (r['lat_out'] as num).toDouble(),
        lng: (r['lng_out'] as num).toDouble(),
        type: SpotType.parse(r['spot_type'] as String?),
        distanceM: (r['distance_m'] as num).toDouble(),
        coverPath: r['cover_path'] as String?,
      );
}

/// 지명 검색 결과 — 카카오 로컬 키워드 검색 API. 스팟 검색이 아니라 지도 이동용이다.
class PlaceResult {
  PlaceResult({
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
  });

  final String name;
  final String address;
  final double lat;
  final double lng;

  factory PlaceResult.fromRow(Map r) {
    final road = r['road_address_name'] as String?;
    return PlaceResult(
      name: r['place_name'] as String,
      address: (road != null && road.isNotEmpty) ? road : r['address_name'] as String,
      lat: double.parse(r['y'] as String),
      lng: double.parse(r['x'] as String),
    );
  }
}

/// 등록 폼 입력값. 필수 5개 + 접힌 선택 필드 (docs/USER_FLOWS.md F4).
class NewSpotInput {
  NewSpotInput({
    required this.name,
    required this.lat,
    required this.lng,
    required this.type,
    required this.obstacles,
    required this.difficulty,
    this.surface,
    this.surfaceQuality,
    this.isIndoor,
    this.isFree,
    this.hasLighting,
    this.nightOk,
    this.kickoutRisk,
    this.bestTime,
    this.description,
    this.isPrivateProperty = false,
  });

  final String name;
  final double lat;
  final double lng;
  final SpotType type;
  final List<String> obstacles; // DB enum 원시값 ('stair' 등)
  final String difficulty; // 'beginner' | 'intermediate' | 'advanced'
  final String? surface;
  final String? surfaceQuality;
  final bool? isIndoor;
  final bool? isFree;
  final bool? hasLighting;
  final bool? nightOk;
  final String? kickoutRisk;
  final String? bestTime;
  final String? description;
  final bool isPrivateProperty;
}

// ─────────────────────────────────────────────────────────────
// 데이터 접근. 레이어를 더 쌓지 않는다 — 쿼리 몇 개짜리 레포지토리다.
// ─────────────────────────────────────────────────────────────

class SpotRepo {
  static final _db = Supabase.instance.client;

  /// 지도에 보이는 영역의 스팟. bbox를 쓴다 — 반경 검색은 원형이라
  /// 화면(사각형) 모서리의 스팟이 누락된다.
  static Future<List<SpotPin>> inBbox({
    required double minLng,
    required double minLat,
    required double maxLng,
    required double maxLat,
    String? filterType,
  }) async {
    final rows = await _db.rpc('spots_in_bbox', params: {
      'min_lng': minLng,
      'min_lat': minLat,
      'max_lng': maxLng,
      'max_lat': maxLat,
      'filter_type': filterType,
      'max_rows': 200,
    }) as List;
    return rows
        .map((r) => SpotPin.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  /// 상세. geom은 일부러 빼고 읽는다 — PostGIS geography가 PostgREST에서
  /// EWKB hex로 나와 파싱이 번거롭고, 좌표는 이미 마커에서 알고 있다.
  static Future<SpotDetail> detail(int id) async {
    final row = await _db
        .from('spots')
        .select(
          'id,name,spot_type,obstacles,difficulty,surface,surface_quality,'
          'is_indoor,is_free,has_lighting,night_ok,kickout_risk,best_time,'
          'description,status,is_private_property,last_verified_at,open_report_count',
        )
        .eq('id', id)
        .single();
    return SpotDetail(row);
  }

  /// 등록 중 핀을 움직이는 동안 호출 — 반경은 타입별로 서버가 정한다
  /// (스트리트 50m, 파크·광장 150m. supabase/migrations/0002_functions.sql).
  static Future<List<NearSpot>> near({
    required double lng,
    required double lat,
    required SpotType type,
  }) async {
    final rows = await _db.rpc('spots_near', params: {
      'lng': lng,
      'lat': lat,
      'new_type': _typeValue(type),
    }) as List;
    return rows
        .map((r) => NearSpot.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  /// 등록. rate limit·중복 플래그는 서버(create_spot RPC)가 건다 —
  /// 클라이언트가 우회할 수 없게.
  static Future<int> create(NewSpotInput s) async {
    final id = await _db.rpc('create_spot', params: {
      'p_name': s.name,
      'p_lng': s.lng,
      'p_lat': s.lat,
      'p_spot_type': _typeValue(s.type),
      'p_obstacles': s.obstacles,
      'p_difficulty': s.difficulty,
      'p_surface': s.surface,
      'p_surface_quality': s.surfaceQuality,
      'p_is_indoor': s.isIndoor,
      'p_is_free': s.isFree,
      'p_has_lighting': s.hasLighting,
      'p_night_ok': s.nightOk,
      'p_kickout_risk': s.kickoutRisk ?? 'unknown',
      'p_best_time': s.bestTime,
      'p_description': s.description,
      'p_is_private_property': s.isPrivateProperty,
    }) as num;
    return id.toInt();
  }

  /// 사진을 스토리지에 올리고 spot_photos에 행을 남긴다.
  /// [isCover]는 신규 등록의 첫 사진에만 true — 목록·마커의 대표 사진이 된다.
  static Future<void> uploadPhoto({
    required int spotId,
    required Uint8List bytes,
    required bool isCover,
  }) async {
    final uid = _db.auth.currentUser!.id;
    final path = '$spotId/${DateTime.now().microsecondsSinceEpoch}.jpg';

    await _db.storage.from('spot-photos').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );

    await _db.from('spot_photos').insert({
      'spot_id': spotId,
      'uploaded_by': uid,
      'storage_path': path,
      'is_cover': isCover,
    });
  }

  static String publicPhotoUrl(String storagePath) =>
      _db.storage.from('spot-photos').getPublicUrl(storagePath);

  /// 제보(주로 "없어졌어요") 증빙 사진. 스팟 사진첩(spot_photos)에는 안 넣는다 —
  /// 운영자만 보는 감사 자료지 다른 사용자에게 노출할 갤러리 사진이 아니다.
  /// 같은 버킷의 `reports/` 아래에 올린다 (버킷 정책은 경로를 구분하지 않는다).
  static Future<void> uploadReportPhoto(String path, Uint8List bytes) {
    return _db.storage.from('spot-photos').uploadBinary(
          path, bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );
  }

  /// 상세 화면의 사진 캐러셀. 대표 사진(is_cover)을 맨 앞에 둔다.
  static Future<List<String>> photoUrls(int spotId) async {
    final rows = await _db
        .from('spot_photos')
        .select('storage_path')
        .eq('spot_id', spotId)
        .order('is_cover', ascending: false)
        .order('created_at');
    return (rows as List)
        .map((r) => publicPhotoUrl(r['storage_path'] as String))
        .toList();
  }

  /// 제보 — "아직 있어요"는 즉시 반영, 나머지는 3건 누적돼야 상태가 바뀐다
  /// (TRUST_AND_MODERATION.md). 같은 유저의 같은 유형 제보는 월 1건으로
  /// 서버가 조용히 무시하므로, 반환값이 null이어도 실패가 아니다.
  static Future<void> submitReport({
    required int spotId,
    required String kind,
    String? memo,
    String? photoPath,
  }) {
    return _db.rpc('submit_report', params: {
      'p_spot_id': spotId,
      'p_kind': kind,
      'p_memo': memo,
      'p_photo_path': photoPath,
    });
  }

  /// 공유 딥링크로 들어온 스팟 1개. `spots_in_bbox`와 같은 행 모양이라
  /// `SpotPin`으로 그대로 파싱한다. 비회원도 열 수 있다(RPC가 anon 허용).
  static Future<SpotPin?> pinById(int id) async {
    final rows = await _db.rpc('spot_pin', params: {'p_id': id}) as List;
    if (rows.isEmpty) return null;
    return SpotPin.fromRow(Map<String, dynamic>.from(rows.first as Map));
  }

  static Future<bool> isFavorite(int spotId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return false;
    final row = await _db
        .from('favorites')
        .select('spot_id')
        .eq('user_id', uid)
        .eq('spot_id', spotId)
        .maybeSingle();
    return row != null;
  }

  static Future<void> addFavorite(int spotId) {
    final uid = _db.auth.currentUser!.id;
    return _db.from('favorites').insert({'user_id': uid, 'spot_id': spotId});
  }

  static Future<void> removeFavorite(int spotId) {
    final uid = _db.auth.currentUser!.id;
    return _db
        .from('favorites')
        .delete()
        .eq('user_id', uid)
        .eq('spot_id', spotId);
  }

  /// 즐겨찾기 목록. 저장 순서(최근 먼저)로, 마커와 같은 모양(`SpotPin`)으로 돌려준다.
  static Future<List<SpotPin>> myFavorites() async {
    final rows = await _db.rpc('my_favorite_spots') as List;
    return rows
        .map((r) => SpotPin.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  /// 지명 검색 — 카카오 로컬 키워드 검색. REST API 키는 공개돼도 안전한
  /// 값이다(env.dart 주석 참조). 별도 활성화 없이 기본으로 열려 있다.
  static Future<List<PlaceResult>> searchPlace(String query) async {
    final uri = Uri.https('dapi.kakao.com', '/v2/local/search/keyword.json',
        {'query': query, 'size': '10'});
    final res =
        await http.get(uri, headers: {'Authorization': 'KakaoAK $kakaoRestApiKey'});
    if (res.statusCode != 200) throw StateError('Place search failed');
    final docs = (jsonDecode(res.body) as Map)['documents'] as List;
    return docs.map((d) => PlaceResult.fromRow(d as Map)).toList();
  }

  static String _typeValue(SpotType t) => switch (t) {
        SpotType.skatepark => 'skatepark',
        SpotType.plazaPark => 'plaza_park',
        SpotType.diy => 'diy',
        SpotType.street => 'street',
      };
}
