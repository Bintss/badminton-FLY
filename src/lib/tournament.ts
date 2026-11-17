import type { SessionOverview, TournamentState } from './types'

/** 대회 경기 한 줄 (matches + match_players) */
export interface ScheduledMatch {
  id: string
  round_no: number
  order_no: number
  status: 'queued' | 'playing' | 'finished' | 'canceled'
  court_no: number | null
  started_at: string | null
  finished_at: string | null
  score1: number | null
  score2: number | null
  /** normal: 점수, walkover1/2: 팀 1/2 기권승 */
  result_kind: 'normal' | 'walkover1' | 'walkover2' | null
  /** 마지막 입력 시각. 수정할 때 같이 보내 충돌을 막는다 */
  result_at: string | null
  match_players: { registration_id: string; team: 1 | 2 | null }[]
}

export const SCHEDULED_COLUMNS =
  'id, round_no, order_no, status, court_no, started_at, finished_at, score1, score2, result_kind, result_at, match_players(registration_id, team)'

export const STATE_LABEL: Record<TournamentState, string> = {
  draft: '대진 준비 중',
  published: '대진 공개, 시작 전',
  in_progress: '대회 진행 중',
  finished: '대회 끝',
}

/** 대회 경기만 돌아가는 단계인가 (자율 경기 만들기 막힘) */
export function tournamentActive(s: Pick<SessionOverview, 'tournament_state'> | null | undefined) {
  return s?.tournament_state === 'published' || s?.tournament_state === 'in_progress'
}

/** 팀별 두 명씩. 팀 정보가 없으면(자율 경기) 앞 2명 / 뒤 2명 */
export function teamsOf(players: { registration_id: string; team: 1 | 2 | null }[]): [string[], string[]] {
  if (players.every((p) => p.team)) {
    return [players.filter((p) => p.team === 1).map((p) => p.registration_id), players.filter((p) => p.team === 2).map((p) => p.registration_id)]
  }
  const ids = players.map((p) => p.registration_id)
  return [ids.slice(0, 2), ids.slice(2, 4)]
}

export interface PlayerState {
  name: string
  confirmed: boolean
  arrived: boolean
  playingElsewhere: boolean
}

/** 대기 중인 대회 경기가 코트에 못 들어가는 이유. 들어갈 수 있으면 null (서버 match_ready와 같은 규칙) */
export function blockReason(m: ScheduledMatch, info: (id: string) => PlayerState | undefined): string | null {
  const gone: string[] = []
  const notYet: string[] = []
  const busy: string[] = []
  for (const p of m.match_players) {
    const s = info(p.registration_id)
    if (!s || !s.confirmed) gone.push(s?.name ?? '취소한 사람')
    else if (!s.arrived) notYet.push(s.name)
    else if (s.playingElsewhere) busy.push(s.name)
  }
  if (gone.length) return `${gone.join(', ')}님이 참석을 취소했어요. 선수를 바꿔야 해요`
  if (notYet.length) return `${notYet.join(', ')}님이 아직 안 왔어요`
  if (busy.length) return `${busy.join(', ')}님이 다른 코트에서 경기 중이에요`
  return null
}

/** 설정 화면의 예상치: 매치당 경기 수는 코트 수와 (참석자 / 4) 중 작은 값 */
export function planEstimate(players: number, courts: number, rounds: number, minutesPerGame: number) {
  const perRound = Math.max(0, Math.min(courts, Math.floor(players / 4)))
  const games = perRound * rounds
  return {
    perRound,
    games,
    restPerRound: Math.max(0, players - perRound * 4),
    avgPerPlayer: players > 0 ? (games * 4) / players : 0,
    minutes: rounds * minutesPerGame,
  }
}

/** 대진 편집용 한 경기. 빈 자리는 null */
export interface DraftMatch {
  key: string
  round: number
  team1: [string | null, string | null]
  team2: [string | null, string | null]
}

export function draftPlayers(d: DraftMatch): string[] {
  return [...d.team1, ...d.team2].filter((x): x is string => !!x)
}

let keySeq = 0
export function newDraft(round: number): DraftMatch {
  keySeq += 1
  return { key: `new-${keySeq}`, round, team1: [null, null], team2: [null, null] }
}

