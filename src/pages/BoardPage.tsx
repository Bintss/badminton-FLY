import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { ConfirmButton } from '../components/ConfirmButton'
import { ScoreSheet, type ScoreKind } from '../components/ScoreSheet'
import { GenderToggle } from '../components/GenderToggle'
import { Input } from '../components/form'
import { IconChevronLeft, IconDown, IconSun, IconUndo, IconUp, IconX } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Empty, List, Page, SectionTitle, Skeleton } from '../components/ui'
import { DEFAULT_TZ, formatTime, trimSeconds } from '../lib/datetime'
import { useServerNow } from '../lib/serverTime'
import { errorMessage, supabase } from '../lib/supabase'
import { blockReason, teamsOf, tournamentActive, type PlayerState, type ScheduledMatch } from '../lib/tournament'
import type { SessionOverview } from '../lib/types'

/** 이 시간 이상 쉰 사람은 강조 (분) */
const REST_ALERT_MIN = 30

interface PlayerStat {
  registration_id: string
  kind: 'member' | 'guest'
  user_id: string | null
  guest_name: string | null
  seq: number
  late_eta: string | null
  checked_in_at: string | null
  games: number
  last_finished_at: string | null
  is_playing: boolean
  queued_count: number
}

interface MatchRow {
  id: string
  court_no: number | null
  queue_pos: number | null
  status: 'queued' | 'playing'
  started_at: string | null
  created_at: string
  phase: 'free' | 'scheduled'
  round_no: number | null
  order_no: number | null
  match_players: { registration_id: string; team: 1 | 2 | null }[]
}

interface Player extends PlayerStat {
  name: string
  level?: string
  restMin: number | null // 체크인 전이면 null
}

/** 대진판을 보는 동안 화면이 꺼지지 않게 (지원하는 브라우저만) */
function useWakeLock(enabled: boolean) {
  const [active, setActive] = useState(false)
  useEffect(() => {
    if (!enabled || !('wakeLock' in navigator)) return
    let lock: WakeLockSentinel | null = null
    let alive = true
    const acquire = async () => {
      try {
        lock = await navigator.wakeLock.request('screen')
        if (!alive) return void lock.release()
        setActive(true)
        lock.addEventListener('release', () => setActive(false))
      } catch {
        setActive(false)
      }
    }
    const onVisible = () => {
      if (document.visibilityState === 'visible') void acquire()
    }
    void acquire()
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      alive = false
      document.removeEventListener('visibilitychange', onVisible)
      void lock?.release()
    }
  }, [enabled])
  return active
}

