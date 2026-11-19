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

export type Gender = 'M' | 'F'
/** 남복 / 여복 / 혼복(팀마다 남1·여1) */
export type GameKind = 'MD' | 'WD' | 'XD'
export const KIND_LABEL: Record<GameKind, string> = { MD: '남복', WD: '여복', XD: '혼복' }

/** 경기 안 자리별 성별: [팀1, 팀1, 팀2, 팀2] */
const LAYOUT: Record<GameKind, Gender[]> = { MD: ['M', 'M', 'M', 'M'], WD: ['F', 'F', 'F', 'F'], XD: ['M', 'F', 'M', 'F'] }

/** 4명 성별로 종목 판정. 한 명이라도 모르면 null, 규칙에 안 맞으면 'invalid' */
export function gameKind(g: (Gender | null | undefined)[]): GameKind | 'invalid' | null {
  if (g.length !== 4 || g.some((x) => !x)) return null
  const [a, b, c, d] = g
  if (g.every((x) => x === 'M')) return 'MD'
  if (g.every((x) => x === 'F')) return 'WD'
  if (a !== b && c !== d) return 'XD'
  return 'invalid'
}

const W_KIND = 4 // 같은 종목을 반복하면 붙는 비용 (골고루)

/**
 * 한 매치 묶기 (성별 모드). kinds대로 자리 성별이 정해지고, 같은 성별 자리끼리만 맞바꾸며 국소 탐색
 *   비용 = 기본 비용 + 각자 이 종목을 이미 한 횟수 × W_KIND
 */
function arrangeTyped(
  men: string[],
  women: string[],
  kinds: GameKind[],
  ctx: Ctx,
  kindHist: Record<string, Record<GameKind, number>>,
  rand: () => number,
): { cost: number; matches: string[][] } {
  const slots: Gender[] = kinds.flatMap((k) => LAYOUT[k])
  const costOf = (arr: string[], m: number) => {
    const q = arr.slice(m * 4, m * 4 + 4)
    return matchCost(q, ctx) + W_KIND * q.reduce((t, id) => t + kindHist[id][kinds[m]], 0)
  }
  let best: string[] = []
  let bestCost = Infinity
  for (let restart = 0; restart < 10; restart++) {
    const ms = shuffle([...men], rand)
    const ws = shuffle([...women], rand)
    const arr = slots.map((g) => (g === 'M' ? ms.pop()! : ws.pop()!))
    const costs = kinds.map((_, m) => costOf(arr, m))
    let stale = 0
    while (stale < 400) {
      const i = Math.floor(rand() * arr.length)
      const j = Math.floor(rand() * arr.length)
      if (i === j || slots[i] !== slots[j]) {
        stale++
        continue
      }
      const mi = Math.floor(i / 4)
      const mj = Math.floor(j / 4)
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
  return { cost: bestCost, matches: kinds.map((_, m) => best.slice(m * 4, m * 4 + 4)) }
}

function shuffle<T>(arr: T[], rand: () => number): T[] {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1))
    ;[arr[i], arr[j]] = [arr[j], arr[i]]
  }
  return arr
}

/**
 * 자동 초안
 *   - 매치마다 min(코트 수, ⌊인원/4⌋)경기
 *   - 출전자: 지금까지 게임 수가 적은 사람부터 → 모두의 게임 수가 ±1 안에서 같다
 *     같으면 직전 매치에 쉰 사람 먼저 (연속 휴식 줄이기), 그다음 무작위
 *   - 묶기: 파트너 반복 최소, 두 팀 실력 합 비슷하게, 상대 반복·한 경기 안의 실력 폭 작게
 *   - 성별 모드(모두 성별이 있을 때): 모든 경기가 남복·여복·혼복 중 하나.
 *     출전 남녀 수가 각각 짝수가 되게 출전자를 고르고(필요하면 우선순위가 가장 가까운 사람끼리 맞바꿈),
 *     가능한 종목 조합을 모두 시도해 비용이 가장 낮은 것을 고른다. 같은 종목만 하는 사람이 없게 종목 반복에 비용
 */
