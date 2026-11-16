import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

export const isSupabaseConfigured = Boolean(url && anonKey)

export const supabase = createClient(url ?? 'http://localhost', anonKey ?? 'missing', {
  auth: {
    flowType: 'pkce', // 정적 호스팅: 브라우저에서 ?code= 를 세션으로 교환
    detectSessionInUrl: true,
    persistSession: true,
    autoRefreshToken: true,
  },
})

/** OAuth 리다이렉트 목적지. 앱 루트(index.html이 실제로 있는 경로)로 돌아오게 해서 404를 피한다. */
export const appRootUrl = () => new URL(import.meta.env.BASE_URL, window.location.origin).toString()

const ERROR_MESSAGES: Record<string, string> = {
  not_authenticated: '로그인이 필요해요.',
  forbidden: '권한이 없어요.',
  club_not_found: '동아리를 찾을 수 없어요.',
  not_pending: '이미 처리된 신청이에요.',
  not_member: '동아리 회원이 아니에요.',
  last_admin: '마지막 운영진은 해제할 수 없어요.',
}

/** RPC 에러를 사용자에게 보여줄 문장으로 바꾼다. */
export function errorMessage(err: unknown): string {
  const msg = typeof err === 'object' && err && 'message' in err ? String((err as { message: unknown }).message) : String(err)
  return ERROR_MESSAGES[msg] ?? `문제가 생겼어요: ${msg}`
}
