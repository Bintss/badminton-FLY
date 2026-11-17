import { newDraft, type DraftMatch } from './tournament'

/**
 * 급수 글자 → 실력 점수 1~5. 모르는 급수·게스트는 중간값 3
 *   자강·S·A = 5, B = 4, C = 3, D = 2, 초심·입문·E·F = 1
 */
export function levelScore(level: string | null | undefined): number {
  const t = (level ?? '').trim().toUpperCase()
  if (!t) return 3
  if (/자강|^S|^A/.test(t)) return 5
  if (/^B/.test(t)) return 4
  if (/^C/.test(t)) return 3
  if (/^D/.test(t)) return 2
  if (/초심|입문|왕초|^E|^F/.test(t)) return 1
  return 3
}

/** 같은 시드면 같은 결과 (다시 짜기는 시드만 바꾼다) */
function rng(seed: number) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const pairKey = (a: string, b: string) => (a < b ? `${a}|${b}` : `${b}|${a}`)

/** 가중치: 파트너 반복을 가장 피하고, 그다음 팀 실력 차, 상대 반복, 한 경기 안의 실력 폭 */
const W = { partner: 12, balance: 3, opponent: 2, spread: 0.6 }

interface Ctx {
  score: Record<string, number>
  partners: Map<string, number>
  opponents: Map<string, number>
}

function matchCost(q: string[], ctx: Ctx): number {
  const [a, b, c, d] = q
  const s = ctx.score
  const pc = (x: string, y: string) => ctx.partners.get(pairKey(x, y)) ?? 0
  const oc = (x: string, y: string) => ctx.opponents.get(pairKey(x, y)) ?? 0
  const scores = [s[a], s[b], s[c], s[d]]
  return (
    W.partner * (pc(a, b) + pc(c, d)) +
    W.balance * Math.abs(s[a] + s[b] - s[c] - s[d]) +
    W.opponent * (oc(a, c) + oc(a, d) + oc(b, c) + oc(b, d)) +
    W.spread * (Math.max(...scores) - Math.min(...scores))
  )
}

/** 한 매치에 출전하는 4g명을 g경기로 묶는다. 무작위 시작 + 두 자리 맞바꾸기 국소 탐색, 여러 번 재시작 */
function arrangeRound(ids: string[], ctx: Ctx, rand: () => number): string[][] {
  const g = ids.length / 4
  const costOf = (arr: string[], m: number) => matchCost(arr.slice(m * 4, m * 4 + 4), ctx)
  let best: string[] = []
  let bestCost = Infinity
  for (let restart = 0; restart < 12; restart++) {
    const arr = [...ids]
    for (let i = arr.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1))
      ;[arr[i], arr[j]] = [arr[j], arr[i]]
    }
    const costs = Array.from({ length: g }, (_, m) => costOf(arr, m))
    let stale = 0
    while (stale < 400) {
      const i = Math.floor(rand() * arr.length)
      const j = Math.floor(rand() * arr.length)
      const mi = Math.floor(i / 4)
      const mj = Math.floor(j / 4)
      if (i === j) continue
      ;[arr[i], arr[j]] = [arr[j], arr[i]]
      const ci = costOf(arr, mi)
      const cj = mi === mj ? ci : costOf(arr, mj)
      const before = mi === mj ? costs[mi] : costs[mi] + costs[mj]
      const after = mi === mj ? ci : ci + cj
      if (after < before - 1e-9) {
        costs[mi] = ci
        costs[mj] = cj
        stale = 0
      } else {
        ;[arr[i], arr[j]] = [arr[j], arr[i]]
        stale++
      }
    }
    const total = costs.reduce((x, y) => x + y, 0)
    if (total < bestCost) {
      bestCost = total
      best = [...arr]
    }
  }
  return Array.from({ length: g }, (_, m) => best.slice(m * 4, m * 4 + 4))
}