export function autoDraft(
  players: { id: string; score: number; gender?: Gender | null }[],
  rounds: number,
  courts: number,
  seed: number,
): DraftMatch[] {
  const n = players.length
  const gMax = Math.min(courts, Math.floor(n / 4))
  if (gMax <= 0 || rounds <= 0) return []
  const typed = players.every((p) => p.gender)
  const genderOf: Record<string, Gender | null | undefined> = Object.fromEntries(players.map((p) => [p.id, p.gender]))
  const rand = rng(seed)
  const ctx: Ctx = { score: Object.fromEntries(players.map((p) => [p.id, p.score])), partners: new Map(), opponents: new Map() }
  const games: Record<string, number> = Object.fromEntries(players.map((p) => [p.id, 0]))
  const kindHist: Record<string, Record<GameKind, number>> = Object.fromEntries(players.map((p) => [p.id, { MD: 0, WD: 0, XD: 0 }]))
  const tiebreak: Record<string, number> = {}
  let restedLast = new Set<string>()
  const out: DraftMatch[] = []

  for (let r = 1; r <= rounds; r++) {
    for (const p of players) tiebreak[p.id] = rand()
    const order = [...players]
      .sort(
        (a, b) =>
          games[a.id] - games[b.id] ||
          (restedLast.has(b.id) ? 1 : 0) - (restedLast.has(a.id) ? 1 : 0) ||
          tiebreak[a.id] - tiebreak[b.id],
      )
      .map((p) => p.id)

    let playing: string[] = []
    let quads: string[][] = []
    let kinds: (GameKind | null)[] = []

    if (!typed) {
      playing = order.slice(0, gMax * 4)
      quads = arrangeRound(playing, ctx, rand)
      kinds = quads.map(() => null)
    } else {
      // 남녀 각각 짝수가 되는 출전자 고르기. 안 되면 경기 수를 줄인다
      for (let g = gMax; g >= 1 && playing.length === 0; g--) {
        const sel = order.slice(0, g * 4)
        const rest = order.slice(g * 4)
        const men = sel.filter((id) => genderOf[id] === 'M').length
        if (men % 2 === 0) {
          playing = sel
          break
        }
        // 출전자 중 한 명과 쉬는 사람 중 성별이 다른 한 명을 맞바꾼다. 우선순위 차이가 가장 작은 쌍으로
        let bestSwap: [number, number] | null = null
        let bestGap = Infinity
        for (let si = 0; si < sel.length; si++) {
          for (let ri = 0; ri < rest.length; ri++) {
            if (genderOf[sel[si]] === genderOf[rest[ri]]) continue
            const gap = g * 4 + ri - si
            if (gap < bestGap) {
              bestGap = gap
              bestSwap = [si, ri]
            }
          }
        }
        if (bestSwap) {
          const [si, ri] = bestSwap
          ;[sel[si], rest[ri]] = [rest[ri], sel[si]]
          playing = sel
        }
      }
      const men = playing.filter((id) => genderOf[id] === 'M')
      const women = playing.filter((id) => genderOf[id] === 'F')
      const g = playing.length / 4
      let best: { cost: number; matches: string[][]; kinds: GameKind[] } | null = null
      for (let b = (men.length / 2) % 2; b <= Math.min(men.length, women.length) / 2; b += 2) {
        const a = (men.length - 2 * b) / 4
        const c = (women.length - 2 * b) / 4
        if (a < 0 || c < 0 || a + b + c !== g) continue
        const ks: GameKind[] = [...Array(a).fill('MD'), ...Array(b).fill('XD'), ...Array(c).fill('WD')]
        const res = arrangeTyped(men, women, ks, ctx, kindHist, rand)
        if (!best || res.cost < best.cost) best = { ...res, kinds: ks }
      }
      if (best) {
        quads = best.matches
        kinds = best.kinds
      }
    }
    const playingSet = new Set(quads.flat())
    restedLast = new Set(order.filter((id) => !playingSet.has(id)))

    quads.forEach((q, mi) => {
      // 팀 안 순서: 혼복은 남자 먼저, 그 외는 실력 높은 사람 먼저 (보기 편하게)
      const sortTeam = (t: string[]) =>
        kinds[mi] === 'XD' ? [...t].sort((x) => (genderOf[x] === 'M' ? -1 : 1)) : [...t].sort((x, y) => ctx.score[y] - ctx.score[x])
      const t1 = sortTeam([q[0], q[1]])
      const t2 = sortTeam([q[2], q[3]])
      const d = newDraft(r)
      d.team1 = [t1[0], t1[1]]
      d.team2 = [t2[0], t2[1]]
      out.push(d)
      for (const id of q) {
        games[id] += 1
        const k = kinds[mi]
        if (k) kindHist[id][k] += 1
      }
      for (const [x, y] of [[t1[0], t1[1]], [t2[0], t2[1]]]) ctx.partners.set(pairKey(x, y), (ctx.partners.get(pairKey(x, y)) ?? 0) + 1)
      for (const x of t1) for (const y of t2) ctx.opponents.set(pairKey(x, y), (ctx.opponents.get(pairKey(x, y)) ?? 0) + 1)
    })
  }
  return out
}

