/// 클라이언트 키. 둘 다 앱에 embed 되는 게 전제인 공개 키다.
///
/// - Supabase publishable key: RLS가 실제 접근 제어를 한다 (docs/DATA_MODEL.md)
/// - Kakao 네이티브 앱 키: 패키지명 + 키 해시로 바인딩된다
///
/// 그래도 CI나 다른 환경에서 바꿔 끼울 수 있게 --dart-define을 받는다.
/// **secret key는 절대 여기 두지 않는다.** 서버 전용이다.
library;

const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://udirqulcxuixelzagvpg.supabase.co',
);

const supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_418BpwghMiBfTOaPVFHFMQ_jdAwkVaH',
);

const kakaoAppKey = String.fromEnvironment(
  'KAKAO_APP_KEY',
  defaultValue: '1c6f918f0493317c5267d13d1b16fd2d',
);

/// REST API 키. 카카오 로그인 OIDC 흐름의 client_id로 쓴다 (auth.dart).
/// OAuth의 client_id와 같은 성격의 값이라 공개돼도 안전하다 —
/// 실제 비밀은 서버(Edge Function)에만 있는 client_secret이다.
const kakaoRestApiKey = String.fromEnvironment(
  'KAKAO_REST_API_KEY',
  defaultValue: '544383594aa4a8fb77c33af0640b31ed',
);