/**
 * 자동 초안
 *   - 매치마다 min(코트 수, ⌊인원/4⌋)경기
 *   - 출전자: 지금까지 게임 수가 적은 사람부터 → 모두의 게임 수가 ±1 안에서 같다
 *     같으면 직전 매치에 쉰 사람 먼저 (연속 휴식 줄이기), 그다음 무작위
 *   - 묶기: 파트너 반복 최소, 두 팀 실력 합 비슷하게, 상대 반복·한 경기 안의 실력 폭 작게
 */
export function autoDraft(players: { id: string; score: number }[], rounds: number, courts: number, seed: number): DraftMatch[] {
  const n = players.length
  const g = Math.min(courts, Math.floor(n / 4))
  if (g <= 0 || rounds <= 0) return []
  const rand = rng(seed)
  const ctx: Ctx = { score: Object.fromEntries(players.map((p) => [p.id, p.score])), partners: new Map(), opponents: new Map() }
  const games: Record<string, number> = Object.fromEntries(players.map((p) => [p.id, 0]))
  const tiebreak: Record<string, number> = Object.fromEntries(players.map((p) => [p.id, rand()]))
  let restedLast = new Set<string>()
  const out: DraftMatch[] = []

  for (let r = 1; r <= rounds; r++) {
    for (const p of players) tiebreak[p.id] = rand()
    const order = [...players].sort(
      (a, b) =>
        games[a.id] - games[b.id] ||
        (restedLast.has(b.id) ? 1 : 0) - (restedLast.has(a.id) ? 1 : 0) ||
        tiebreak[a.id] - tiebreak[b.id],
    )
    const playing = order.slice(0, g * 4).map((p) => p.id)
    restedLast = new Set(order.slice(g * 4).map((p) => p.id))

    for (const q of arrangeRound(playing, ctx, rand)) {
      // 팀 안에서 순서 정리: 실력 높은 사람 먼저 (보기 편하게)
      const t1 = [q[0], q[1]].sort((x, y) => ctx.score[y] - ctx.score[x])
      const t2 = [q[2], q[3]].sort((x, y) => ctx.score[y] - ctx.score[x])
      const d = newDraft(r)
      d.team1 = [t1[0], t1[1]]
      d.team2 = [t2[0], t2[1]]
      out.push(d)
      for (const id of q) games[id] += 1
      for (const [x, y] of [[t1[0], t1[1]], [t2[0], t2[1]]]) ctx.partners.set(pairKey(x, y), (ctx.partners.get(pairKey(x, y)) ?? 0) + 1)
      for (const x of t1) for (const y of t2) ctx.opponents.set(pairKey(x, y), (ctx.opponents.get(pairKey(x, y)) ?? 0) + 1)
    }
  }
  return out
}

export interface MatchNote {
  /** 팀 실력 합 */
  sum1: number
  sum2: number
  /** 다른 경기에서도 같은 팀인 짝이 있음 */
  partnerRepeat: boolean
}

/** 편집 화면의 경기별 표시용. 4명이 다 찬 경기만 계산 */
export function draftNotes(drafts: DraftMatch[], scoreOf: (id: string) => number): Record<string, MatchNote> {
  const pairs = new Map<string, number>()
  const full = drafts.filter((d) => [...d.team1, ...d.team2].every(Boolean))
  for (const d of full) {
    for (const t of [d.team1, d.team2]) {
      const k = pairKey(t[0]!, t[1]!)
      pairs.set(k, (pairs.get(k) ?? 0) + 1)
    }
  }
  const notes: Record<string, MatchNote> = {}
  for (const d of full) {
    notes[d.key] = {
      sum1: scoreOf(d.team1[0]!) + scoreOf(d.team1[1]!),
      sum2: scoreOf(d.team2[0]!) + scoreOf(d.team2[1]!),
      partnerRepeat: [d.team1, d.team2].some((t) => (pairs.get(pairKey(t[0]!, t[1]!)) ?? 0) > 1),
    }
  }
  return notes
}
