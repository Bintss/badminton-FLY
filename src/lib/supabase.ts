import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
// 새 publishable 키(sb_publishable_...) 우선, 기존 이름(ANON_KEY)도 지원. CI에서 미설정 변수는 빈 문자열이라 || 사용
const anonKey = (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY) as
  | string
  | undefined

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
  last_admin: '마지막 운영진이라 해제하거나 나갈 수 없어요. 다른 사람을 먼저 운영진으로 지정하세요.',
  session_not_found: '운동 일정을 찾을 수 없어요.',
  session_canceled: '취소된 운동이에요.',
  not_open: '아직 투표가 열리지 않았어요.',
  closed: '이미 시작한 운동이에요.',
  registration_not_found: '신청 내역을 찾을 수 없어요.',
  already_canceled: '이미 취소한 신청이에요.',
  invalid_capacity: '정원은 1명 이상이어야 해요.',
  capacity_below_confirmed: '현재 확정 인원보다 적게 줄일 수 없어요.',
  invalid_time: '시간을 확인해주세요. (시작은 미래, 끝은 시작보다 늦게, 오픈은 시작 전)',
  invalid_court_count: '코트는 1면 이상이어야 해요.',
  template_not_found: '정기운동을 찾을 수 없어요.',
  already_open: '이미 투표가 열려서 오픈 시각은 바꿀 수 없어요.',
  not_confirmed: '참석 확정된 사람만 체크인할 수 있어요.',
  invalid_name: '이름을 입력해주세요.',
  club_needs_approval: '동아리는 개설 신청 후 승인을 받아야 만들 수 있어요.',
  request_pending: '이미 승인을 기다리는 개설 신청이 있어요.',
  request_not_found: '이미 처리됐거나 없는 신청이에요.',
  guest_limit: '게스트는 한 사람당 3명까지 데려올 수 있어요.',
  need_four_players: '서로 다른 4명을 골라주세요.',
  invalid_players: '이 운동 참석자만 경기에 넣을 수 있어요.',
  match_not_found: '경기를 찾을 수 없어요.',
  not_playing: '이미 끝난 경기예요. (다른 폰에서 먼저 처리했을 수 있어요)',
  match_closed: '이미 끝났거나 취소된 경기예요.',
  not_queued: '대기 중인 경기만 순서를 바꿀 수 있어요.',
  invalid_link: '링크는 https://로 시작해야 해요.',
  invalid_logo_path: '로고 파일 경로가 올바르지 않아요.',
  place_not_found: '장소를 찾을 수 없어요.',
  tournament_locked: '지금 대회 단계에서는 바꿀 수 없어요. 새로고침해서 대회 상태를 확인해주세요.',
  tournament_running: '대회가 진행 중이라 자율 경기를 만들 수 없어요. 대회가 끝나면 다시 만들 수 있어요.',
  tournament_started: '이미 대회 경기가 시작돼서 확정을 취소할 수 없어요.',
  not_tournament: '자체대회가 아닌 운동이에요.',
  invalid_gender: '성별은 남 또는 여로 골라주세요.',
  banned: '이 동아리에는 가입 신청을 할 수 없어요.',
  invalid_score: '점수가 규칙에 맞지 않아요. 목표 점수와 듀스 규칙을 확인해주세요.',
  score_forbidden: '점수는 이 경기 선수나 운영진만 넣을 수 있어요. 대회가 끝난 뒤 수정은 운영진만 할 수 있어요.',
  score_conflict: '다른 사람이 먼저 점수를 넣었어요. 새로고침해서 확인해주세요.',
  match_not_finished: '경기가 끝난 뒤에 점수를 넣을 수 있어요.',
  not_forfeitable: '시작 전인 대회 경기만 기권 처리할 수 있어요.',
  not_scheduled: '대회 경기에만 점수를 기록해요.',
  cannot_remove_self: '본인은 내보낼 수 없어요. 내 정보에서 동아리 나가기를 쓰세요.',
  is_admin: '운영진은 바로 내보낼 수 없어요. 먼저 운영진에서 해제하세요.',
  not_banned: '강퇴된 회원이 아니에요.',
  confirm_name_mismatch: '동아리 이름이 정확히 같지 않아요.',
  invalid_level: '급수는 A조, B조, C조, D조, 초심 중에서 골라주세요.',
  invalid_round_count: '매치 수는 1~20 사이로 정해주세요.',
  invalid_score_rule: '점수 규칙을 확인해주세요. (목표 5~50점, 최대 점수는 목표 이상)',
  invalid_minutes: '경기당 시간은 5~60분 사이로 정해주세요.',
  rounds_in_use: '대진에 들어 있는 매치보다 매치 수를 줄일 수 없어요. 먼저 그 매치의 경기를 지워주세요.',
  score_rule_locked: '점수가 입력된 뒤에는 점수 규칙을 바꿀 수 없어요.',
  invalid_schedule: '대진 형식이 올바르지 않아요.',
  invalid_round: '매치 번호가 매치 수를 넘었어요.',
  duplicate_order: '같은 매치에 같은 순서의 경기가 두 개 있어요.',
  duplicate_in_round: '한 사람이 같은 매치에 두 경기 들어 있어요.',
  empty_schedule: '대진이 비어 있어요. 경기를 하나 이상 넣어주세요.',
  schedule_stale: '대진에 참석을 취소한 사람이 있어요. 그 자리를 바꾸고 다시 저장해주세요.',
  not_substitutable: '시작 전인 대회 경기만 선수를 바꿀 수 있어요.',
  scheduled_order_locked: '대회 경기 순서는 대진표 순서를 따라요.',
}

/** RPC 에러를 사용자에게 보여줄 문장으로 바꾼다. */
export function errorMessage(err: unknown): string {
  const msg = typeof err === 'object' && err && 'message' in err ? String((err as { message: unknown }).message) : String(err)
  return ERROR_MESSAGES[msg] ?? `문제가 생겼어요: ${msg}`
}