export interface MatchNote {
  /** 종목. 성별을 모르는 사람이 있으면 null, 규칙에 안 맞으면 'invalid' */
  kind: GameKind | 'invalid' | null
  /** 팀 실력 합 */
  sum1: number
  sum2: number
  /** 다른 경기에서도 같은 팀인 짝이 있음 */
  partnerRepeat: boolean
}

/** 편집 화면의 경기별 표시용. 4명이 다 찬 경기만 계산 */
export function draftNotes(
  drafts: DraftMatch[],
  scoreOf: (id: string) => number,
  genderOf: (id: string) => Gender | null = () => null,
): Record<string, MatchNote> {
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
      kind: gameKind([d.team1[0]!, d.team1[1]!, d.team2[0]!, d.team2[1]!].map(genderOf)),
      sum1: scoreOf(d.team1[0]!) + scoreOf(d.team1[1]!),
      sum2: scoreOf(d.team2[0]!) + scoreOf(d.team2[1]!),
      partnerRepeat: [d.team1, d.team2].some((t) => (pairs.get(pairKey(t[0]!, t[1]!)) ?? 0) > 1),
    }
  }
  return notes
}

/**
 * 교류전 자동 초안: 모든 경기가 주최 2명(팀1) vs 상대 2명(팀2)
 *   - 매치마다 min(코트 수, ⌊주최 인원/2⌋, ⌊상대 인원/2⌋)경기
 *   - 편마다 게임 수가 적은 사람부터 (같으면 직전에 쉰 사람, 그다음 무작위) → 편 안에서 게임 수가 ±1
 *   - 묶기 비용은 자체대회와 같고, 자리 맞바꾸기는 같은 편(성별 모드면 같은 편·같은 성별)끼리만
 *   - 성별 모드(두 편 모두 성별이 있을 때): 경기마다 남복·여복·혼복, 두 편이 같은 종목.
 *     가능한 종목 조합 중 우선순위가 높은 사람을 가장 많이 쓰는 조합을 고르고, 같으면 비용이 낮은 쪽
 */
