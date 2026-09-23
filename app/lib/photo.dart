import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 업로드 전 처리 — 두 가지를 한 번에 해결한다.
///
/// 1. **EXIF GPS 제거.** 사진 촬영자의 집 위치가 새어나갈 수 있다
///    (docs/DATA_MODEL.md #저장하지-않는-것). 디코드→인코드 자체가 원본
///    메타데이터를 버리므로 별도 EXIF 라이브러리가 필요 없다.
/// 2. **용량 축소.** 스팟 사진은 판단 자료지 인화용이 아니다. 긴 변
///    1600px로 제한한다.
///
/// 회전은 EXIF의 orientation 태그가 사라지기 전에 픽셀에 구워 넣는다
/// (`bakeOrientation`) — 안 하면 세로로 찍은 사진이 재인코딩 후 눕는다.
Uint8List preparePhoto(Uint8List original) {
  final decoded = img.decodeImage(original);
  if (decoded == null) throw const FormatException('이미지를 읽을 수 없어요');

  final upright = img.bakeOrientation(decoded);
  final longSide = upright.width > upright.height ? upright.width : upright.height;
  final resized = longSide > 1600
      ? (upright.width >= upright.height
          ? img.copyResize(upright, width: 1600)
          : img.copyResize(upright, height: 1600))
      : upright;

  return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}
