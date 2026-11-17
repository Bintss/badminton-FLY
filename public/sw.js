// 홈 화면 앱(PWA)용 최소 서비스워커.
// 앱 파일은 캐시하지 않는다: 배포하면 항상 최신 화면을 받도록 (투표 규칙이 바뀌어도 옛 화면이 남지 않게).
// 네트워크가 끊겼을 때만 안내 화면을 보여준다. Supabase 요청은 건드리지 않는다.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

const OFFLINE_HTML = `<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FLY 배드민턴</title><body style="margin:0;font-family:system-ui,sans-serif;background:#f1f4f3;color:#1a2421;display:grid;place-items:center;min-height:100vh;text-align:center">
<div><p style="font-size:18px;font-weight:700">인터넷에 연결되어 있지 않아요</p><p style="color:#55615d">연결을 확인한 뒤 다시 열어주세요.</p>
<button onclick="location.reload()" style="margin-top:12px;height:44px;padding:0 20px;border:0;border-radius:12px;background:#13644f;color:#fff;font-size:15px;font-weight:600">다시 시도</button></div></body></html>`

self.addEventListener('fetch', (event) => {
  if (event.request.mode !== 'navigate') return
  event.respondWith(
    fetch(event.request).catch(() => new Response(OFFLINE_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8' } })),
  )
})
