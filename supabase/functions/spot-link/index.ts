// Public landing for shared spots. The URL is clickable in messengers even
// before Universal Links / Android App Links have a dedicated domain.
Deno.serve((request) => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405 });
  }

  const id = new URL(request.url).searchParams.get("id");
  if (!id || !/^[1-9][0-9]{0,18}$/.test(id)) {
    return new Response("Invalid spot id", { status: 400 });
  }

  const deepLink = "com.skatespot.sk8spot://spot/" + id;
  const html = `<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta property="og:title" content="Skate Spot">
  <meta property="og:description" content="공유받은 스케이트 스팟을 앱에서 확인하세요.">
  <title>스팟 열기 · Skate Spot</title>
  <style>
    body { margin: 0; min-height: 100vh; display: grid; place-items: center;
           font: 16px system-ui, sans-serif; background: #f3f4f6; color: #111827; }
    main { margin: 24px; padding: 32px; max-width: 420px; background: white;
           border-radius: 18px; box-shadow: 0 8px 30px #11182714; text-align: center; }
    a { display: block; padding: 14px; border-radius: 10px; background: #111827;
        color: white; font-weight: 700; text-decoration: none; }
    p { line-height: 1.6; color: #4b5563; }
  </style>
</head>
<body>
  <main>
    <h1>Skate Spot</h1>
    <p>공유받은 스팟을 앱에서 확인하세요.</p>
    <a href="${deepLink}">앱에서 스팟 열기</a>
    <p>앱이 설치되지 않았다면 앱 출시 후 다시 열어주세요.</p>
  </main>
</body>
</html>`;
  return new Response(request.method === "HEAD" ? null : html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=300",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
    },
  });
});