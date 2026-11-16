export type MemberRole = 'admin' | 'member'
export type MemberStatus = 'pending' | 'approved' | 'rejected' | 'left'

export interface Club {
  id: string
  name: string
  created_at: string
  timezone?: string
}

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
  clubs: Pick<Club, 'id' | 'name'> | null
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