export default function BoardPage() {
  const { sessionId } = useParams()
  const { club, isAdmin } = useClub()
  const { session: auth } = useAuth()
  const uid = auth?.user.id
  const toast = useToast()
  const tz = club.timezone ?? DEFAULT_TZ
  const now = useServerNow(15_000)

  const [s, setS] = useState<SessionOverview | null>(null)
  const [stats, setStats] = useState<PlayerStat[]>([])
  const [matches, setMatches] = useState<MatchRow[]>([])
  const [names, setNames] = useState<Record<string, string>>({})
  const [levels, setLevels] = useState<Record<string, string>>({})
  const [canOperate, setCanOperate] = useState(false)
  const [loaded, setLoaded] = useState(false)

  const load = useCallback(async () => {
    if (!sessionId) return
    const [ov, st, ms, rs] = await Promise.all([
      supabase.from('session_overview').select('*').eq('id', sessionId).maybeSingle(),
      supabase.from('session_player_stats').select('*').eq('session_id', sessionId),
      supabase
        .from('matches')
        .select('id, court_no, queue_pos, status, started_at, created_at, phase, round_no, order_no, match_players(registration_id, team)')
        .eq('session_id', sessionId)
        .in('status', ['queued', 'playing']),
      supabase
        .from('registrations')
        .select('id, guest_name, profiles!registrations_user_id_fkey(display_name)')
        .eq('session_id', sessionId),
    ])
    const err = ov.error ?? st.error ?? ms.error ?? rs.error
    if (err) toast.error(errorMessage(err))
    setS((ov.data as SessionOverview | null) ?? null)
    setStats((st.data as PlayerStat[] | null) ?? [])
    setMatches((ms.data as MatchRow[] | null) ?? [])
    const map: Record<string, string> = {}
    for (const r of (rs.data as unknown as { id: string; guest_name: string | null; profiles: { display_name: string } | null }[] | null) ?? []) {
      map[r.id] = r.guest_name ?? r.profiles?.display_name ?? '이름 없음'
    }
    setNames(map)
    setLoaded(true)
  }, [sessionId, toast])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    if (!sessionId) return
    supabase.rpc('can_operate_board', { p_session: sessionId }).then(({ data }) => setCanOperate(Boolean(data)))
    supabase
      .from('club_members')
      .select('user_id, level')
      .eq('club_id', club.id)
      .eq('status', 'approved')
      .then(({ data }) => {
        const map: Record<string, string> = {}
        for (const m of data ?? []) if (m.level) map[m.user_id as string] = m.level as string
        setLevels(map)
      })
  }, [sessionId, club.id])

  // 실시간: 다른 폰에서 바꾼 내용 반영 (짧게 모아서 한 번 다시 읽기)
  const reloadTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (!sessionId) return
    const schedule = () => {
      if (reloadTimer.current) return
      reloadTimer.current = setTimeout(() => {
        reloadTimer.current = null
        void load()
      }, 300 + Math.random() * 400)
    }
    const channel = supabase
      .channel(`board:${sessionId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'matches', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'registrations', filter: `session_id=eq.${sessionId}` }, schedule)
      .subscribe()
    return () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current)
      reloadTimer.current = null
      void supabase.removeChannel(channel)
    }
  }, [sessionId, load])

  const operating = canOperate && !!s && !s.canceled_at
  const awake = useWakeLock(operating)

  const players: Player[] = useMemo(() => {
    return stats
      .map((p) => {
        const since = Math.max(p.checked_in_at ? Date.parse(p.checked_in_at) : 0, p.last_finished_at ? Date.parse(p.last_finished_at) : 0)
        return {
          ...p,
          name: names[p.registration_id] ?? p.guest_name ?? '이름 없음',
          level: p.user_id ? levels[p.user_id] : undefined,
          restMin: p.checked_in_at ? Math.max(0, Math.floor((now - since) / 60000)) : null,
        }
      })
      .sort((a, b) => {
        // 도착한 사람 먼저 → 게임 수 적은 순 → 오래 쉰 순 → 신청 순
        if ((a.restMin === null) !== (b.restMin === null)) return a.restMin === null ? 1 : -1
        if (a.games !== b.games) return a.games - b.games
        if ((b.restMin ?? 0) !== (a.restMin ?? 0)) return (b.restMin ?? 0) - (a.restMin ?? 0)
        return a.seq - b.seq
      })
  }, [stats, names, levels, now])

  const byId = useMemo(() => Object.fromEntries(players.map((p) => [p.registration_id, p])), [players])
  // 대회 모드: 대회 경기만 돌아간다. 확정 전 초안(운영진에게만 보임)은 대진판에 섞지 않는다
  const tMode = tournamentActive(s)
  const visible = matches.filter((m) => m.phase === 'free' || tMode)
  const playing = visible.filter((m) => m.status === 'playing')
  const queued = visible
    .filter((m) => m.status === 'queued' && m.phase === 'free')
    .sort((a, b) => (a.queue_pos ?? 0) - (b.queue_pos ?? 0) || a.created_at.localeCompare(b.created_at))
  const tQueued = visible
    .filter((m) => m.status === 'queued' && m.phase === 'scheduled')
    .sort((a, b) => (a.round_no ?? 0) - (b.round_no ?? 0) || (a.order_no ?? 0) - (b.order_no ?? 0))

  const back = (
    <Link to={s ? `/c/${club.id}/s/${s.id}` : `/c/${club.id}`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      {s?.title ?? '일정'}
    </Link>
  )

  if (!loaded) {
    return (
      <Page back={back} wide>
        <Skeleton className="h-7 w-32" />
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <Skeleton className="aspect-[2.2/1] w-full rounded-2xl" />
          <Skeleton className="aspect-[2.2/1] w-full rounded-2xl" />
        </div>
      </Page>
    )
  }
  if (!s) return <Page back={back}><Empty title="운동을 찾을 수 없어요" /></Page>

  const nameOf = (id: string) => byId[id]?.name ?? names[id] ?? '?'

  return (
    <Page back={back} wide>
      <div className="mb-4 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h1 className="text-[22px] font-bold tracking-tight text-ink">대진판</h1>
        <span className="flex items-center gap-2 text-sm text-ink-soft">
          {formatTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}, 코트 {s.court_count}면
          {awake && (
            <span className="inline-flex items-center gap-1 text-court-600" title="대진판을 보는 동안 화면이 꺼지지 않아요">
              <IconSun className="h-4 w-4" />
              화면 켜둠
            </span>
          )}
        </span>
      </div>
      {s.canceled_at && <p className="mb-3 rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">취소된 운동이에요.</p>}
      {tMode && (
        <Link to={`/c/${club.id}/s/${s.id}/tournament`} className="mb-3 flex items-center justify-between gap-3 rounded-xl bg-court-50 px-3 py-2.5 text-sm text-court-700 active:bg-court-100">
          <span>
            <span className="font-bold">자체대회 진행 중.</span> 대진표 순서대로, 4명이 모두 도착한 경기부터 빈 코트에 들어가요.
          </span>
          <span className="shrink-0 font-semibold underline underline-offset-4">대진표</span>
        </Link>
      )}
      {!canOperate && !s.canceled_at && <p className="mb-3 rounded-xl bg-black/[0.04] px-3 py-2 text-sm text-ink-soft">참석 확정자와 운영진만 대진을 바꿀 수 있어요. 지금은 보기만 할 수 있어요.</p>}

      {/* 가로 화면(태블릿·가로 모드)에서는 왼쪽 코트·대기, 오른쪽 참석자 */}
      <div className="md:grid md:grid-cols-[minmax(0,1fr)_minmax(0,22rem)] md:gap-6">
        <div>
          <Courts
            s={s}
            playing={playing}
            now={now}
            nameOf={nameOf}
            canOperate={operating}
            isAdmin={isAdmin}
            myRegIds={new Set(players.filter((p) => p.user_id && p.user_id === uid).map((p) => p.registration_id))}
            onChanged={load}
          />
          {tMode ? (
            <TournamentQueue
              queued={tQueued}
              nameOf={nameOf}
              info={(id) => {
                const p = byId[id]
                return p
                  ? { name: p.name, confirmed: true, arrived: p.restMin !== null, playingElsewhere: p.is_playing }
                  : { name: names[id] ?? '?', confirmed: false, arrived: false, playingElsewhere: false }
              }}
              canCancel={operating && isAdmin}
              tournamentLink={`/c/${club.id}/s/${s.id}/tournament`}
              onChanged={load}
            />
          ) : (
            <Queue queued={queued} nameOf={nameOf} canOperate={operating} onChanged={load} />
          )}
        </div>
        <Players sessionId={s.id} players={players} canOperate={operating} selectable={operating && !tMode} tournament={tMode} onChanged={load} />
      </div>
    </Page>
  )
}

/** 코트를 위에서 본 라인 (복식). 가로로 긴 코트, 가운데가 네트 */
function CourtLines({ empty }: { empty: boolean }) {
  const stroke = empty ? 'rgba(19,100,79,0.28)' : 'rgba(255,255,255,0.55)'
  return (
    <svg viewBox="0 0 440 200" preserveAspectRatio="none" className="absolute inset-0 h-full w-full" aria-hidden>
      <g fill="none" stroke={stroke} strokeWidth="2" vectorEffect="non-scaling-stroke">
        <rect x="6" y="6" width="428" height="188" />
        <line x1="6" y1="20" x2="434" y2="20" />
        <line x1="6" y1="180" x2="434" y2="180" />
        <line x1="30" y1="6" x2="30" y2="194" />
        <line x1="410" y1="6" x2="410" y2="194" />
        <line x1="160" y1="6" x2="160" y2="194" />
        <line x1="280" y1="6" x2="280" y2="194" />
        <line x1="6" y1="100" x2="160" y2="100" />
        <line x1="280" y1="100" x2="434" y2="100" />
      </g>
      <line x1="220" y1="0" x2="220" y2="200" stroke={empty ? 'rgba(19,100,79,0.45)' : '#fff'} strokeWidth="3" strokeDasharray="3 4" vectorEffect="non-scaling-stroke" />
    </svg>
  )
}

function Courts({
  s,
  playing,
  now,
  nameOf,
  canOperate,
  isAdmin,
  myRegIds,
  onChanged,
}: {
  s: SessionOverview
  playing: MatchRow[]
  now: number
  nameOf: (id: string) => string
  canOperate: boolean
  isAdmin: boolean
  /** 내 신청 id (대회 경기 점수 입력 권한 판단) */
  myRegIds: Set<string>
  onChanged: () => Promise<void>
}) {
  const toast = useToast()
  const [busy, setBusy] = useState<string | null>(null)
  const [scoring, setScoring] = useState<MatchRow | null>(null)

  /** 대회 경기 종료 + 점수. 실패하면 창에 보여줄 문구 */
  const finishScheduled = async (m: MatchRow, kind: ScoreKind, a: number | null, b: number | null): Promise<string | null> => {
    const { data, error } = await supabase.rpc('finish_with_score', { p_match: m.id, p_score1: a, p_score2: b, p_kind: kind })
    if (error) {
      await onChanged()
      return errorMessage(error)
    }
    const result = kind === 'normal' ? ` ${a}:${b} 기록` : kind ? ' 기권승 기록' : ', 점수는 나중에 입력'
    toast.success(`코트 ${m.court_no} 종료${result}${data ? '. 다음 경기가 들어갔어요' : ''}`)
    await onChanged()
    return null
  }
  const courts = Array.from({ length: s.court_count }, (_, i) => i + 1)

  const act = async (m: MatchRow, rpc: 'finish_match' | 'cancel_match') => {
    setBusy(m.id)
    const { data, error } = await supabase.rpc(rpc, { p_match: m.id })
    if (error) toast.error(errorMessage(error))
    else if (rpc === 'finish_match') toast.success(data ? `코트 ${m.court_no} 종료, 다음 경기가 들어갔어요` : `코트 ${m.court_no} 종료`)
    else toast.info(`코트 ${m.court_no} 경기를 취소했어요`)
    await onChanged()
    setBusy(null)
  }

  return (
    <section className="grid gap-3 sm:grid-cols-2">
      {courts.map((no) => {
        const m = playing.find((x) => x.court_no === no)
        const sides = m ? teamsOf(m.match_players) : [[], []]
        return (
          <div key={no}>
            <div className="mb-1.5 flex items-baseline justify-between px-1">
              <span className="text-[13px] font-bold text-ink-soft">
                코트 <span className="score text-[18px] text-ink">{no}</span>
                {m?.phase === 'scheduled' && (
                  <span className="ml-2 font-semibold text-court-600">
                    매치 {m.round_no} · {m.order_no}경기
                  </span>
                )}
              </span>
              {m?.started_at && (
                <span className="score text-[17px] font-semibold text-ink-soft">{Math.max(0, Math.floor((now - Date.parse(m.started_at)) / 60000))}분</span>
              )}
            </div>
            {/* 빈 코트는 납작하게: 4면이 다 비어도 참석자 목록이 너무 밀려나지 않게 */}
            <div className={`relative overflow-hidden rounded-2xl ${m ? 'aspect-[2.2/1] bg-court-600' : 'aspect-[4.4/1] border border-dashed border-court-200 bg-court-50 sm:aspect-[2.2/1]'}`}>
              <CourtLines empty={!m} />
              {m ? (
                <div className="absolute inset-0 grid grid-cols-2">
                  {sides.map((side, i) => (
                    <div key={i} className="flex flex-col items-center justify-center gap-2 px-3">
                      {side.map((id) => (
                        <span key={id} className="max-w-full truncate rounded-md bg-court-700/55 px-2 py-0.5 text-[16px] font-bold text-white">
                          {nameOf(id)}
                        </span>
                      ))}
                    </div>
                  ))}
                </div>
              ) : (
                <div className="absolute inset-0 flex items-center justify-center">
                  <span className="rounded-md bg-court-50/90 px-2 py-0.5 text-sm font-medium text-court-700">비어 있음</span>
                </div>
              )}
            </div>
            {m && canOperate && (
              <div className="mt-2 flex gap-2">
                {(m.phase === 'free' || isAdmin) && (
                  <ConfirmButton
                    label="취소"
                    confirmLabel="경기 취소"
                    className="h-11 border border-black/10 bg-white px-4 text-[15px] text-ink-soft"
                    disabled={busy === m.id}
                    onConfirm={() => void act(m, 'cancel_match')}
                  />
                )}
                {m.phase === 'scheduled' ? (
                  <Button className="h-11 flex-1 bg-ink text-[15px] text-white" disabled={busy === m.id} onClick={() => setScoring(m)}>
                    경기 종료 · 점수
                  </Button>
                ) : (
                  <ConfirmButton
                    label="경기 종료"
                    confirmLabel="한 번 더 누르면 종료"
                    className="h-11 flex-1 bg-ink text-[15px] text-white"
                    armedClassName="h-11 flex-1 bg-court-700 text-[15px] text-white"
                    disabled={busy === m.id}
                    onConfirm={() => void act(m, 'finish_match')}
                  />
                )}
              </div>
            )}
          </div>
        )
      })}
      {scoring && (
        <ScoreSheet
          mode="finish"
          title={`코트 ${scoring.court_no} · 매치 ${scoring.round_no} · ${scoring.order_no}경기`}
          team1={teamsOf(scoring.match_players)[0].map(nameOf).join(', ')}
          team2={teamsOf(scoring.match_players)[1].map(nameOf).join(', ')}
          target={s.score_target}
          cap={s.score_cap}
          canScore={isAdmin || scoring.match_players.some((p) => myRegIds.has(p.registration_id))}
          onSubmit={(kind, a, b) => finishScheduled(scoring, kind, a, b)}
          onClose={() => setScoring(null)}
        />
      )}
    </section>
  )
}

function Queue({
  queued,
  nameOf,
  canOperate,
  onChanged,
}: {
  queued: MatchRow[]
  nameOf: (id: string) => string
  canOperate: boolean
  onChanged: () => Promise<void>
}) {
  const toast = useToast()
  const [busy, setBusy] = useState(false)

  const run = async (fn: () => PromiseLike<{ error: unknown }>, ok?: string) => {
    setBusy(true)
    const { error } = await fn()
    if (error) toast.error(errorMessage(error))
    else if (ok) toast.info(ok)
    await onChanged()
    setBusy(false)
  }

  return (
    <section>
      <SectionTitle right={queued.length > 0 ? '코트가 비면 위에서부터 들어가요' : undefined}>
        대기 경기 <span className="score text-[17px]">{queued.length}</span>
      </SectionTitle>
      {queued.length === 0 ? (
        <p className="rounded-2xl border border-dashed border-black/15 px-4 py-4 text-center text-sm text-ink-soft">
          대기 중인 경기가 없어요. 참석자에서 4명을 골라 만들어요.
        </p>
      ) : (
        <List>
          {queued.map((m, i) => (
            <div key={m.id} className="flex items-center gap-2 px-3 py-2.5">
              <span className="score w-6 shrink-0 text-center text-[20px] font-semibold text-court-600">{i + 1}</span>
              <span className="min-w-0 flex-1 text-[15px] leading-snug text-ink">{m.match_players.map((p) => nameOf(p.registration_id)).join(', ')}</span>
              {canOperate && (
                <div className="flex shrink-0 items-center gap-1">
                  <button
                    className="flex h-10 w-10 items-center justify-center rounded-lg bg-black/[0.05] text-ink-soft disabled:opacity-30"
                    disabled={busy || i === 0}
                    onClick={() => void run(() => supabase.rpc('move_match', { p_match: m.id, p_direction: -1 }))}
                    aria-label={`${i + 1}번 경기 위로`}
                  >
                    <IconUp />
                  </button>
                  <button
                    className="flex h-10 w-10 items-center justify-center rounded-lg bg-black/[0.05] text-ink-soft disabled:opacity-30"
                    disabled={busy || i === queued.length - 1}
                    onClick={() => void run(() => supabase.rpc('move_match', { p_match: m.id, p_direction: 1 }))}
                    aria-label={`${i + 1}번 경기 아래로`}
                  >
                    <IconDown />
                  </button>
                  <ConfirmButton
                    label={<IconX />}
                    ariaLabel={`${i + 1}번 경기 삭제`}
                    confirmLabel="삭제"
                    className="h-10 w-10 bg-black/[0.05] text-ink-soft"
                    armedClassName="h-10 px-3 bg-danger text-white text-sm"
                    disabled={busy}
                    onConfirm={() => void run(() => supabase.rpc('cancel_match', { p_match: m.id }), '대기 경기를 삭제했어요')}
                  />
                </div>
              )}
            </div>
          ))}
        </List>
      )}
    </section>
  )
}

/** 대회 모드 대기열: 대진표 순서. 못 들어가는 경기는 이유를 보여준다 */
const TQUEUE_PREVIEW = 8
function TournamentQueue({
  queued,
  nameOf,
  info,
  canCancel,
  tournamentLink,
  onChanged,
}: {
  queued: MatchRow[]
  nameOf: (id: string) => string
  info: (id: string) => PlayerState
  canCancel: boolean
  tournamentLink: string
  onChanged: () => Promise<void>
}) {
  const toast = useToast()
  const [busy, setBusy] = useState(false)
  const [all, setAll] = useState(false)
  const shown = all ? queued : queued.slice(0, TQUEUE_PREVIEW)

  const cancel = async (m: MatchRow) => {
    setBusy(true)
    const { error } = await supabase.rpc('cancel_match', { p_match: m.id })
    if (error) toast.error(errorMessage(error))
    else toast.info(`매치 ${m.round_no} · ${m.order_no}경기를 취소했어요`)
    await onChanged()
    setBusy(false)
  }

  return (
    <section>
      <SectionTitle right={<Link to={tournamentLink} className="font-semibold text-court-600">대진표 전체</Link>}>
        남은 대회 경기 <span className="score text-[17px]">{queued.length}</span>
      </SectionTitle>
      {queued.length === 0 ? (
        <p className="rounded-2xl border border-dashed border-black/15 px-4 py-4 text-center text-sm text-ink-soft">
          남은 대회 경기가 없어요. 진행 중인 경기가 끝나면 대회가 끝나요.
        </p>
      ) : (
        <List>
          {shown.map((m) => {
            const [t1, t2] = teamsOf(m.match_players)
            const reason = blockReason(m as unknown as ScheduledMatch, info)
            return (
              <div key={m.id} className="flex items-center gap-2 px-3 py-2.5">
                <span className={`score w-9 shrink-0 text-center text-[17px] font-semibold ${reason ? 'text-ink-faint' : 'text-court-600'}`}>
                  {m.round_no}-{m.order_no}
                </span>
                <div className="min-w-0 flex-1">
                  <p className="text-[15px] leading-snug text-ink">
                    <span className="whitespace-nowrap">{t1.map(nameOf).join(', ')}</span> <span className="px-0.5 text-xs font-bold text-ink-faint">vs</span>{' '}
                    <span className="whitespace-nowrap">{t2.map(nameOf).join(', ')}</span>
                  </p>
                  <p className={`text-xs ${reason ? 'text-shuttle-800' : 'text-court-600'}`}>{reason ?? '코트가 비면 바로 들어가요'}</p>
                </div>
                {canCancel && (
                  <ConfirmButton
                    label={<IconX />}
                    ariaLabel={`매치 ${m.round_no} ${m.order_no}경기 취소`}
                    confirmLabel="취소"
                    className="h-10 w-10 shrink-0 bg-black/[0.05] text-ink-soft"
                    armedClassName="h-10 shrink-0 px-3 bg-danger text-white text-sm"
                    disabled={busy}
                    onConfirm={() => void cancel(m)}
                  />
                )}
              </div>
            )
          })}
        </List>
      )}
      {queued.length > TQUEUE_PREVIEW && (
        <button type="button" onClick={() => setAll((v) => !v)} className="mt-2 w-full rounded-xl py-2 text-sm font-semibold text-ink-soft active:bg-black/5">
          {all ? '접기' : `${queued.length - TQUEUE_PREVIEW}경기 더 보기`}
        </button>
      )}
    </section>
  )
}

function Players({
  sessionId,
  players,
  canOperate,
  selectable,
  tournament,
  onChanged,
}: {
  sessionId: string
  players: Player[]
  /** 체크인·게스트 추가 */
  canOperate: boolean
  /** 4명 골라 경기 만들기 (대회 중에는 꺼짐) */
  selectable: boolean
  tournament: boolean
  onChanged: () => Promise<void>
}) {
  const toast = useToast()
  const [selected, setSelected] = useState<string[]>([])
  const [warned, setWarned] = useState(false)
  const [guest, setGuest] = useState('')
  const [guestGender, setGuestGender] = useState<'M' | 'F' | null>(null)
  const [busy, setBusy] = useState(false)

  // 선택한 사람이 명단에서 빠지면(참석 취소 등) 선택에서도 뺀다
  const valid = selectable ? selected.filter((id) => players.some((p) => p.registration_id === id)) : []
  const busyPeople = valid.filter((id) => {
    const p = players.find((x) => x.registration_id === id)
    return p && (p.is_playing || p.queued_count > 0)
  })
  const arrivedCount = players.filter((p) => p.restMin !== null).length

  const toggle = (id: string) => {
    setWarned(false)
    setSelected((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : cur.length >= 4 ? cur : [...cur, id]))
  }

  const createMatch = async () => {
    if (valid.length !== 4) return
    if (busyPeople.length > 0 && !warned) {
      setWarned(true) // 경고 한 번, 다시 누르면 진행
      return
    }
    setBusy(true)
    const { data, error } = await supabase.rpc('create_match', { p_session: sessionId, p_registrations: valid })
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    const row = (Array.isArray(data) ? data[0] : data) as { status: string; court_no: number | null } | undefined
    toast.success(row?.status === 'playing' ? `코트 ${row.court_no}에서 바로 시작해요` : '대기 경기에 추가했어요')
    setSelected([])
    setWarned(false)
    await onChanged()
  }

  const setCheckIn = async (p: Player, value: boolean) => {
    const { error } = await supabase.rpc('set_checked_in', { p_registration: p.registration_id, p_checked_in: value })
    if (error) toast.error(errorMessage(error))
    else if (!value) toast.info(`${p.name}님 도착을 취소했어요`)
    await onChanged()
  }

  const addGuest = async (e: FormEvent) => {
    e.preventDefault()
    if (!guest.trim()) return
    setBusy(true)
    const { error } = await supabase.rpc('add_guest', { p_session: sessionId, p_name: guest.trim(), p_gender: guestGender })
    setBusy(false)
    if (error) toast.error(errorMessage(error))
    else {
      toast.success(`게스트 ${guest.trim()}님을 추가했어요`)
      setGuest('')
      setGuestGender(null)
    }
    await onChanged()
  }

  return (
    <section>
      <SectionTitle right={`도착 ${arrivedCount}/${players.length}`}>참석자</SectionTitle>
      {canOperate && (
        <p className="-mt-1 mb-2 text-xs text-ink-faint">
          {tournament ? '대회 중에는 경기를 새로 만들지 않아요. 도착한 사람만 눌러주세요.' : '게임 수가 적은 순서예요. 4명을 눌러 경기를 만들어요.'}
        </p>
      )}
      {players.length === 0 ? (
        <Empty title="참석 확정자가 없어요" />
      ) : (
        <List>
          {players.map((p) => {
            const isSel = valid.includes(p.registration_id)
            const arrived = p.restMin !== null
            const idle = arrived && !p.is_playing && p.queued_count === 0
            const longRest = idle && (p.restMin ?? 0) >= REST_ALERT_MIN
            return (
              <div
                key={p.registration_id}
                role={selectable ? 'button' : undefined}
                aria-pressed={selectable ? isSel : undefined}
                tabIndex={selectable ? 0 : undefined}
                onClick={selectable ? () => toggle(p.registration_id) : undefined}
                onKeyDown={selectable ? (e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), toggle(p.registration_id)) : undefined}
                className={`relative flex min-h-16 items-center gap-3 px-3 py-2.5 ${isSel ? 'bg-court-50' : longRest && !tournament ? 'bg-shuttle-100/70' : ''} ${selectable ? 'cursor-pointer select-none active:bg-floor' : ''}`}
              >
                {isSel && <span className="absolute inset-y-0 left-0 w-1 bg-court-600" aria-hidden />}
                <span className={`score w-9 shrink-0 text-center text-[28px] font-semibold leading-none ${arrived ? 'text-ink' : 'text-ink-faint'}`} aria-label={`${p.games}게임`}>
                  {p.games}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5">
                    <span className={`truncate text-[16px] font-semibold ${arrived ? 'text-ink' : 'text-ink-faint'}`}>{p.name}</span>
                    {p.level && <Badge tone="outline">{p.level}</Badge>}
                    {p.kind === 'guest' && <Badge>게스트</Badge>}
                  </div>
                  <p className={`text-[13px] ${longRest ? 'font-semibold text-shuttle-800' : 'text-ink-soft'}`}>
                    {!arrived
                      ? p.late_eta
                        ? `아직 안 왔어요, ${trimSeconds(p.late_eta)} 도착 예정`
                        : '아직 안 왔어요'
                      : p.is_playing
                        ? '경기 중'
                        : p.queued_count > 0
                          ? tournament
                            ? `대회 경기 ${p.queued_count}개 남음`
                            : `대기 경기 ${p.queued_count}개에 있어요`
                          : `${p.restMin}분째 쉬는 중`}
                  </p>
                </div>

                {isSel && <Badge tone="court">선택 {valid.indexOf(p.registration_id) + 1}</Badge>}
                {!isSel && p.is_playing && <Badge tone="court">경기 중</Badge>}
                {!isSel && !p.is_playing && p.queued_count > 0 && <Badge tone="shuttle">대기</Badge>}

                {canOperate && !arrived && (
                  <button
                    className="h-10 shrink-0 rounded-xl bg-court-600 px-3.5 text-sm font-semibold text-white active:bg-court-700"
                    onClick={(e) => {
                      e.stopPropagation()
                      void setCheckIn(p, true)
                    }}
                  >
                    도착
                  </button>
                )}
                {canOperate && arrived && idle && p.games === 0 && !isSel && (
                  <ConfirmButton
                    label={<IconUndo />}
                    ariaLabel={`${p.name} 도착 취소`}
                    confirmLabel="도착 취소"
                    className="h-10 w-10 shrink-0 text-ink-faint active:bg-black/5"
                    armedClassName="h-10 shrink-0 px-3 bg-danger/10 text-danger text-sm"
                    onConfirm={() => void setCheckIn(p, false)}
                  />
                )}
              </div>
            )
          })}
        </List>
      )}
      <p className="mt-2 text-xs leading-relaxed text-ink-faint">
        {REST_ALERT_MIN}분 넘게 쉰 사람은 노란색이에요. 쉰 시간은 도착한 때부터 세서, 늦게 온 사람이 불리하지 않아요.
      </p>

      {canOperate && (
        <form onSubmit={addGuest} className="mt-4 flex gap-2">
          <Input value={guest} onChange={(e) => setGuest(e.target.value)} maxLength={30} placeholder="게스트 이름" className="mt-0 min-w-0 flex-1" aria-label="게스트 이름" />
          <div className="flex items-center">
            <GenderToggle compact value={guestGender} onChange={setGuestGender} label="게스트 성별" />
          </div>
          <Button type="submit" variant="secondary" disabled={busy || !guest.trim()}>
            게스트 추가
          </Button>
        </form>
      )}

      {/* 선택 바: 하단 탭 바로 위에 붙는다 */}
      {selectable && valid.length > 0 && (
        <div className="fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom))] z-20 border-t border-black/[0.08] bg-white/95 shadow-[0_-8px_24px_rgba(0,0,0,0.06)] backdrop-blur">
          <div className="mx-auto max-w-md px-4 py-3">
            <p className="mb-2 truncate text-sm text-ink">
              {valid.map((id) => players.find((p) => p.registration_id === id)?.name).join(', ')}
            </p>
            {warned && busyPeople.length > 0 && (
              <p className="mb-2 rounded-lg bg-shuttle-100 px-3 py-2 text-sm text-shuttle-800">
                {busyPeople.map((id) => players.find((p) => p.registration_id === id)?.name).join(', ')}님은 이미 경기 중이거나 대기 경기에 있어요. 그래도 만들려면 한 번 더 누르세요.
              </p>
            )}
            <div className="flex gap-2">
              <Button
                variant="secondary"
                onClick={() => {
                  setSelected([])
                  setWarned(false)
                }}
              >
                선택 해제
              </Button>
              <Button className="flex-1" disabled={busy || valid.length !== 4} onClick={() => void createMatch()}>
                {valid.length === 4 ? (warned ? '그래도 경기 만들기' : '경기 만들기') : `${4 - valid.length}명 더 골라주세요`}
              </Button>
            </div>
          </div>
        </div>
      )}
    </section>
  )
}
