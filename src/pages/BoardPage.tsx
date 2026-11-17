import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { Input } from '../components/form'
import { Badge, Button, Card, ErrorText, Page, Spinner } from '../components/ui'
import { DEFAULT_TZ, formatTime, trimSeconds } from '../lib/datetime'
import { useServerNow } from '../lib/serverTime'
import { errorMessage, supabase } from '../lib/supabase'
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
  match_players: { registration_id: string }[]
}

interface Player extends PlayerStat {
  name: string
  level?: string
  restMin: number | null // 체크인 전이면 null
}

export default function BoardPage() {
  const { sessionId } = useParams()
  const { club } = useClub()
  const tz = club.timezone ?? DEFAULT_TZ
  const now = useServerNow(15_000)

  const [s, setS] = useState<SessionOverview | null>(null)
  const [stats, setStats] = useState<PlayerStat[]>([])
  const [matches, setMatches] = useState<MatchRow[]>([])
  const [names, setNames] = useState<Record<string, string>>({})
  const [levels, setLevels] = useState<Record<string, string>>({})
  const [canOperate, setCanOperate] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    if (!sessionId) return
    const [ov, st, ms, rs] = await Promise.all([
      supabase.from('session_overview').select('*').eq('id', sessionId).maybeSingle(),
      supabase.from('session_player_stats').select('*').eq('session_id', sessionId),
      supabase
        .from('matches')
        .select('id, court_no, queue_pos, status, started_at, created_at, match_players(registration_id)')
        .eq('session_id', sessionId)
        .in('status', ['queued', 'playing']),
      supabase
        .from('registrations')
        .select('id, guest_name, profiles!registrations_user_id_fkey(display_name)')
        .eq('session_id', sessionId)
        .eq('status', 'confirmed'),
    ])
    const err = ov.error ?? st.error ?? ms.error ?? rs.error
    if (err) setError(errorMessage(err))
    setS((ov.data as SessionOverview | null) ?? null)
    setStats((st.data as PlayerStat[] | null) ?? [])
    setMatches((ms.data as MatchRow[] | null) ?? [])
    const map: Record<string, string> = {}
    for (const r of (rs.data as unknown as { id: string; guest_name: string | null; profiles: { display_name: string } | null }[] | null) ?? []) {
      map[r.id] = r.guest_name ?? r.profiles?.display_name ?? '이름 없음'
    }
    setNames(map)
    setLoaded(true)
  }, [sessionId])

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
  const playing = matches.filter((m) => m.status === 'playing')
  const queued = matches
    .filter((m) => m.status === 'queued')
    .sort((a, b) => (a.queue_pos ?? 0) - (b.queue_pos ?? 0) || a.created_at.localeCompare(b.created_at))

  if (!loaded) return <Page><Spinner /></Page>
  if (!s) return <Page title="대진판"><Card><p className="text-sm text-neutral-500">운동을 찾을 수 없어요.</p></Card></Page>

  const nameOf = (id: string) => byId[id]?.name ?? names[id] ?? '?'

  return (
    <Page>
      <Link to={`/c/${club.id}/s/${s.id}`} className="mb-3 inline-block text-sm text-neutral-500">
        ← {s.title}
      </Link>
      <div className="mb-3 flex items-baseline justify-between">
        <h1 className="text-xl font-bold text-neutral-900">대진판</h1>
        <span className="text-sm text-neutral-500">
          {formatTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)} · 코트 {s.court_count}면
        </span>
      </div>
      {s.canceled_at && <ErrorText>취소된 운동이에요.</ErrorText>}
      {!canOperate && !s.canceled_at && <p className="mb-3 text-sm text-neutral-500">참석 확정자와 운영진만 대진을 바꿀 수 있어요. 보기만 가능해요.</p>}

      <Courts s={s} playing={playing} now={now} nameOf={nameOf} canOperate={canOperate} onChanged={load} />
      <Queue queued={queued} nameOf={nameOf} canOperate={canOperate} onChanged={load} />
      <Players sessionId={s.id} players={players} canOperate={canOperate && !s.canceled_at} onChanged={load} />
      <ErrorText>{error}</ErrorText>
    </Page>
  )
}

/** 실수로 누르기 쉬운 버튼: 첫 탭은 확인 상태로, 3초 안에 다시 누르면 실행 */
function ConfirmButton({
  label,
  confirmLabel,
  onConfirm,
  variant = 'secondary',
  className = '',
  disabled,
}: {
  label: string
  confirmLabel: string
  onConfirm: () => void
  variant?: 'primary' | 'secondary' | 'danger'
  className?: string
  disabled?: boolean
}) {
  const [armed, setArmed] = useState(false)
  useEffect(() => {
    if (!armed) return
    const t = setTimeout(() => setArmed(false), 3000)
    return () => clearTimeout(t)
  }, [armed])
  return (
    <Button
      variant={armed ? 'danger' : variant}
      className={className}
      disabled={disabled}
      onClick={() => {
        if (armed) {
          setArmed(false)
          onConfirm()
        } else setArmed(true)
      }}
    >
      {armed ? confirmLabel : label}
    </Button>
  )
}

