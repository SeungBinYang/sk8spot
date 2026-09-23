// Kakao OIDC 코드 교환 — Client Secret을 클라이언트에 노출하지 않기 위한 서버 프록시.
//
// 왜 이게 필요한가: Supabase 내장 Kakao OAuth 프로바이더는 항상
// account_email + profile_image 스코프를 강제로 요청한다. 이메일 동의항목은
// 카카오 비즈 앱 전환(본인인증) 없이는 열리지 않아 KOE205로 로그인이 막힌다.
//
// 그래서 이 앱은 OIDC(openid 스코프)로 직접 인가 코드를 받고, 이 함수에서
// 토큰으로 교환한 뒤 id_token만 돌려준다. 클라이언트는 그 id_token으로
// supabase.auth.signInWithIdToken을 호출해 세션을 만든다.
// client_secret은 이 함수 밖으로 절대 나가지 않는다.
//
// 필요한 Edge Function Secrets: KAKAO_REST_API_KEY, KAKAO_CLIENT_SECRET
// (Project Settings > Edge Functions > Secrets 에서 등록)

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let payload: { code?: string; redirect_uri?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "잘못된 요청 본문" }, 400);
  }

  const { code, redirect_uri } = payload;
  if (!code || !redirect_uri) {
    return json({ error: "code, redirect_uri가 필요합니다" }, 400);
  }

  const clientId = Deno.env.get("KAKAO_REST_API_KEY");
  const clientSecret = Deno.env.get("KAKAO_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    return json(
      { error: "서버 설정 누락: KAKAO_REST_API_KEY / KAKAO_CLIENT_SECRET" },
      500,
    );
  }

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uri,
    code,
  });

  let data: Record<string, unknown>;
  try {
    const r = await fetch("https://kauth.kakao.com/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded;charset=utf-8" },
      body,
    });
    data = await r.json();
    if (!r.ok) {
      return json(
        { error: data.error_description ?? data.error ?? "카카오 토큰 교환 실패" },
        400,
      );
    }
  } catch (e) {
    return json({ error: `카카오 요청 실패: ${e}` }, 502);
  }

  if (!data.id_token) {
    // openid 스코프 없이 받은 code이거나, OIDC 설정이 꺼져 있을 때 여기로 온다.
    return json({ error: "id_token이 없습니다. Kakao 콘솔의 OpenID Connect 설정을 확인하세요." }, 400);
  }

  return json({ id_token: data.id_token, access_token: data.access_token });
});