export function draftsFromMatches(ms: ScheduledMatch[]): DraftMatch[] {
  return [...ms]
    .sort((a, b) => a.round_no - b.round_no || a.order_no - b.order_no)
    .map((m) => {
      const [t1, t2] = teamsOf(m.match_players)
      return { key: m.id, round: m.round_no, team1: [t1[0] ?? null, t1[1] ?? null], team2: [t2[0] ?? null, t2[1] ?? null] }
    })
}

export interface DraftCheck {
  /** 저장 가능한 완성 경기 (빈 경기는 빠짐) */
  complete: DraftMatch[]
  /** 1~3명만 채운 경기 수 */
  partial: number
  /** 매치 수를 넘는 매치에 있는 경기 수 */
  outOfRange: number
  /** 참석을 취소한 사람이 들어 있는 경기 수 */
  stale: number
  /** 사람별 배정 게임 수 (참석 확정자 전원, 0 포함) */
  counts: Record<string, number>
  min: number
  max: number
}

export function checkDrafts(drafts: DraftMatch[], confirmedIds: string[], roundCount: number): DraftCheck {
  const confirmed = new Set(confirmedIds)
  const counts: Record<string, number> = Object.fromEntries(confirmedIds.map((id) => [id, 0]))
  let partial = 0
  let outOfRange = 0
  let stale = 0
  const complete: DraftMatch[] = []
  for (const d of drafts) {
    const ps = draftPlayers(d)
    if (ps.length === 0) continue
    if (ps.length < 4) {
      partial += 1
      continue
    }
    if (d.round > roundCount) outOfRange += 1
    if (ps.some((id) => !confirmed.has(id))) stale += 1
    complete.push(d)
    for (const id of ps) if (id in counts) counts[id] += 1
  }
  const values = Object.values(counts)
  return {
    complete,
    partial,
    outOfRange,
    stale,
    counts,
    min: values.length ? Math.min(...values) : 0,
    max: values.length ? Math.max(...values) : 0,
  }
}

/** save_schedule 입력. 매치 안에서 화면 순서대로 1, 2, 3… */
export function toSchedulePayload(complete: DraftMatch[]) {
  const nextOrder: Record<number, number> = {}
  return complete.map((d) => {
    nextOrder[d.round] = (nextOrder[d.round] ?? 0) + 1
    return { round: d.round, order: nextOrder[d.round], team1: d.team1, team2: d.team2 }
  })
}

/**
 * 점수 규칙 (서버 score_problem과 같은 규칙). 맞으면 null, 아니면 안내 문구
 *   이긴 팀 ≥ 목표, 목표에서 끝나면 2점 차 이상, 듀스 뒤엔 정확히 2점 차, 최대 점수에선 1점 차도 인정
 */
export function scoreProblem(target: number, cap: number | null, s1: number | null, s2: number | null): string | null {
  if (s1 === null || s2 === null || Number.isNaN(s1) || Number.isNaN(s2) || s1 < 0 || s2 < 0) return '두 팀 점수를 모두 넣어주세요'
  if (s1 === s2) return '동점으로는 끝날 수 없어요'
  const w = Math.max(s1, s2)
  const l = Math.min(s1, s2)
  if (w < target) return `이긴 팀이 ${target}점 이상이어야 해요`
  if (cap !== null && w > cap) return `최대 ${cap}점까지예요`
  if (w === target) return l > target - 2 ? `${target - 1}:${target - 1} 이후엔 2점을 앞서야 끝나요` : null
  if (w - l === 2) return null
  if (cap !== null && w === cap && w - l === 1) return null
  return cap !== null && w === cap ? `${cap}점에선 1~2점 차로 끝나요` : '듀스 뒤엔 2점을 앞서야 끝나요'
}

/** 이긴 팀 (점수 또는 기권승). 결과 없으면 null */
export function winnerOf(m: Pick<ScheduledMatch, 'score1' | 'score2' | 'result_kind'>): 1 | 2 | null {
  if (m.result_kind === 'walkover1') return 1
  if (m.result_kind === 'walkover2') return 2
  if (m.result_kind === 'normal' && m.score1 !== null && m.score2 !== null) return m.score1 > m.score2 ? 1 : 2
  return null
}
