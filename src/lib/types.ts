export type MemberRole = 'admin' | 'member'
export type MemberStatus = 'pending' | 'approved' | 'rejected' | 'left'

export interface Club {
  id: string
  name: string
  created_at: string
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