function Courts({
  s,
  playing,
  now,
  nameOf,
  canOperate,
  onChanged,
}: {
  s: SessionOverview
  playing: MatchRow[]
  now: number
  nameOf: (id: string) => string
  canOperate: boolean
  onChanged: () => Promise<void>
}) {
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState('')
  const courts = Array.from({ length: s.court_count }, (_, i) => i + 1)

  const act = async (matchId: string, rpc: 'finish_match' | 'cancel_match') => {
    setBusy(matchId)
    setError('')
    const { error } = await supabase.rpc(rpc, { p_match: matchId })
    if (error) setError(errorMessage(error))
    await onChanged()
    setBusy(null)
  }

  return (
    <section>
      <div className="grid grid-cols-1 gap-2">
        {courts.map((no) => {
          const m = playing.find((x) => x.court_no === no)
          return (
            <Card key={no} className={m ? '' : 'bg-neutral-50 shadow-none'}>
              <div className="flex items-center justify-between">
                <span className="text-sm font-semibold text-neutral-500">코트 {no}</span>
                {m?.started_at && <span className="text-sm tabular-nums text-neutral-500">{Math.max(0, Math.floor((now - Date.parse(m.started_at)) / 60000))}분</span>}
              </div>
              {m ? (
                <>
                  <div className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1">
                    {m.match_players.map((p) => (
                      <span key={p.registration_id} className="truncate font-medium text-neutral-900">
                        {nameOf(p.registration_id)}
                      </span>
                    ))}
                  </div>
                  {canOperate && (
                    <div className="mt-3 flex gap-2">
                      <ConfirmButton label="취소" confirmLabel="경기 취소?" className="h-10" disabled={busy === m.id} onConfirm={() => void act(m.id, 'cancel_match')} />
                      <ConfirmButton label="종료" confirmLabel="종료 확인" variant="primary" className="h-10 flex-1" disabled={busy === m.id} onConfirm={() => void act(m.id, 'finish_match')} />
                    </div>
                  )}
                </>
              ) : (
                <p className="mt-2 text-sm text-neutral-400">비어 있음 · 경기를 만들면 바로 들어가요</p>
              )}
            </Card>
          )
        })}
      </div>
      <ErrorText>{error}</ErrorText>
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
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const run = async (fn: () => PromiseLike<{ error: unknown }>) => {
    setBusy(true)
    setError('')
    const { error } = await fn()
    if (error) setError(errorMessage(error))
    await onChanged()
    setBusy(false)
  }

  return (
    <section className="mt-6">
      <h2 className="mb-2 text-sm font-semibold text-neutral-500">대기 경기 {queued.length}</h2>
      {queued.length === 0 ? (
        <p className="text-sm text-neutral-500">대기 중인 경기가 없어요.</p>
      ) : (
        <Card className="divide-y divide-neutral-100 p-0">
          {queued.map((m, i) => (
            <div key={m.id} className="flex items-center gap-2 px-3 py-2.5">
              <span className="w-5 shrink-0 text-right text-sm tabular-nums text-neutral-400">{i + 1}</span>
              <span className="min-w-0 flex-1 truncate text-[15px] text-neutral-900">{m.match_players.map((p) => nameOf(p.registration_id)).join(' · ')}</span>
              {canOperate && (
                <div className="flex shrink-0 items-center gap-1">
                  <button className="h-9 w-9 rounded-lg bg-neutral-100 text-neutral-700 disabled:opacity-30" disabled={busy || i === 0} onClick={() => void run(() => supabase.rpc('move_match', { p_match: m.id, p_direction: -1 }))} aria-label="위로">
                    ▲
                  </button>
                  <button className="h-9 w-9 rounded-lg bg-neutral-100 text-neutral-700 disabled:opacity-30" disabled={busy || i === queued.length - 1} onClick={() => void run(() => supabase.rpc('move_match', { p_match: m.id, p_direction: 1 }))} aria-label="아래로">
                    ▼
                  </button>
                  <ConfirmButton label="✕" confirmLabel="삭제?" className="h-9 px-3" disabled={busy} onConfirm={() => void run(() => supabase.rpc('cancel_match', { p_match: m.id }))} />
                </div>
              )}
            </div>
          ))}
        </Card>
      )}
      <ErrorText>{error}</ErrorText>
    </section>
  )
}

function Players({
  sessionId,
  players,
  canOperate,
  onChanged,
}: {
  sessionId: string
  players: Player[]
  canOperate: boolean
  onChanged: () => Promise<void>
}) {
  const [selected, setSelected] = useState<string[]>([])
  const [warned, setWarned] = useState(false)
  const [guest, setGuest] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  // 선택한 사람이 명단에서 빠지면(참석 취소 등) 선택에서도 뺀다
  const valid = selected.filter((id) => players.some((p) => p.registration_id === id))
  const busyPeople = valid.filter((id) => {
    const p = players.find((x) => x.registration_id === id)
    return p && (p.is_playing || p.queued_count > 0)
  })

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
    setError('')
    const { error } = await supabase.rpc('create_match', { p_session: sessionId, p_registrations: valid })
    setBusy(false)
    if (error) {
      setError(errorMessage(error))
      return
    }
    setSelected([])
    setWarned(false)
    await onChanged()
  }

  const checkIn = async (id: string) => {
    setError('')
    const { error } = await supabase.rpc('set_checked_in', { p_registration: id, p_checked_in: true })
    if (error) setError(errorMessage(error))
    await onChanged()
  }

  const addGuest = async (e: FormEvent) => {
    e.preventDefault()
    if (!guest.trim()) return
    setBusy(true)
    setError('')
    const { error } = await supabase.rpc('add_guest', { p_session: sessionId, p_name: guest.trim() })
    setBusy(false)
    if (error) setError(errorMessage(error))
    else setGuest('')
    await onChanged()
  }

  return (
    <section className="mt-6 pb-24">
      <h2 className="mb-2 text-sm font-semibold text-neutral-500">
        참석자 {players.length} <span className="font-normal">· 게임 수 적은 순{canOperate && ', 4명을 눌러 경기 만들기'}</span>
      </h2>
      <Card className="divide-y divide-neutral-100 p-0">
        {players.map((p) => {
          const isSel = valid.includes(p.registration_id)
          const arrived = p.restMin !== null
          const longRest = arrived && !p.is_playing && p.queued_count === 0 && (p.restMin ?? 0) >= REST_ALERT_MIN
          return (
            <div
              key={p.registration_id}
              role={canOperate ? 'button' : undefined}
              onClick={canOperate ? () => toggle(p.registration_id) : undefined}
              className={`flex items-center gap-2 px-3 py-2.5 ${isSel ? 'bg-blue-50 ring-2 ring-inset ring-blue-500' : longRest ? 'bg-amber-50' : ''} ${arrived ? '' : 'opacity-60'} ${canOperate ? 'cursor-pointer select-none' : ''}`}
            >
              <span className="w-8 shrink-0 text-center text-lg font-bold tabular-nums text-neutral-900">{p.games}</span>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-1.5">
                  <span className="truncate font-medium text-neutral-900">{p.name}</span>
                  {p.level && <Badge>{p.level}</Badge>}
                  {p.kind === 'guest' && <Badge>게스트</Badge>}
                </div>
                <p className="text-xs text-neutral-500">
                  {!arrived
                    ? p.late_eta
                      ? `미도착 · ${trimSeconds(p.late_eta)} 예정`
                      : '미도착'
                    : p.is_playing
                      ? '경기 중'
                      : `${p.restMin}분 쉬는 중${p.queued_count > 0 ? ` · 대기 경기 ${p.queued_count}` : ''}`}
                </p>
              </div>
              {p.is_playing && <Badge tone="blue">경기 중</Badge>}
              {!p.is_playing && p.queued_count > 0 && <Badge tone="amber">대기</Badge>}
              {!arrived && canOperate && (
                <button
                  className="shrink-0 rounded-lg bg-neutral-900 px-3 py-1.5 text-sm font-semibold text-white"
                  onClick={(e) => {
                    e.stopPropagation()
                    void checkIn(p.registration_id)
                  }}
                >
                  도착
                </button>
              )}
            </div>
          )
        })}
      </Card>
      <p className="mt-1 text-xs text-neutral-400">왼쪽 숫자 = 오늘 게임 수. {REST_ALERT_MIN}분 이상 쉰 사람은 노란색으로 표시돼요. 쉰 시간은 도착(체크인) 이후부터 세요.</p>

      {canOperate && (
        <form onSubmit={addGuest} className="mt-4 flex gap-2">
          <Input value={guest} onChange={(e) => setGuest(e.target.value)} maxLength={30} placeholder="게스트 이름" className="mt-0" />
          <Button type="submit" variant="secondary" disabled={busy || !guest.trim()}>
            게스트 추가
          </Button>
        </form>
      )}
      <ErrorText>{error}</ErrorText>

      {canOperate && valid.length > 0 && (
        <div className="fixed inset-x-0 bottom-0 z-20 border-t border-neutral-200 bg-white/95 backdrop-blur">
          <div className="mx-auto max-w-md px-4 py-3">
            {warned && busyPeople.length > 0 && (
              <p className="mb-2 text-sm text-amber-800">
                {busyPeople.map((id) => players.find((p) => p.registration_id === id)?.name).join(', ')}님은 이미 경기 중이거나 대기 경기에 있어요. 그래도 만들려면 한 번 더 누르세요.
              </p>
            )}
            <div className="flex gap-2">
              <Button variant="secondary" onClick={() => { setSelected([]); setWarned(false) }}>
                해제
              </Button>
              <Button className="flex-1" disabled={busy || valid.length !== 4} onClick={() => void createMatch()}>
                {valid.length === 4 ? (warned ? '그래도 경기 만들기' : '경기 만들기') : `${valid.length}/4명 선택`}
              </Button>
            </div>
          </div>
        </div>
      )}
    </section>
  )
}