export function autoDraftExchange(
  home: { id: string; score: number; gender?: Gender | null }[],
  away: { id: string; score: number; gender?: Gender | null }[],
  rounds: number,
  courts: number,
  seed: number,
): DraftMatch[] {
  const gMax = Math.min(courts, Math.floor(home.length / 2), Math.floor(away.length / 2))
  if (gMax <= 0 || rounds <= 0) return []
  const all = [...home, ...away]
  const typed = all.every((p) => p.gender)
  const genderOf: Record<string, Gender | null | undefined> = Object.fromEntries(all.map((p) => [p.id, p.gender]))
  const rand = rng(seed)
  const ctx: Ctx = { score: Object.fromEntries(all.map((p) => [p.id, p.score])), partners: new Map(), opponents: new Map() }
  const games: Record<string, number> = Object.fromEntries(all.map((p) => [p.id, 0]))
  const kindHist: Record<string, Record<GameKind, number>> = Object.fromEntries(all.map((p) => [p.id, { MD: 0, WD: 0, XD: 0 }]))
  const tiebreak: Record<string, number> = {}
  let restedLast = new Set<string>()
  const out: DraftMatch[] = []

  const orderOf = (side: { id: string }[]) =>
    [...side]
      .sort(
        (a, b) =>
          games[a.id] - games[b.id] ||
          (restedLast.has(b.id) ? 1 : 0) - (restedLast.has(a.id) ? 1 : 0) ||
          tiebreak[a.id] - tiebreak[b.id],
      )
      .map((p) => p.id)

  /** 자리마다 반(같은 반끼리만 맞바꿈)이 정해진 배열을 국소 탐색으로 묶는다 */
  const arrange = (pools: Record<string, string[]>, classes: string[], kinds: (GameKind | null)[]) => {
    const g = kinds.length
    const costOf = (arr: string[], m: number) => {
      const q = arr.slice(m * 4, m * 4 + 4)
      const k = kinds[m]
      return matchCost(q, ctx) + (k ? W_KIND * q.reduce((t, id) => t + kindHist[id][k], 0) : 0)
    }
    let best: string[] = []
    let bestCost = Infinity
    for (let restart = 0; restart < 10; restart++) {
      const bags = Object.fromEntries(Object.entries(pools).map(([k, v]) => [k, shuffle([...v], rand)]))
      const arr = classes.map((c) => bags[c].pop()!)
      const costs = Array.from({ length: g }, (_, m) => costOf(arr, m))
      let stale = 0
      while (stale < 400) {
        const i = Math.floor(rand() * arr.length)
        const j = Math.floor(rand() * arr.length)
        if (i === j || classes[i] !== classes[j]) {
          stale++
          continue
        }
        const mi = Math.floor(i / 4)
        const mj = Math.floor(j / 4)
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
    return { cost: bestCost, quads: Array.from({ length: g }, (_, m) => best.slice(m * 4, m * 4 + 4)) }
  }

  for (let r = 1; r <= rounds; r++) {
    for (const p of all) tiebreak[p.id] = rand()
    const oH = orderOf(home)
    const oA = orderOf(away)
    let quads: string[][] = []
    let kinds: (GameKind | null)[] = []

    if (!typed) {
      const g = gMax
      kinds = Array(g).fill(null)
      const classes = Array.from({ length: g }, () => ['H', 'H', 'A', 'A']).flat()
      quads = arrange({ H: oH.slice(0, 2 * g), A: oA.slice(0, 2 * g) }, classes, kinds).quads
    } else {
      // 종목 조합(남복 a, 혼복 b, 여복 c) 후보: 편마다 남 2a+b명, 여 2c+b명이 필요
      let pick: { rank: number; cost: number; quads: string[][]; kinds: GameKind[] } | null = null
      for (let g = gMax; g >= 1 && !pick; g--) {
        for (let a = 0; a <= g; a++) {
          for (let b = 0; a + b <= g; b++) {
            const c = g - a - b
            const need = { M: 2 * a + b, F: 2 * c + b }
            const sel = (order: string[]) => {
              const men = order.filter((id) => genderOf[id] === 'M').slice(0, need.M)
              const women = order.filter((id) => genderOf[id] === 'F').slice(0, need.F)
              return men.length === need.M && women.length === need.F ? { men, women } : null
            }
            const sH = sel(oH)
            const sA = sel(oA)
            if (!sH || !sA) continue
            // 우선순위: 뽑힌 사람의 순번 합이 작을수록 게임 수가 고르다
            const rank = [...sH.men, ...sH.women].reduce((t, id) => t + oH.indexOf(id), 0) +
              [...sA.men, ...sA.women].reduce((t, id) => t + oA.indexOf(id), 0)
            if (pick && rank > pick.rank) continue
            const ks: GameKind[] = [...Array(a).fill('MD'), ...Array(b).fill('XD'), ...Array(c).fill('WD')]
            const classes = ks.flatMap((k) => {
              const [g1, g2, g3, g4] = LAYOUT[k]
              return [`H${g1}`, `H${g2}`, `A${g3}`, `A${g4}`]
            })
            const res = arrange({ HM: sH.men, HF: sH.women, AM: sA.men, AF: sA.women }, classes, ks)
            if (!pick || rank < pick.rank || res.cost < pick.cost) pick = { rank, cost: res.cost, quads: res.quads, kinds: ks }
          }
        }
      }
      if (pick) {
        quads = pick.quads
        kinds = pick.kinds
      }
    }

    const playingSet = new Set(quads.flat())
    restedLast = new Set(all.map((p) => p.id).filter((id) => !playingSet.has(id)))

    quads.forEach((q, mi) => {
      const sortTeam = (t: string[]) =>
        kinds[mi] === 'XD' ? [...t].sort((x) => (genderOf[x] === 'M' ? -1 : 1)) : [...t].sort((x, y) => ctx.score[y] - ctx.score[x])
      const t1 = sortTeam([q[0], q[1]])
      const t2 = sortTeam([q[2], q[3]])
      const d = newDraft(r)
      d.team1 = [t1[0], t1[1]]
      d.team2 = [t2[0], t2[1]]
      out.push(d)
      for (const id of q) {
        games[id] += 1
        const k = kinds[mi]
        if (k) kindHist[id][k] += 1
      }
      for (const [x, y] of [[t1[0], t1[1]], [t2[0], t2[1]]]) ctx.partners.set(pairKey(x, y), (ctx.partners.get(pairKey(x, y)) ?? 0) + 1)
      for (const x of t1) for (const y of t2) ctx.opponents.set(pairKey(x, y), (ctx.opponents.get(pairKey(x, y)) ?? 0) + 1)
    })
  }
  return out
}
