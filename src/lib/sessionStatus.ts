import type { SessionOverview } from './types'

export type SessionPhase = 'canceled' | 'before_open' | 'open' | 'full' | 'in_progress' | 'ended'

/**
 * 보는 동아리 편의 정원·인원. 교류전에서 상대 동아리 화면이면 상대 편, 그 밖에는 주최(= 전체)
 */
export function sideCounts(s: SessionOverview, clubId?: string) {
  const partner = s.kind === 'exchange' && !!clubId && clubId === s.partner_club_id
  return partner
    ? { confirmed: s.partner_confirmed_count, waitlist: s.partner_waitlist_count, capacity: s.partner_capacity ?? 0 }
    : { confirmed: s.confirmed_count, waitlist: s.waitlist_count, capacity: s.capacity }
}

/** 세션 상태는 저장하지 않고 시각으로 계산한다 (DB와 같은 규칙). now = 서버 보정 시각, clubId = 보는 동아리(교류전 편) */
export function sessionPhase(s: SessionOverview, now: number, clubId?: string): SessionPhase {
  if (s.canceled_at) return 'canceled'
  const opens = Date.parse(s.opens_at)
  const starts = Date.parse(s.starts_at)
  const ends = Date.parse(s.ends_at)
  if (now < opens) return 'before_open'
  if (now < starts) {
    const c = sideCounts(s, clubId)
    return c.confirmed >= c.capacity ? 'full' : 'open'
  }
  if (now < ends) return 'in_progress'
  return 'ended'
}

export const PHASE_LABEL: Record<SessionPhase, string> = {
  canceled: '취소됨',
  before_open: '오픈 전',
  open: '투표 중',
  full: '마감',
  in_progress: '진행 중',
  ended: '종료',
}
