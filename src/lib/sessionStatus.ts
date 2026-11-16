import type { SessionOverview } from './types'

export type SessionPhase = 'canceled' | 'before_open' | 'open' | 'full' | 'in_progress' | 'ended'

/** 세션 상태는 저장하지 않고 시각으로 계산한다 (DB와 같은 규칙). now = 서버 보정 시각 */
export function sessionPhase(s: SessionOverview, now: number): SessionPhase {
  if (s.canceled_at) return 'canceled'
  const opens = Date.parse(s.opens_at)
  const starts = Date.parse(s.starts_at)
  const ends = Date.parse(s.ends_at)
  if (now < opens) return 'before_open'
  if (now < starts) return s.confirmed_count >= s.capacity ? 'full' : 'open'
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
