// 홈 화면 앱(PWA)용 최소 서비스워커.
// 앱 파일은 캐시하지 않는다: 배포하면 항상 최신 화면을 받도록 (투표 규칙이 바뀌어도 옛 화면이 남지 않게).
// 네트워크가 끊겼을 때만 안내 화면을 보여준다. Supabase 요청은 건드리지 않는다.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

const OFFLINE_HTML = `<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>배드민턴 모임</title><body style="margin:0;font-family:system-ui,sans-serif;background:#f1f4f3;color:#1a2421;display:grid;place-items:center;min-height:100vh;text-align:center">
<div><p style="font-size:18px;font-weight:700">인터넷에 연결되어 있지 않아요</p><p style="color:#55615d">연결을 확인한 뒤 다시 열어주세요.</p>
<button onclick="location.reload()" style="margin-top:12px;height:44px;padding:0 20px;border:0;border-radius:12px;background:#13644f;color:#fff;font-size:15px;font-weight:600">다시 시도</button></div></body></html>`

self.addEventListener('fetch', (event) => {
  if (event.request.mode !== 'navigate') return
  event.respondWith(
    fetch(event.request).catch(() => new Response(OFFLINE_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8' } })),
  )
})

// ── 웹 푸시 ────────────────────────────────────────────────────
// 서버(send-push)가 보낸 {title, body, url, tag}를 알림으로 띄운다
self.addEventListener('push', (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch {
    data = { title: '배드민턴 모임', body: event.data ? event.data.text() : '' }
  }
  const scope = self.registration.scope
  // 홈 화면 앱 아이콘에 안 읽은 수 (서버가 badge로 보내줌, 지원하는 폰만)
  if (typeof data.badge === 'number' && self.navigator && 'setAppBadge' in self.navigator) {
    self.navigator.setAppBadge(data.badge).catch(() => {})
  }
  event.waitUntil(
    self.registration.showNotification(data.title || '배드민턴 모임', {
      body: data.body || '',
      icon: scope + 'icons/icon-192.png',
      badge: scope + 'icons/icon-192.png',
      tag: data.tag,
      renotify: Boolean(data.tag),
      data: { url: data.url || scope },
    }),
  )
})

// 알림을 누르면: 이미 열린 앱 창이 있으면 그 창을 그 화면으로, 없으면 새로 연다
self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || self.registration.scope
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      for (const w of wins) {
        if (w.url.startsWith(self.registration.scope) && 'focus' in w) {
          w.navigate(url).catch(() => {})
          return w.focus()
        }
      }
      return self.clients.openWindow(url)
    }),
  )
})
