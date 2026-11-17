import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { ConfirmButton } from '../components/ConfirmButton'
import { Field, Input } from '../components/form'
import { ScoreCapField } from '../components/ScoreCapField'
import { IconChevronLeft, IconPlus, IconX } from '../components/icons'
import { ScoreSheet, type ScoreKind } from '../components/ScoreSheet'
import { Sheet } from '../components/Sheet'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, List, Page, SectionTitle, Skeleton } from '../components/ui'
import { KIND_LABEL, autoDraft, draftNotes, gameKind, levelScore, type Gender, type GameKind } from '../lib/autoDraft'
import { GenderMark, GenderToggle } from '../components/GenderToggle'
import { errorMessage, supabase } from '../lib/supabase'
import {
  SCHEDULED_COLUMNS,
  STATE_LABEL,
  blockReason,
  checkDrafts,
  draftPlayers,
  draftsFromMatches,
  newDraft,
  planEstimate,
  teamsOf,
  toSchedulePayload,
  tournamentActive,
  winnerOf,
  type DraftMatch,
  type PlayerState,
  type ScheduledMatch,
} from '../lib/tournament'
import type { RegistrationStatus, SessionOverview } from '../lib/types'

interface Reg {
  id: string
  kind: 'member' | 'guest'
  user_id: string | null
  guest_name: string | null
  guest_gender: Gender | null
  status: RegistrationStatus
  seq: number
  checked_in_at: string | null
  profiles: { display_name: string } | null
}

interface MatchWithPhase extends ScheduledMatch {
  phase: 'free' | 'scheduled'
}

interface Roster {
  /** 참석 확정자, 신청 순 */
  confirmed: Reg[]
  nameOf: (id: string) => string
  levelOf: (id: string) => string | undefined
  /** 급수 글자로 정한 실력 점수 1~5 (게스트·모르는 급수 3) */
  scoreOf: (id: string) => number
  genderOf: (id: string) => Gender | null
  /** 회원은 동아리 성별, 게스트는 신청의 성별을 바꾼다 (운영진) */
  setGender: (id: string, g: Gender | null) => Promise<void>
  isConfirmed: (id: string) => boolean
}

