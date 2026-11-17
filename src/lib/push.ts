import { supabase } from './supabase'

/** 이 기기에서 웹 푸시를 켤 수 있는 상태 */
export type PushState =
  | 'unsupported' // 브라우저가 지원 안 함 (카톡 안 브라우저 등)
  | 'ios_install' // 아이폰: 홈 화면에 추가한 앱에서만 가능
  | 'not_ready' // 서버에 알림 키가 아직 없음 (운영 설정 전)
  | 'denied' // 사용자가 알림 권한을 막음 → 폰 설정에서 풀어야 함
  | 'off' // 켤 수 있음
  | 'on' // 켜져 있음

const isIos = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
const isStandalone = () =>
  window.matchMedia('(display-mode: standalone)').matches || (navigator as unknown as { standalone?: boolean }).standalone === true

async function registration() {
  if (!('serviceWorker' in navigator)) return null
  const base = import.meta.env.BASE_URL
  return (await navigator.serviceWorker.getRegistration(base)) ?? (await navigator.serviceWorker.register(`${base}sw.js`, { scope: base }))
}

let cachedKey: string | null | undefined
async function publicKey() {
  if (cachedKey !== undefined) return cachedKey
  const { data } = await supabase.rpc('push_public_key')
  cachedKey = (data as string | null) ?? null
  return cachedKey
}

export async function pushState(): Promise<PushState> {
  if (isIos() && !isStandalone()) return 'ios_install'
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return 'unsupported'
  if (Notification.permission === 'denied') return 'denied'
  if (!(await publicKey())) return 'not_ready'
  const reg = await registration()
  const sub = await reg?.pushManager.getSubscription()
  return sub && Notification.permission === 'granted' ? 'on' : 'off'
}

function urlBase64ToUint8Array(base64: string) {
  const padding = '='.repeat((4 - (base64.length % 4)) % 4)
  const raw = atob((base64 + padding).replace(/-/g, '+').replace(/_/g, '/'))
  return Uint8Array.from(raw, (c) => c.charCodeAt(0))
}

/** 알림 켜기: 권한 요청 → 구독 → 서버에 저장. 결과 상태를 돌려준다 */
export async function enablePush(): Promise<PushState> {
  const key = await publicKey()
  if (!key) return 'not_ready'
  const permission = await Notification.requestPermission()
  if (permission !== 'granted') return permission === 'denied' ? 'denied' : 'off'
  const reg = await registration()
  if (!reg) return 'unsupported'
  const sub =
    (await reg.pushManager.getSubscription()) ??
    (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(key) }))
  const json = sub.toJSON() as { endpoint: string; keys: { p256dh: string; auth: string } }
  const { error } = await supabase.rpc('save_push_subscription', {
    p_endpoint: json.endpoint,
    p_p256dh: json.keys.p256dh,
    p_auth: json.keys.auth,
    p_user_agent: navigator.userAgent,
  })
  if (error) throw error
  return 'on'
}

/** 이 기기 알림 끄기 */
export async function disablePush(): Promise<PushState> {
  const reg = await registration()
  const sub = await reg?.pushManager.getSubscription()
  if (sub) {
    await supabase.rpc('delete_push_subscription', { p_endpoint: sub.endpoint })
    await sub.unsubscribe()
  }
  return 'off'
}

/** 로그인한 계정이 바뀌어도 이 기기 구독을 현재 계정으로 다시 저장 (켜져 있을 때만) */
export async function syncPushSubscription() {
  try {
    if (!('serviceWorker' in navigator) || !('PushManager' in window) || Notification.permission !== 'granted') return
    const reg = await navigator.serviceWorker.getRegistration(import.meta.env.BASE_URL)
    const sub = await reg?.pushManager.getSubscription()
    if (!sub) return
    const json = sub.toJSON() as { endpoint: string; keys: { p256dh: string; auth: string } }
    await supabase.rpc('save_push_subscription', {
      p_endpoint: json.endpoint,
      p_p256dh: json.keys.p256dh,
      p_auth: json.keys.auth,
      p_user_agent: navigator.userAgent,
    })
  } catch {
    /* 알림 동기화 실패는 앱 사용에 지장 없음 */
  }
}

export const NOTIFICATION_KINDS = [
  { kind: 'vote_created', label: '새 운동 투표', hint: '정기운동·번개·자체대회가 생겼을 때' },
  { kind: 'vote_soon', label: '투표 10분 전', hint: '선착순 투표가 열리기 10분 전' },
  { kind: 'court_assigned', label: '코트 배정', hint: '내 경기가 코트에 들어갔을 때' },
  { kind: 'join_approved', label: '가입 승인', hint: '동아리 가입이 승인됐을 때' },
  { kind: 'join_request', label: '가입 신청 (운영진)', hint: '누군가 가입을 신청했을 때' },
] as const
export type NotificationKind = (typeof NOTIFICATION_KINDS)[number]['kind']
