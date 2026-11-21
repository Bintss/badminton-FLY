export type MemberRole = 'admin' | 'member'
export type MemberStatus = 'pending' | 'approved' | 'rejected' | 'left'

export interface Club {
  id: string
  name: string
  created_at: string
  timezone?: string
  description?: string
  link_url?: string | null
  logo_path?: string | null
}

export interface ClubPlace {
  id: string
  club_id: string
  name: string
  address: string
  note: string
  sort: number
}

/** clubs 조회에 쓰는 컬럼 목록 */
export const CLUB_COLUMNS = 'id, name, created_at, timezone, description, link_url, logo_path'

export interface Profile {
  id: string
  display_name: string
}

export interface ClubMember {
  club_id: string
  user_id: string
  role: MemberRole
  status: MemberStatus
  level: string | null
  /** 'M' 남 / 'F' 여 / null 미입력 */
  gender: 'M' | 'F' | null
  /** 강퇴된 시각. 있으면 다시 가입 신청 불가 */
  banned_at: string | null
  requested_at: string
}

/** club_members + profiles + clubs 조인 결과 */
/** 동아리 개설 신청 */
export interface ClubRequest {
  id: string
  requested_by: string
  requester_name: string
  name: string
  note: string
  status: 'pending' | 'approved' | 'rejected' | 'canceled'
  reason: string | null
  club_id: string | null
  created_at: string
  decided_at: string | null
}

export interface MembershipWithClub extends ClubMember {
  clubs: Pick<Club, 'id' | 'name' | 'logo_path'> | null
}

export interface MemberWithProfile extends ClubMember {
  profiles: Profile | null
}

export type SessionType = 'regular' | 'flash'
export type SessionKind = 'normal' | 'tournament' | 'exchange'
/** 대회 진행 단계. 일반 운동은 null */
export type TournamentState = 'draft' | 'published' | 'in_progress' | 'finished'
export type RegistrationStatus = 'confirmed' | 'waitlisted' | 'canceled'

/** session_overview 뷰 한 행 */
export interface SessionOverview {
  id: string
  club_id: string
  template_id: string | null
  type: SessionType
  host_user_id: string | null
  title: string
  place: string
  starts_at: string
  ends_at: string
  capacity: number
  court_count: number
  opens_at: string
  canceled_at: string | null
  /** 정원을 차지한 확정 인원 (게스트 정원 포함 설정이면 게스트도) */
  confirmed_count: number
  waitlist_count: number
  /** 취소 안 한 게스트 전체 */
  guest_count: number
  guests_in_capacity: boolean
  my_registration_id: string | null
  my_status: RegistrationStatus | null
  kind: SessionKind
  tournament_state: TournamentState | null
  round_count: number | null
  score_target: number
  score_cap: number | null
  minutes_per_game: number
  /** 교류전 상대 동아리와 초대 상태, 상대 정원·인원 (일반 운동·자체대회는 null·0) */
  partner_club_id: string | null
  partner_status: 'invited' | 'accepted' | 'declined' | null
  partner_capacity: number | null
  partner_confirmed_count: number
  partner_waitlist_count: number
}

export interface SessionTemplate {
  id: string
  club_id: string
  title: string
  weekday: number
  start_time: string // 'HH:MM:SS'
  end_time: string
  place: string
  capacity: number
  court_count: number
  open_days_before: number
  open_time: string
  active: boolean
  guests_in_capacity: boolean
  /** 고정 참석자: 일정이 만들어질 때 자동 신청되는 회원 */
  fixed_user_ids: string[]
}

/** registrations + 신청자 이름 */
export interface RegistrationRow {
  id: string
  session_id: string
  kind: 'member' | 'guest'
  user_id: string | null
  guest_name: string | null
  status: RegistrationStatus
  seq: number
  late_eta: string | null
  checked_in_at: string | null
  created_at: string
  promoted_at: string | null
  added_by: string | null
  side_club_id?: string | null
  guest_gender: 'M' | 'F' | null
  guest_level: string | null
  /** 정기운동 고정 참석자로 자동 신청됨 */
  is_fixed?: boolean
  profiles: { display_name: string } | null
  /** 게스트를 데려온 회원 */
  adder?: { display_name: string } | null
}
