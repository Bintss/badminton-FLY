// 웹 푸시 보내기 (Supabase Edge Function)
//   DB 트리거(pg_net)가 알림이 생길 때마다, 예약 작업이 매분 이 함수를 부른다.
//   보낼 알림을 가져가서(claim_push_batch) 그 사람의 모든 기기(push_subscriptions)로 보내고,
//   없어진 기기(404/410)는 구독을 지우고, 알림에 '보냄' 표시(finish_push)를 한다.
//
// 필요한 비밀값 (supabase secrets set …):
//   PUSH_SECRET        DB Vault의 push_secret과 같은 값 (아무나 이 함수를 부르지 못하게)
//   VAPID_PUBLIC_KEY   npx web-push generate-vapid-keys 로 만든 공개 키
//   VAPID_PRIVATE_KEY  같은 명령으로 만든 비밀 키 (절대 앱·저장소에 넣지 않는다)
//   VAPID_SUBJECT      mailto:운영진메일 (푸시 서비스가 문제 있을 때 연락할 곳)
//   APP_URL            https://bintss.github.io/badminton-FLY  (알림을 누르면 열 주소의 앞부분)
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 는 Supabase가 자동으로 넣어준다.
//
// 배포: supabase functions deploy send-push --no-verify-jwt   (호출 확인은 PUSH_SECRET으로 한다)

import webpush from 'npm:web-push@3.6.7'
import { createClient } from 'npm:@supabase/supabase-js@2'

const BATCH = 200
const MAX_ROUNDS = 5

Deno.serve(async (req) => {
  if (req.headers.get('x-push-secret') !== Deno.env.get('PUSH_SECRET')) {
    return new Response('forbidden', { status: 403 })
  }

  // 설정 확인: 무엇이 잘못됐는지 응답에 남긴다 (DB의 net._http_response에서 보임). 비밀값 자체는 절대 내보내지 않는다
  const subject = (Deno.env.get('VAPID_SUBJECT') ?? '').trim()
  const publicKey = (Deno.env.get('VAPID_PUBLIC_KEY') ?? '').trim()
  const privateKey = (Deno.env.get('VAPID_PRIVATE_KEY') ?? '').trim()
  const problems: string[] = []
  if (!/^(mailto:|https:\/\/)/.test(subject)) problems.push('VAPID_SUBJECT는 mailto:메일주소 형식이어야 해요')
  if (!/^[A-Za-z0-9_-]{80,90}$/.test(publicKey)) problems.push(`VAPID_PUBLIC_KEY 형식이 아니에요 (길이 ${publicKey.length}, 보통 87자)`)
  if (!/^[A-Za-z0-9_-]{40,46}$/.test(privateKey)) problems.push(`VAPID_PRIVATE_KEY 형식이 아니에요 (길이 ${privateKey.length}, 보통 43자)`)
  if (problems.length) return json({ ok: false, step: 'config', problems }, 500)
  try {
    webpush.setVapidDetails(subject, publicKey, privateKey)
  } catch (e) {
    return json({ ok: false, step: 'vapid', error: (e as Error).message }, 500)
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  })
  const appUrl = (Deno.env.get('APP_URL') ?? '').replace(/\/$/, '')

  let sent = 0
  let failed = 0
  for (let round = 0; round < MAX_ROUNDS; round++) {
    const { data: batch, error } = await supabase.rpc('claim_push_batch', { p_limit: BATCH })
    if (error) return json({ ok: false, step: 'claim', error: error.message }, 500)
    if (!batch || batch.length === 0) break

    const userIds = [...new Set(batch.map((n: { user_id: string }) => n.user_id))]
    const { data: subs } = await supabase.from('push_subscriptions').select('id, user_id, endpoint, p256dh, auth').in('user_id', userIds)
    // 사람별 안 읽은 알림 수 → 앱 아이콘 숫자
    const { data: unreadRows } = await supabase.from('notifications').select('user_id').in('user_id', userIds).is('read_at', null)
    const unread = new Map<string, number>()
    for (const r of unreadRows ?? []) unread.set(r.user_id, (unread.get(r.user_id) ?? 0) + 1)
    const byUser = new Map<string, { id: string; endpoint: string; p256dh: string; auth: string }[]>()
    for (const s of subs ?? []) byUser.set(s.user_id, [...(byUser.get(s.user_id) ?? []), s])

    const done: number[] = []
    const errors: Record<number, string> = {}
    const dead = new Set<string>()
    const ok = new Set<string>()

    await Promise.all(
      batch.map(async (n: { id: number; user_id: string; title: string; body: string; url: string; kind: string; session_id: string | null }) => {
        const payload = JSON.stringify({
          title: n.title,
          body: n.body,
          // 누르면 그 화면을 열면서 이 알림을 읽음 처리 (?read=알림번호)
          url: `${appUrl}${n.url}${n.url.includes('?') ? '&' : '?'}read=${n.id}`,
          // 같은 운동·같은 종류 알림은 폰 알림센터에서 하나로 합쳐진다
          tag: `${n.kind}:${n.session_id ?? n.id}`,
          badge: unread.get(n.user_id) ?? 0,
        })
        const targets = byUser.get(n.user_id) ?? []
        if (targets.length === 0) {
          // 받을 기기가 없음: 알림함에는 있으므로 처리 완료로 두되, 이유를 남긴다
          done.push(n.id)
          errors[n.id] = 'no_device'
          return
        }
        const results = await Promise.all(
          targets.map(async (s) => {
            try {
              await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, {
                TTL: n.kind === 'court_assigned' ? 600 : n.kind === 'court_next' ? 1800 : 6 * 3600, // 코트 배정 10분·코트 대기 30분 지나면 의미 없음
                urgency: n.kind === 'court_assigned' || n.kind === 'court_next' || n.kind === 'vote_soon' ? 'high' : 'normal',
              })
              ok.add(s.id)
              return null
            } catch (e) {
              const status = (e as { statusCode?: number }).statusCode
              if (status === 404 || status === 410) dead.add(s.id) // 앱 삭제·권한 해제 등
              return `${status ?? ''} ${(e as Error).message}`.trim()
            }
          }),
        )
        done.push(n.id)
        const errs = results.filter(Boolean)
        if (errs.length && errs.length === targets.length) errors[n.id] = errs.join('; ').slice(0, 300)
        sent += targets.length - errs.length
        failed += errs.length
      }),
    )

    const okIds = done.filter((id) => !errors[id])
    if (okIds.length) await supabase.rpc('finish_push', { p_ids: okIds, p_error: null })
    for (const [id, msg] of Object.entries(errors)) await supabase.rpc('finish_push', { p_ids: [Number(id)], p_error: msg })
    if (dead.size) await supabase.from('push_subscriptions').delete().in('id', [...dead])
    if (ok.size) await supabase.from('push_subscriptions').update({ last_ok_at: new Date().toISOString() }).in('id', [...ok])
    if (batch.length < BATCH) break
  }

  return json({ ok: true, sent, failed })
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}
