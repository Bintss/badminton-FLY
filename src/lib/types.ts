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
  requested_at: string
}

/** club_members + profiles + clubs 조인 결과 */
export interface MembershipWithClub extends ClubMember {
  clubs: Pick<Club, 'id' | 'name' | 'logo_path'> | null
}

export interface MemberWithProfile extends ClubMember {
  profiles: Profile | null
}

export type SessionType = 'regular' | 'flash'
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
  confirmed_count: number
  waitlist_count: number
  guest_count: number
  my_registration_id: string | null
  my_status: RegistrationStatus | null
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
  profiles: { display_name: string } | null
}