export default function TournamentPage() {
  const { sessionId } = useParams()
  const { club, isAdmin } = useClub()
  const { session: auth } = useAuth()
  const toast = useToast()
  const uid = auth?.user.id

  const [s, setS] = useState<SessionOverview | null>(null)
  const [regs, setRegs] = useState<Reg[]>([])
  const [matches, setMatches] = useState<MatchWithPhase[]>([])
  const [levels, setLevels] = useState<Record<string, string>>({})
  const [genders, setGenders] = useState<Record<string, Gender>>({})
  const [loaded, setLoaded] = useState(false)

  const load = useCallback(async () => {
    if (!sessionId) return
    const [ov, rs, ms] = await Promise.all([
      supabase.from('session_overview').select('*').eq('id', sessionId).maybeSingle(),
      supabase
        .from('registrations')
        .select('id, kind, user_id, guest_name, guest_gender, status, seq, checked_in_at, profiles!registrations_user_id_fkey(display_name)')
        .eq('session_id', sessionId)
        .order('seq'),
      // 대회 경기 전부 + (다른 코트에서 경기 중인지 알기 위해) 진행 중인 자율 경기
      supabase
        .from('matches')
        .select(`phase, ${SCHEDULED_COLUMNS}`)
        .eq('session_id', sessionId)
        .or('phase.eq.scheduled,status.eq.playing')
        .order('round_no')
        .order('order_no'),
    ])
    const err = ov.error ?? rs.error ?? ms.error
    if (err) toast.error(errorMessage(err))
    setS((ov.data as SessionOverview | null) ?? null)
    setRegs((rs.data as unknown as Reg[] | null) ?? [])
    setMatches((ms.data as unknown as MatchWithPhase[] | null) ?? [])
    setLoaded(true)
  }, [sessionId, toast])

  useEffect(() => {
    void load()
  }, [load])

  const loadMembers = useCallback(async () => {
    const { data } = await supabase.from('club_members').select('user_id, level, gender').eq('club_id', club.id).eq('status', 'approved')
    const lv: Record<string, string> = {}
    const gd: Record<string, Gender> = {}
    for (const m of data ?? []) {
      if (m.level) lv[m.user_id as string] = m.level as string
      if (m.gender) gd[m.user_id as string] = m.gender as Gender
    }
    setLevels(lv)
    setGenders(gd)
  }, [club.id])
  useEffect(() => {
    void loadMembers()
  }, [loadMembers])

  const reloadTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (!sessionId) return
    const schedule = () => {
      if (reloadTimer.current) return
      reloadTimer.current = setTimeout(() => {
        reloadTimer.current = null
        void load()
      }, 400 + Math.random() * 600)
    }
    const channel = supabase
      .channel(`tournament:${sessionId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'matches', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'registrations', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'sessions', filter: `id=eq.${sessionId}` }, schedule)
      .subscribe()
    return () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current)
      reloadTimer.current = null
      void supabase.removeChannel(channel)
    }
  }, [sessionId, load])

  const roster: Roster = useMemo(() => {
    const byId = Object.fromEntries(regs.map((r) => [r.id, r]))
    return {
      confirmed: regs.filter((r) => r.status === 'confirmed'),
      nameOf: (id) => {
        const r = byId[id]
        return r ? (r.guest_name ?? r.profiles?.display_name ?? '이름 없음') : '?'
      },
      levelOf: (id) => {
        const u = byId[id]?.user_id
        return u ? levels[u] : undefined
      },
      isConfirmed: (id) => byId[id]?.status === 'confirmed',
      scoreOf: (id) => {
        const u = byId[id]?.user_id
        return levelScore(u ? levels[u] : null)
      },
      genderOf: (id) => {
        const r = byId[id]
        if (!r) return null
        return r.kind === 'guest' ? r.guest_gender : r.user_id ? (genders[r.user_id] ?? null) : null
      },
      setGender: async (id, g) => {
        const r = byId[id]
        if (!r) return
        const { error } =
          r.kind === 'guest'
            ? await supabase.rpc('set_guest_gender', { p_registration: id, p_gender: g })
            : await supabase.rpc('set_member_gender', { p_club: club.id, p_user: r.user_id, p_gender: g })
        if (error) toast.error(errorMessage(error))
        await Promise.all([load(), loadMembers()])
      },
    }
  }, [regs, levels, genders, club.id, toast, load, loadMembers])

  const scheduled = useMemo(() => matches.filter((m) => m.phase === 'scheduled'), [matches])

  const back = (
    <Link to={`/c/${club.id}/s/${sessionId}`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      {s?.title ?? '일정'}
    </Link>
  )

  if (!loaded) {
    return (
      <Page back={back}>
        <Skeleton className="h-7 w-32" />
        <Skeleton className="mt-4 h-48 w-full rounded-2xl" />
      </Page>
    )
  }
  if (!s) return <Page back={back}><Empty title="운동을 찾을 수 없어요" /></Page>

  const state = s.tournament_state
  const myRegId = regs.find((r) => r.kind === 'member' && r.user_id === uid && r.status !== 'canceled')?.id ?? null
  const showSchedule = s.kind === 'tournament' && state && state !== 'draft'

  return (
    <Page back={back} wide={state === 'draft' && isAdmin}>
      <div className="mb-4">
        <div className="flex items-center gap-2">
          <Badge tone="court">자체대회</Badge>
          {state && <span className={`text-[13px] font-bold ${state === 'in_progress' ? 'text-court-600' : 'text-ink-soft'}`}>{STATE_LABEL[state]}</span>}
        </div>
        <h1 className="mt-1 text-[24px] font-bold leading-tight tracking-tight text-ink">{s.title}</h1>
      </div>

      {s.canceled_at && <p className="mb-3 rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">취소된 운동이에요.</p>}

      {s.kind !== 'tournament' ? (
        <Empty title="자체대회가 아닌 운동이에요">자체대회는 일정 화면의 자체대회 버튼으로 따로 만들어요.</Empty>
      ) : (
        !isAdmin && !showSchedule && <Empty title="아직 대진이 공개되지 않았어요">운영진이 대진을 확정하면 여기에 바로 보여요.</Empty>
      )}

      {isAdmin && s.kind === 'tournament' && !s.canceled_at && <SettingsCard s={s} players={roster.confirmed.length} onChanged={load} />}

      {isAdmin && s.kind === 'tournament' && state === 'draft' && !s.canceled_at && (
        <ScheduleEditor s={s} roster={roster} matches={scheduled} onChanged={load} />
      )}

      {showSchedule && (
        <ScheduleView s={s} roster={roster} regs={regs} matches={matches} myRegId={myRegId} isAdmin={isAdmin} onChanged={load} />
      )}
    </Page>
  )
}

// ---------------------------------------------------------------------
// 대회 설정 (운영진). 대회 켜고 끄기는 없음: 자체대회는 처음부터 따로 만든다
// ---------------------------------------------------------------------
function SettingsCard({ s, players, onChanged }: { s: SessionOverview; players: number; onChanged: () => Promise<void> }) {
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [rounds, setRounds] = useState(String(s.round_count ?? 5))
  const [target, setTarget] = useState(String(s.score_target))
  const [capOn, setCapOn] = useState(s.score_cap !== null)
  const [cap, setCap] = useState(String(s.score_cap ?? Math.min(60, s.score_target + 5)))
  const [minutes, setMinutes] = useState(String(s.minutes_per_game))
  const [busy, setBusy] = useState(false)

  // 다른 운영진이 바꾸면 화면도 따라간다
  useEffect(() => {
    setRounds(String(s.round_count ?? 5))
    setTarget(String(s.score_target))
    setCapOn(s.score_cap !== null)
    setCap(String(s.score_cap ?? Math.min(60, s.score_target + 5)))
    setMinutes(String(s.minutes_per_game))
  }, [s.round_count, s.score_target, s.score_cap, s.minutes_per_game])

  const draft = s.tournament_state === 'draft'
  const n = (v: string) => Number.parseInt(v, 10)
  const est = planEstimate(players, s.court_count, s.round_count ?? 0, s.minutes_per_game)

  const save = async () => {
    setBusy(true)
    const { error } = await supabase.rpc('save_tournament_settings', {
      p_session: s.id,
      p_round_count: n(rounds),
      p_score_target: n(target),
      p_score_cap: capOn ? n(cap) : null,
      p_minutes_per_game: n(minutes),
    })
    setBusy(false)
    if (error) toast.error(errorMessage(error))
    else {
      toast.success('대회 설정을 저장했어요')
      setOpen(false)
    }
    await onChanged()
  }

  if (s.tournament_state === 'finished') return null

  return (
    <Card className="mb-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-[15px] font-bold text-ink">대회 설정</h2>
          <p className="mt-1 text-[13px] leading-relaxed text-ink-soft">
            {s.round_count}매치, {s.score_target}점{s.score_cap ? `(최대 ${s.score_cap}점)` : ''}, 경기당 {s.minutes_per_game}분. 참석 {players}명, 코트{' '}
            {s.court_count}면이면 매치마다 {est.perRound}경기{est.restPerRound > 0 && `(${est.restPerRound}명 휴식)`}, 한 사람당 평균{' '}
            {est.avgPerPlayer.toFixed(1)}게임, 약 {est.minutes}분이에요.
          </p>
        </div>
        <button type="button" onClick={() => setOpen((v) => !v)} className="h-9 shrink-0 rounded-lg px-3 text-sm font-semibold text-court-600 active:bg-court-50">
          {open ? '닫기' : '바꾸기'}
        </button>
      </div>

      {open && (
        <div className="mt-4 space-y-4 border-t border-black/[0.06] pt-4">
          <div className="grid grid-cols-2 gap-3">
            <Field label="매치 수" hint={!draft ? '확정 후 변경 불가' : undefined}>
              <Input type="number" inputMode="numeric" min={1} max={20} value={rounds} disabled={!draft} onChange={(e) => setRounds(e.target.value)} />
            </Field>
            <Field label="경기당 시간 (분)">
              <Input type="number" inputMode="numeric" min={5} max={60} value={minutes} onChange={(e) => setMinutes(e.target.value)} />
            </Field>
            <Field label="목표 점수">
              <Input type="number" inputMode="numeric" min={5} max={50} value={target} onChange={(e) => setTarget(e.target.value)} />
            </Field>
            <ScoreCapField capOn={capOn} setCapOn={setCapOn} cap={cap} setCap={setCap} />
          </div>
          <Button className="w-full" disabled={busy} onClick={() => void save()}>
            설정 저장
          </Button>
        </div>
      )}
    </Card>
  )
}

// ---------------------------------------------------------------------
// 대진 짜기 (운영진, 확정 전): 자동 초안 + 탭 두 번으로 자리 바꾸기
// ---------------------------------------------------------------------
/** 편집 중 고른 자리: 경기의 한 칸 또는 쉬는 사람 */
type Pos = { kind: 'slot'; key: string; team: 1 | 2; idx: 0 | 1 } | { kind: 'bench'; id: string }

const samePos = (a: Pos | null, b: Pos) =>
  !!a && (a.kind === 'bench' ? b.kind === 'bench' && a.id === b.id : b.kind === 'slot' && a.key === b.key && a.team === b.team && a.idx === b.idx)

function withEmptyRounds(drafts: DraftMatch[], rounds: number, perRound: number): DraftMatch[] {
  const out = [...drafts]
  for (let r = 1; r <= rounds; r++) {
    if (!out.some((d) => d.round === r)) for (let i = 0; i < perRound; i++) out.push(newDraft(r))
  }
  return out
}

function ScheduleEditor({ s, roster, matches, onChanged }: { s: SessionOverview; roster: Roster; matches: ScheduledMatch[]; onChanged: () => Promise<void> }) {
  const toast = useToast()
  const rounds = s.round_count ?? 0
  const perRound = Math.max(1, Math.min(s.court_count, Math.floor(roster.confirmed.length / 4)))
  const [drafts, setDrafts] = useState<DraftMatch[]>(() => withEmptyRounds(draftsFromMatches(matches), rounds, perRound))
  const [dirty, setDirty] = useState(false)
  const [round, setRound] = useState(1)
  const [sel, setSel] = useState<Pos | null>(null)
  const [busy, setBusy] = useState(false)

  // 저장 안 한 변경이 없을 때만 서버 내용(다른 운영진의 저장)으로 맞춘다
  useEffect(() => {
    if (!dirty) setDrafts(withEmptyRounds(draftsFromMatches(matches), rounds, perRound))
  }, [matches, rounds, perRound, dirty])
  useEffect(() => {
    if (round > rounds) setRound(Math.max(1, rounds))
  }, [round, rounds])

  const confirmedIds = useMemo(() => roster.confirmed.map((r) => r.id), [roster.confirmed])
  const check = checkDrafts(drafts, confirmedIds, rounds)
  const notes = draftNotes(drafts, roster.scoreOf, roster.genderOf)
  const noGender = roster.confirmed.filter((p) => !roster.genderOf(p.id))
  const anyGender = roster.confirmed.some((p) => roster.genderOf(p.id))
  const blocked = check.partial > 0 || check.outOfRange > 0 || check.stale > 0
  const blockedText =
    check.stale > 0
      ? `참석을 취소한 사람이 든 경기가 ${check.stale}개 있어요. 빨간 이름을 바꿔주세요.`
      : check.partial > 0
        ? `4명을 다 채우지 않은 경기가 ${check.partial}개 있어요. 채우거나 지워주세요.`
        : check.outOfRange > 0
          ? `매치 수보다 뒤에 있는 경기가 ${check.outOfRange}개 있어요.`
          : null
  const hasAnyone = drafts.some((d) => draftPlayers(d).length > 0)

  const update = (fn: (ds: DraftMatch[]) => DraftMatch[]) => {
    setDrafts(fn)
    setDirty(true)
  }

  const generate = () => {
    if (anyGender && noGender.length > 0) {
      toast.error(`성별이 없는 ${noGender.length}명의 성별을 먼저 정해주세요`)
      return
    }
    const players = roster.confirmed.map((p) => ({ id: p.id, score: roster.scoreOf(p.id), gender: roster.genderOf(p.id) }))
    const next = autoDraft(players, rounds, s.court_count, Math.floor(Math.random() * 2 ** 31))
    if (next.length === 0) {
      toast.error('참석자가 4명 이상이어야 대진을 짤 수 있어요')
      return
    }
    setSel(null)
    update(() => withEmptyRounds(next, rounds, perRound))
    const played = new Set(next.flatMap(draftPlayers))
    const zero = roster.confirmed.filter((p) => !played.has(p.id))
    if (zero.length > 0)
      toast.info(`${zero.map((p) => roster.nameOf(p.id)).join(', ')}님은 성별 인원이 맞지 않아 경기가 없어요. 직접 넣어주세요`)
    else toast.success(`${next.length}경기를 짰어요. 바꿀 사람은 눌러서 자리를 바꾸세요`)
  }

  const slotValue = (ds: DraftMatch[], p: Extract<Pos, { kind: 'slot' }>) => {
    const d = ds.find((x) => x.key === p.key)
    return d ? (p.team === 1 ? d.team1 : d.team2)[p.idx] : null
  }
  const writeSlot = (ds: DraftMatch[], p: Extract<Pos, { kind: 'slot' }>, id: string | null) =>
    ds.map((d) => {
      if (d.key !== p.key) return d
      const team = [...(p.team === 1 ? d.team1 : d.team2)] as [string | null, string | null]
      team[p.idx] = id
      return p.team === 1 ? { ...d, team1: team } : { ...d, team2: team }
    })

  /** 첫 탭은 고르기, 두 번째 탭은 두 자리 맞바꾸기. 쉬는 사람과 바꾸면 원래 있던 사람이 쉬는 사람이 된다 */
  const tap = (p: Pos) => {
    if (!sel) return setSel(p)
    if (samePos(sel, p)) return setSel(null)
    if (sel.kind === 'bench' && p.kind === 'bench') return setSel(p)
    const a = sel
    setSel(null)
    update((ds) => {
      if (a.kind === 'slot' && p.kind === 'slot') {
        const va = slotValue(ds, a)
        const vb = slotValue(ds, p)
        return writeSlot(writeSlot(ds, a, vb), p, va)
      }
      if (a.kind === 'slot' && p.kind === 'bench') return writeSlot(ds, a, p.id)
      if (a.kind === 'bench' && p.kind === 'slot') return writeSlot(ds, p, a.id)
      return ds
    })
  }

  const save = async (andPublish: boolean) => {
    setBusy(true)
    if (dirty || andPublish) {
      const { error } = await supabase.rpc('save_schedule', { p_session: s.id, p_matches: toSchedulePayload(check.complete) })
      if (error) {
        setBusy(false)
        toast.error(errorMessage(error))
        return
      }
      setDirty(false)
    }
    if (andPublish) {
      const { error } = await supabase.rpc('publish_schedule', { p_session: s.id })
      if (error) toast.error(errorMessage(error))
      else toast.success('대진을 확정했어요. 참가자들에게 바로 보여요')
    } else toast.success(`대진 ${check.complete.length}경기를 저장했어요`)
    setBusy(false)
    await onChanged()
  }

  if (rounds === 0) return <Empty title="매치 수를 먼저 정해주세요" />

  const ds = drafts.filter((d) => d.round === round)
  const inRound = new Set(ds.flatMap(draftPlayers))
  const bench = roster.confirmed.filter((p) => !inRound.has(p.id))
  const prevInRound = new Set(drafts.filter((d) => d.round === round - 1).flatMap(draftPlayers))
  const restedBefore = round > 1 && drafts.some((d) => d.round === round - 1 && draftPlayers(d).length > 0)
  const selName = sel ? (sel.kind === 'bench' ? roster.nameOf(sel.id) : slotValue(drafts, sel) ? roster.nameOf(slotValue(drafts, sel)!) : '빈 자리') : null

  const roundIssue = (r: number) =>
    drafts.some(
      (d) =>
        d.round === r &&
        ((notes[d.key]?.partnerRepeat ?? false) || notes[d.key]?.kind === 'invalid' || (draftPlayers(d).length > 0 && draftPlayers(d).length < 4)),
    )

  return (
    <>
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-[18px] font-bold text-ink">대진 짜기</h2>
        {hasAnyone ? (
          <ConfirmButton
            label="자동으로 다시 짜기"
            confirmLabel="지금 대진을 덮어써요. 한 번 더"
            className="h-10 border border-black/10 bg-white px-3 text-sm text-ink"
            armedClassName="h-10 bg-ink px-3 text-sm text-white"
            disabled={busy}
            onConfirm={generate}
          />
        ) : (
          <Button className="h-10 px-4 text-sm" disabled={busy} onClick={generate}>
            자동으로 짜기
          </Button>
        )}
      </div>

      {!hasAnyone && (
        <p className="mb-4 rounded-xl bg-floor px-3 py-3 text-[13px] leading-relaxed text-ink-soft">
          자동으로 짜기를 누르면 참석자 {roster.confirmed.length}명의 게임 수를 똑같이 맞추고, 같은 파트너를 피하고, 급수로 두 팀 실력을 맞춘 대진을
          만들어요. 성별이 있으면 모든 경기를 혼복·남복·여복 중 하나로, 한 사람이 같은 종목만 하지 않게 골고루 섞어요. 직접 짜려면 빈 자리를 누르고 아래
          쉬는 사람을 누르세요.
        </p>
      )}

      {anyGender && noGender.length > 0 && (
        <Card className="mb-4">
          <h3 className="text-[15px] font-bold text-ink">성별이 없는 참석자 {noGender.length}명</h3>
          <p className="mt-1 text-[13px] text-ink-soft">혼복·남복·여복을 맞추려면 모두 성별이 있어야 해요. 여기서 정하면 회원 정보에도 저장돼요.</p>
          <div className="mt-2 divide-y divide-black/[0.06]">
            {noGender.map((p) => (
              <div key={p.id} className="flex items-center justify-between gap-2 py-2">
                <span className="truncate text-[15px] font-semibold text-ink">
                  {roster.nameOf(p.id)}
                  {p.kind === 'guest' && <span className="ml-1 text-xs font-medium text-ink-faint">게스트</span>}
                </span>
                <GenderToggle compact value={null} allowClear={false} label={`${roster.nameOf(p.id)} 성별`} onChange={(g) => void roster.setGender(p.id, g)} />
              </div>
            ))}
          </div>
        </Card>
      )}

      {/* 매치 탭 */}
      <div className="-mx-4 mb-3 flex gap-1.5 overflow-x-auto px-4 pb-1" role="tablist">
        {Array.from({ length: rounds }, (_, i) => i + 1).map((r) => {
          const full = drafts.filter((d) => d.round === r && draftPlayers(d).length === 4).length
          return (
            <button
              key={r}
              type="button"
              role="tab"
              aria-selected={r === round}
              onClick={() => {
                setRound(r)
                setSel(null)
              }}
              className={`relative flex h-12 shrink-0 flex-col items-center justify-center rounded-xl px-4 ${r === round ? 'bg-court-600 text-white' : 'bg-white text-ink ring-1 ring-black/[0.06]'}`}
            >
              <span className="text-[13px] font-bold leading-none">매치 {r}</span>
              <span className={`mt-1 text-[11px] leading-none ${r === round ? 'text-white/75' : 'text-ink-faint'}`}>{full}경기</span>
              {roundIssue(r) && <span className="absolute right-1.5 top-1.5 h-1.5 w-1.5 rounded-full bg-shuttle-500" aria-label="확인할 경기 있음" />}
            </button>
          )
        })}
      </div>

      <p className={`mb-2 min-h-5 text-[13px] ${sel ? 'font-semibold text-court-700' : 'text-ink-faint'}`}>
        {sel ? `${selName} 선택됨. 바꿀 사람이나 자리를 누르세요` : '두 사람을 차례로 누르면 자리가 바뀌어요'}
      </p>

      {/* 이 매치의 경기들 */}
      <div className="grid gap-2 md:grid-cols-2">
        {ds.map((d, i) => {
          const note = notes[d.key]
          const diff = note ? Math.abs(note.sum1 - note.sum2) : 0
          return (
            <div key={d.key} className="rounded-2xl border border-black/[0.06] bg-white p-2">
              <div className="flex items-center gap-2">
                <span className="score w-6 shrink-0 text-center text-[19px] font-semibold text-court-600">{i + 1}</span>
                <div className="grid min-w-0 flex-1 grid-cols-[1fr_auto_1fr] items-center gap-1.5">
                  {([1, 2] as const).map((team) => (
                    <div key={team} className={`grid gap-1 ${team === 2 ? 'col-start-3' : ''}`}>
                      {([0, 1] as const).map((idx) => {
                        const pos: Pos = { kind: 'slot', key: d.key, team, idx }
                        const id = (team === 1 ? d.team1 : d.team2)[idx]
                        return (
                          <PersonChip key={idx} id={id} roster={roster} selected={samePos(sel, pos)} target={!!sel && !samePos(sel, pos)} onClick={() => tap(pos)} />
                        )
                      })}
                    </div>
                  ))}
                  <span className="col-start-2 row-start-1 text-xs font-bold text-ink-faint">vs</span>
                </div>
                <button
                  type="button"
                  aria-label={`매치 ${round} ${i + 1}경기 지우기`}
                  onClick={() => {
                    setSel(null)
                    update((all) => all.filter((x) => x.key !== d.key))
                  }}
                  className="flex h-10 w-8 shrink-0 items-center justify-center rounded-lg text-ink-faint active:bg-black/5"
                >
                  <IconX />
                </button>
              </div>
              {note && (
                <div className="mt-1.5 flex flex-wrap items-center gap-1.5 pl-8 text-xs">
                  {note.kind && note.kind !== 'invalid' && <KindBadge kind={note.kind} />}
                  {note.kind === 'invalid' && <span className="rounded-md bg-danger/10 px-1.5 py-0.5 font-semibold text-danger">종목 안 맞음</span>}
                  <span className={diff >= 2 ? 'font-semibold text-shuttle-800' : 'text-ink-faint'}>
                    실력 {note.sum1} : {note.sum2}
                  </span>
                  {note.partnerRepeat && <span className="rounded-md bg-shuttle-100 px-1.5 py-0.5 font-semibold text-shuttle-800">파트너 반복</span>}
                </div>
              )}
            </div>
          )
        })}
        <button
          type="button"
          onClick={() => update((all) => [...all, newDraft(round)])}
          className="flex h-12 items-center justify-center gap-1 rounded-2xl border border-dashed border-black/15 text-sm font-semibold text-ink-soft active:bg-black/5"
        >
          <IconPlus className="h-4 w-4" />
          경기 추가
        </button>
      </div>

      {/* 쉬는 사람 */}
      <SectionTitle right={`${bench.length}명`}>매치 {round} 쉬는 사람</SectionTitle>
      {bench.length === 0 ? (
        <p className="text-sm text-ink-faint">모두 경기가 있어요.</p>
      ) : (
        <div className="flex flex-wrap gap-1.5">
          {bench.map((p) => {
            const pos: Pos = { kind: 'bench', id: p.id }
            const twice = restedBefore && !prevInRound.has(p.id)
            return (
              <button
                key={p.id}
                type="button"
                onClick={() => tap(pos)}
                className={`inline-flex h-10 items-center gap-1 rounded-lg px-2.5 text-[14px] font-semibold ${
                  samePos(sel, pos) ? 'bg-court-600 text-white' : 'bg-white text-ink ring-1 ring-black/[0.08] active:bg-floor'
                }`}
              >
                {!samePos(sel, pos) && <GenderMark g={roster.genderOf(p.id)} />}
                {roster.nameOf(p.id)}
                {roster.levelOf(p.id) && <span className={`text-xs font-medium ${samePos(sel, pos) ? 'text-white/75' : 'text-ink-faint'}`}>{roster.levelOf(p.id)}</span>}
                <span className={`score text-[14px] ${samePos(sel, pos) ? 'text-white/80' : 'text-ink-faint'}`}>{check.counts[p.id] ?? 0}</span>
                {twice && <span className="ml-0.5 rounded bg-shuttle-100 px-1 text-[11px] text-shuttle-800">연속 휴식</span>}
              </button>
            )
          })}
        </div>
      )}

      {/* 사람별 게임 수 */}
      <SectionTitle right={check.complete.length > 0 ? `최소 ${check.min}게임, 최대 ${check.max}게임` : undefined}>사람별 게임 수</SectionTitle>
      <div className="flex flex-wrap gap-1.5">
        {roster.confirmed.map((p) => {
          const c = check.counts[p.id] ?? 0
          const low = check.complete.length > 0 && check.max - c > 1
          return (
            <span key={p.id} className={`inline-flex items-center gap-1 rounded-lg px-2 py-1 text-[13px] ${low ? 'bg-shuttle-100 text-shuttle-800' : 'bg-white text-ink-soft ring-1 ring-black/[0.06]'}`}>
              {roster.nameOf(p.id)}
              <span className="score text-[15px] font-semibold">{c}</span>
            </span>
          )
        })}
      </div>
      {check.max - check.min > 1 && <p className="mt-2 text-xs text-shuttle-800">노란 사람은 다른 사람보다 2게임 이상 적어요.</p>}

      {/* 저장 / 확정: 하단 탭 바로 위 */}
      <div className="h-28" aria-hidden />
      <div className="fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom))] z-20 border-t border-black/[0.08] bg-white/95 shadow-[0_-8px_24px_rgba(0,0,0,0.06)] backdrop-blur">
        <div className="mx-auto max-w-4xl px-4 py-3">
          <p className={`mb-2 text-sm ${blockedText ? 'text-danger' : 'text-ink-soft'}`}>
            {blockedText ?? `완성된 경기 ${check.complete.length}개${dirty ? ', 저장 안 한 변경이 있어요' : ''}`}
          </p>
          <div className="flex gap-2">
            <Button variant="secondary" disabled={busy || !dirty || blocked} onClick={() => void save(false)}>
              저장
            </Button>
            <ConfirmButton
              label="확정하고 공개"
              confirmLabel="참가자 모두에게 공개돼요. 한 번 더 누르세요"
              className="h-12 flex-1 bg-court-600 px-3 text-[15px] text-white"
              armedClassName="h-12 flex-1 bg-court-700 px-3 text-[14px] text-white"
              disabled={busy || blocked || check.complete.length === 0}
              onConfirm={() => void save(true)}
            />
          </div>
        </div>
      </div>
    </>
  )
}

function PersonChip({ id, roster, selected, target, onClick }: { id: string | null; roster: Roster; selected: boolean; target: boolean; onClick: () => void }) {
  const stale = id && !roster.isConfirmed(id)
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      className={`h-10 min-w-0 truncate rounded-lg px-2 text-left text-[14px] font-semibold transition-colors ${
        selected
          ? 'bg-court-600 text-white'
          : !id
            ? `border border-dashed text-ink-faint ${target ? 'border-court-500 bg-court-50' : 'border-black/15'}`
            : stale
              ? 'bg-danger/10 text-danger'
              : `${target ? 'bg-court-50 ring-1 ring-court-500/40' : 'bg-floor'} text-ink`
      }`}
    >
      {id && !selected && <GenderMark g={roster.genderOf(id)} className="mr-1" />}
      {id ? roster.nameOf(id) : '빈 자리'}
      {id && roster.levelOf(id) && <span className={`ml-1 text-xs font-medium ${selected ? 'text-white/75' : 'text-ink-faint'}`}>{roster.levelOf(id)}</span>}
    </button>
  )
}
// ---------------------------------------------------------------------
// 확정된 대진표 (모두) + 운영진 조작
// ---------------------------------------------------------------------
function ScheduleView({
  s,
  roster,
  regs,
  matches,
  myRegId,
  isAdmin,
  onChanged,
}: {
  s: SessionOverview
  roster: Roster
  regs: Reg[]
  matches: MatchWithPhase[]
  myRegId: string | null
  isAdmin: boolean
  onChanged: () => Promise<void>
}) {
  const toast = useToast()
  const [busy, setBusy] = useState(false)
  const [sub, setSub] = useState<{ match: ScheduledMatch; out: string } | null>(null)
  const [scoring, setScoring] = useState<ScheduledMatch | null>(null)
  const [forfeit, setForfeit] = useState<ScheduledMatch | null>(null)

  /** 점수 넣을 수 있나: 운영진, 또는 그 경기 선수(대회 중이거나 아직 점수가 없을 때) — 서버 can_score_match와 같은 규칙 */
  const canScore = (m: ScheduledMatch) =>
    isAdmin || (!!myRegId && m.match_players.some((p) => p.registration_id === myRegId) && (tournamentActive(s) || !m.result_at))

  const saveScore = async (m: ScheduledMatch, kind: ScoreKind, a: number | null, b: number | null): Promise<string | null> => {
    const { error } = await supabase.rpc('record_score', { p_match: m.id, p_score1: a, p_score2: b, p_kind: kind, p_expected: m.result_at })
    await onChanged()
    if (error) {
      if (error.message.includes('score_conflict')) {
        setScoring(null)
        toast.error('다른 사람이 먼저 점수를 넣었어요. 바뀐 점수를 확인하고 다시 고쳐주세요')
        return null
      }
      return errorMessage(error)
    }
    toast.success(kind === 'normal' ? `${a} : ${b} 저장했어요` : kind === 'clear' ? '점수를 지웠어요' : '기권승으로 저장했어요')
    return null
  }

  const scheduled = matches.filter((m) => m.phase === 'scheduled')
  const active = tournamentActive(s)
  const started = scheduled.some((m) => m.status === 'playing' || m.status === 'finished')

  const playingIds = new Set(matches.filter((m) => m.status === 'playing').flatMap((m) => m.match_players.map((p) => p.registration_id)))
  const regById = Object.fromEntries(regs.map((r) => [r.id, r]))
  const info = (id: string): PlayerState | undefined => {
    const r = regById[id]
    if (!r) return undefined
    return { name: roster.nameOf(id), confirmed: r.status === 'confirmed', arrived: !!r.checked_in_at, playingElsewhere: playingIds.has(id) }
  }

  const run = async (fn: () => PromiseLike<{ error: unknown }>, ok: string) => {
    setBusy(true)
    const { error } = await fn()
    setBusy(false)
    if (error) toast.error(errorMessage(error))
    else toast.success(ok)
    await onChanged()
  }

  const rounds = [...new Set(scheduled.map((m) => m.round_no))].sort((a, b) => a - b)
  const mine = myRegId ? scheduled.filter((m) => m.status !== 'canceled' && m.match_players.some((p) => p.registration_id === myRegId)) : []
  const myNext = mine.find((m) => m.status === 'playing') ?? mine.find((m) => m.status === 'queued')
  const myDone = mine.filter((m) => m.status === 'finished').length
  const myTeamOf = (m: ScheduledMatch) => m.match_players.find((p) => p.registration_id === myRegId)?.team ?? null
  const myWins = mine.filter((m) => winnerOf(m) !== null && winnerOf(m) === myTeamOf(m)).length
  const myLosses = mine.filter((m) => winnerOf(m) !== null && winnerOf(m) !== myTeamOf(m)).length
  const missing = scheduled.filter((m) => m.status === 'finished' && !m.result_kind)
  const doneCount = scheduled.filter((m) => m.status === 'finished').length
  const liveCount = scheduled.filter((m) => m.status !== 'canceled').length

  const subRound = sub?.match.round_no
  const inSubRound = new Set(
    scheduled.filter((m) => m.round_no === subRound && m.status !== 'canceled').flatMap((m) => m.match_players.map((p) => p.registration_id)),
  )

  const teamText = (ids: string[]) =>
    ids.map((id) => (
      <span key={id} className={id === myRegId ? 'font-bold text-court-700' : roster.isConfirmed(id) ? '' : 'text-danger line-through'}>
        {roster.nameOf(id)}
      </span>
    ))

  return (
    <>
      {/* 내 경기 */}
      {myRegId && (
        <Card className="mb-4">
          <div className="flex items-baseline justify-between">
            <h2 className="text-[15px] font-bold text-ink">내 대회 경기</h2>
            <span className="text-sm text-ink-soft">
              {mine.length}경기 중 <span className="score text-[17px] text-ink">{myDone}</span>경기 끝
              {myWins + myLosses > 0 && (
                <>
                  , <span className="font-semibold text-court-700">{myWins}승</span> {myLosses}패
                </>
              )}
            </span>
          </div>
          {mine.length === 0 ? (
            <p className="mt-2 text-sm text-ink-soft">이번 대진에 내 경기가 없어요.</p>
          ) : myNext ? (
            <MyNext m={myNext} myRegId={myRegId} roster={roster} reason={active && myNext.status === 'queued' ? blockReason(myNext, info) : null} />
          ) : (
            <p className="mt-2 text-sm text-ink-soft">내 경기를 모두 마쳤어요.</p>
          )}
        </Card>
      )}

      {/* 운영진 */}
      {isAdmin && active && (
        <Card className="mb-4">
          <h2 className="text-[15px] font-bold text-ink">대회 진행</h2>
          <p className="mt-1 text-sm leading-relaxed text-ink-soft">
            대기 경기의 이름을 누르면 선수를 바꿀 수 있어요. 4명이 모두 도착하면 순서대로 빈 코트에 들어가요.
          </p>
          <div className="mt-3 flex gap-2">
            {s.tournament_state === 'published' && (
              <Button variant="secondary" disabled={busy || started} onClick={() => void run(() => supabase.rpc('unpublish_schedule', { p_session: s.id }), '확정을 취소했어요. 다시 대진을 고칠 수 있어요')}>
                확정 취소
              </Button>
            )}
            <ConfirmButton
              label="대회 끝내기"
              confirmLabel="남은 경기는 취소돼요. 한 번 더"
              className="h-12 flex-1 border border-black/10 bg-white px-3 text-[15px] text-ink"
              armedClassName="h-12 flex-1 bg-danger px-3 text-[14px] text-white"
              disabled={busy}
              onConfirm={() => void run(() => supabase.rpc('end_tournament', { p_session: s.id }), '대회를 끝냈어요. 이제 자율 대진이에요')}
            />
          </div>
        </Card>
      )}

      {s.tournament_state === 'finished' && (
        <p className="mb-4 rounded-xl bg-court-50 px-3 py-2.5 text-sm text-court-700">대회가 끝났어요. 대진판에서 다시 자유롭게 경기를 만들 수 있어요.</p>
      )}

      <SectionTitle right={`${liveCount}경기 중 ${doneCount}경기 끝${missing.length ? `, 점수 미입력 ${missing.length}` : ''}`}>대진표</SectionTitle>
      <div className="space-y-5">
        {rounds.map((r) => (
          <section key={r}>
            <h3 className="mb-1.5 px-1 text-[13px] font-bold text-ink-soft">
              매치 <span className="score text-[17px] text-ink">{r}</span>
            </h3>
            <List>
              {scheduled
                .filter((m) => m.round_no === r)
                .sort((a, b) => a.order_no - b.order_no)
                .map((m) => {
                  const [t1, t2] = teamsOf(m.match_players)
                  const isMine = !!myRegId && m.match_players.some((p) => p.registration_id === myRegId)
                  const reason = active && m.status === 'queued' ? blockReason(m, info) : null
                  const editable = isAdmin && active && m.status === 'queued'
                  const finished = m.status === 'finished'
                  const win = winnerOf(m)
                  const tappable = finished && canScore(m)
                  return (
                    <div
                      key={m.id}
                      role={tappable ? 'button' : undefined}
                      tabIndex={tappable ? 0 : undefined}
                      onClick={tappable ? () => setScoring(m) : undefined}
                      onKeyDown={tappable ? (e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), setScoring(m)) : undefined}
                      className={`flex items-center gap-2 px-3 py-2.5 ${isMine ? 'bg-court-50' : ''} ${m.status === 'canceled' ? 'opacity-50' : ''} ${tappable ? 'cursor-pointer active:bg-floor' : ''}`}
                    >
                      <span className="score w-6 shrink-0 text-center text-[19px] font-semibold text-court-600">{m.order_no}</span>
                      <div className="min-w-0 flex-1">
                        {editable ? (
                          <div className="flex flex-wrap items-center gap-1 text-[15px] text-ink">
                            {[t1, t2].map((team, ti) => (
                              <span key={ti} className="contents">
                                {ti === 1 && <span className="px-0.5 text-xs font-bold text-ink-faint">vs</span>}
                                {team.map((id, k) => (
                                  <span key={id} className="contents">
                                  {k > 0 && <span className="-ml-1 text-ink-faint">,</span>}
                                  <button
                                    type="button"
                                    onClick={() => setSub({ match: m, out: id })}
                                    className={`rounded-md px-1.5 py-0.5 underline decoration-black/20 underline-offset-4 active:bg-black/5 ${roster.isConfirmed(id) ? '' : 'text-danger'}`}
                                  >
                                    {roster.nameOf(id)}
                                  </button>
                                  </span>
                                ))}
                              </span>
                            ))}
                          </div>
                        ) : (
                          <p className={`text-[15px] leading-snug text-ink ${m.status === 'canceled' ? 'line-through' : ''}`}>
                            <span className={`whitespace-nowrap ${win === 2 ? 'opacity-55' : win === 1 ? 'font-semibold' : ''}`}>
                              <Joined parts={teamText(t1)} />
                            </span>{' '}
                            <span className="px-0.5 text-xs font-bold text-ink-faint">vs</span>{' '}
                            <span className={`whitespace-nowrap ${win === 1 ? 'opacity-55' : win === 2 ? 'font-semibold' : ''}`}>
                              <Joined parts={teamText(t2)} />
                            </span>
                          </p>
                        )}
                        {reason && <p className="mt-0.5 text-xs text-shuttle-800">{reason}</p>}
                      </div>
                      {(() => {
                        const k = gameKind([...t1, ...t2].map(roster.genderOf))
                        return k && k !== 'invalid' ? <KindBadge kind={k} /> : null
                      })()}
                      {finished ? <ResultBadge m={m} canEnter={tappable} /> : <StatusBadge m={m} />}
                      {editable && (
                        <button
                          type="button"
                          onClick={() => setForfeit(m)}
                          className="h-10 shrink-0 rounded-lg bg-black/[0.05] px-2 text-xs font-semibold text-ink-soft active:bg-black/10"
                        >
                          기권
                        </button>
                      )}
                      {editable && (
                        <ConfirmButton
                          label={<IconX />}
                          ariaLabel={`매치 ${r} ${m.order_no}경기 취소`}
                          confirmLabel="취소"
                          className="h-10 w-10 shrink-0 bg-black/[0.05] text-ink-soft"
                          armedClassName="h-10 shrink-0 px-3 bg-danger text-white text-sm"
                          disabled={busy}
                          onConfirm={() => void run(() => supabase.rpc('cancel_match', { p_match: m.id }), '대회 경기를 취소했어요')}
                        />
                      )}
                    </div>
                  )
                })}
            </List>
          </section>
        ))}
      </div>

      {scoring && (
        <ScoreSheet
          mode="edit"
          title={`매치 ${scoring.round_no} · ${scoring.order_no}경기 ${scoring.result_kind ? '점수 고치기' : '점수 입력'}`}
          team1={teamsOf(scoring.match_players)[0].map(roster.nameOf).join(', ')}
          team2={teamsOf(scoring.match_players)[1].map(roster.nameOf).join(', ')}
          target={s.score_target}
          cap={s.score_cap}
          initial={{ score1: scoring.score1, score2: scoring.score2 }}
          canScore={canScore(scoring)}
          canClear={!!scoring.result_kind}
          onSubmit={(kind, a, b) => saveScore(scoring, kind, a, b)}
          onClose={() => setScoring(null)}
        />
      )}

      {forfeit && (
        <Sheet title={`매치 ${forfeit.round_no} · ${forfeit.order_no}경기 기권 처리`} onClose={() => setForfeit(null)}>
          <div className="space-y-2 p-4">
            <p className="text-sm leading-relaxed text-ink-soft">끝내 안 온 팀이 있을 때 써요. 경기는 치지 않은 채 끝나고, 게임 수에는 들어가지 않아요.</p>
            {([1, 2] as const).map((team) => (
              <Button
                key={team}
                variant="secondary"
                className="w-full"
                disabled={busy}
                onClick={() => {
                  const m = forfeit
                  setForfeit(null)
                  void run(() => supabase.rpc('forfeit_match', { p_match: m.id, p_winner: team }), '기권 처리했어요')
                }}
              >
                {teamsOf(forfeit.match_players)[team - 1].map(roster.nameOf).join(', ')} 기권승
              </Button>
            ))}
          </div>
        </Sheet>
      )}

      {sub && (
        <Sheet title={`${roster.nameOf(sub.out)} 대신 들어갈 사람`} onClose={() => setSub(null)}>
          <div className="divide-y divide-black/[0.06]">
            {roster.confirmed
              .filter((p) => !inSubRound.has(p.id))
              .map((p) => (
                <button
                  key={p.id}
                  type="button"
                  disabled={busy}
                  onClick={() => {
                    const target = sub
                    setSub(null)
                    void run(
                      () => supabase.rpc('substitute_player', { p_match: target.match.id, p_out: target.out, p_in: p.id }),
                      `${roster.nameOf(target.out)} → ${roster.nameOf(p.id)} 교체했어요`,
                    )
                  }}
                  className="flex min-h-14 w-full items-center gap-2 px-4 py-2 text-left active:bg-black/5"
                >
                  <span className="truncate text-[15px] font-semibold text-ink">{roster.nameOf(p.id)}</span>
                  {roster.levelOf(p.id) && <Badge tone="outline">{roster.levelOf(p.id)}</Badge>}
                  {p.kind === 'guest' && <Badge>게스트</Badge>}
                  {!p.checked_in_at && <span className="ml-auto text-xs text-ink-faint">아직 안 옴</span>}
                </button>
              ))}
            {roster.confirmed.every((p) => inSubRound.has(p.id)) && (
              <p className="px-4 py-6 text-center text-sm text-ink-soft">매치 {subRound}에 경기가 없는 참석자가 없어요.</p>
            )}
          </div>
        </Sheet>
      )}
    </>
  )
}

function Joined({ parts }: { parts: ReactNode[] }) {
  return (
    <>
      {parts.map((p, i) => (
        <span key={i}>
          {i > 0 && ', '}
          {p}
        </span>
      ))}
    </>
  )
}

function KindBadge({ kind }: { kind: GameKind }) {
  const tone = kind === 'MD' ? 'bg-sky-50 text-sky-700' : kind === 'WD' ? 'bg-rose-50 text-rose-600' : 'bg-violet-50 text-violet-700'
  return <span className={`shrink-0 rounded-md px-1.5 py-0.5 text-xs font-semibold ${tone}`}>{KIND_LABEL[kind]}</span>
}

function ResultBadge({ m, canEnter }: { m: ScheduledMatch; canEnter: boolean }) {
  if (m.result_kind === 'normal' && m.score1 !== null && m.score2 !== null) {
    return (
      <span className="score shrink-0 rounded-md bg-ink/[0.06] px-2 py-0.5 text-[16px] font-semibold text-ink">
        <span className={m.score1 > m.score2 ? 'text-court-700' : 'text-ink-faint'}>{m.score1}</span>
        <span className="px-0.5 text-ink-faint">:</span>
        <span className={m.score2 > m.score1 ? 'text-court-700' : 'text-ink-faint'}>{m.score2}</span>
      </span>
    )
  }
  if (m.result_kind === 'walkover1' || m.result_kind === 'walkover2') {
    return <span className="shrink-0 rounded-md bg-ink/[0.06] px-1.5 py-0.5 text-xs font-semibold text-ink-soft">{m.result_kind === 'walkover1' ? '1팀' : '2팀'} 기권승</span>
  }
  return (
    <span className={`shrink-0 rounded-md px-1.5 py-0.5 text-xs font-semibold ${canEnter ? 'bg-shuttle-100 text-shuttle-800' : 'bg-ink/[0.06] text-ink-faint'}`}>
      {canEnter ? '점수 넣기' : '점수 미입력'}
    </span>
  )
}

function StatusBadge({ m }: { m: ScheduledMatch }) {
  if (m.status === 'playing') return <Badge tone="court">코트 {m.court_no}</Badge>
  if (m.status === 'finished') return <Badge>끝</Badge>
  if (m.status === 'canceled') return <Badge tone="danger">취소</Badge>
  return <Badge tone="outline">대기</Badge>
}

function MyNext({ m, myRegId, roster, reason }: { m: ScheduledMatch; myRegId: string; roster: Roster; reason: string | null }) {
  const [t1, t2] = teamsOf(m.match_players)
  const mineTeam = t1.includes(myRegId) ? t1 : t2
  const other = mineTeam === t1 ? t2 : t1
  const partner = mineTeam.find((id) => id !== myRegId)
  return (
    <div className={`mt-3 rounded-xl px-3 py-3 ${m.status === 'playing' ? 'bg-court-600 text-white' : 'bg-floor'}`}>
      <p className={`text-[13px] font-bold ${m.status === 'playing' ? 'text-white/80' : 'text-ink-soft'}`}>
        {m.status === 'playing' ? `지금 코트 ${m.court_no}에서 경기 중` : '다음 경기'}, 매치 {m.round_no} · {m.order_no}경기
      </p>
      <p className={`mt-1 text-[17px] font-bold ${m.status === 'playing' ? 'text-white' : 'text-ink'}`}>
        {partner ? roster.nameOf(partner) : '?'}님과 한 팀
      </p>
      <p className={`text-sm ${m.status === 'playing' ? 'text-white/85' : 'text-ink-soft'}`}>상대: {other.map((id) => roster.nameOf(id)).join(', ')}</p>
      {reason && <p className="mt-1.5 text-xs text-shuttle-800">{reason}</p>}
    </div>
  )
}
