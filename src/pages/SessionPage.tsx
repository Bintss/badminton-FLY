import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { Field, Input } from '../components/form'
import { Badge, Button, Card, ErrorText, Page, Spinner } from '../components/ui'
import { DEFAULT_TZ, formatDateTime, formatTime, toDateInput, toTimeInput, trimSeconds, zonedToIso } from '../lib/datetime'
import { useCountdownNow } from '../lib/serverTime'
import { PHASE_LABEL, sessionPhase } from '../lib/sessionStatus'
import { errorMessage, supabase } from '../lib/supabase'
import type { RegistrationRow, SessionOverview } from '../lib/types'

function formatLeft(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000))
  const d = Math.floor(total / 86400)
  const h = Math.floor((total % 86400) / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const hms = `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  return d > 0 ? `${d}일 ${hms}` : hms
}

export default function SessionPage() {
  const { sessionId } = useParams()
  const { club, isAdmin } = useClub()
  const { session: auth } = useAuth()
  const tz = club.timezone ?? DEFAULT_TZ
  const uid = auth?.user.id

  const [s, setS] = useState<SessionOverview | null>(null)
  const [regs, setRegs] = useState<RegistrationRow[]>([])
  const [levels, setLevels] = useState<Record<string, string>>({})
  const [hostName, setHostName] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    if (!sessionId) return
    const [ov, rs] = await Promise.all([
      supabase.from('session_overview').select('*').eq('id', sessionId).maybeSingle(),
      supabase
        .from('registrations')
        .select('id, session_id, kind, user_id, guest_name, status, seq, late_eta, checked_in_at, created_at, promoted_at, profiles!registrations_user_id_fkey(display_name)')
        .eq('session_id', sessionId)
        .neq('status', 'canceled')
        .order('seq'),
    ])
    if (ov.error || rs.error) setError(errorMessage(ov.error ?? rs.error))
    setS((ov.data as SessionOverview | null) ?? null)
    setRegs((rs.data as unknown as RegistrationRow[] | null) ?? [])
    setLoaded(true)
  }, [sessionId])

  useEffect(() => {
    void load()
  }, [load])

  // 급수(표시용)
  useEffect(() => {
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
  }, [club.id])

  // 번개 개설자 이름
  useEffect(() => {
    if (!s?.host_user_id || s.type !== 'flash') return
    supabase
      .from('profiles')
      .select('display_name')
      .eq('id', s.host_user_id)
      .maybeSingle()
      .then(({ data }) => setHostName((data?.display_name as string | undefined) ?? null))
  }, [s?.host_user_id, s?.type])

  // 실시간 갱신. 오픈 순간 수십 건이 몰리므로 이벤트마다 바로 다시 읽지 않고 모아서 한 번 읽는다
  // (기기마다 0.8~1.5초 사이 무작위로 퍼뜨려 동시 재조회 폭주를 막는다)
  const reloadTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (!sessionId) return
    const schedule = () => {
      if (reloadTimer.current) return
      reloadTimer.current = setTimeout(() => {
        reloadTimer.current = null
        void load()
      }, 800 + Math.random() * 700)
    }
    const channel = supabase
      .channel(`session:${sessionId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'registrations', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'sessions', filter: `id=eq.${sessionId}` }, schedule)
      .subscribe()
    return () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current)
      reloadTimer.current = null
      void supabase.removeChannel(channel)
    }
  }, [sessionId, load])

  const now = useCountdownNow(s ? Date.parse(s.opens_at) : 0)

  const confirmed = useMemo(() => regs.filter((r) => r.status === 'confirmed'), [regs])
  const waitlist = useMemo(() => regs.filter((r) => r.kind === 'member' && r.status === 'waitlisted'), [regs])

  if (!loaded) return <Page><Spinner /></Page>
  if (!s) {
    return (
      <Page title="운동">
        <Card>
          <p className="text-sm text-neutral-500">운동을 찾을 수 없어요.</p>
          <Link to={`/c/${club.id}`} className="mt-2 inline-block text-sm text-neutral-900 underline">
            일정으로
          </Link>
        </Card>
        <ErrorText>{error}</ErrorText>
      </Page>
    )
  }

  const phase = sessionPhase(s, now)
  const canManage = isAdmin || (s.type === 'flash' && s.host_user_id === uid)
  const memberConfirmed = confirmed.filter((r) => r.kind === 'member')
  const myReg = regs.find((r) => r.kind === 'member' && r.user_id === uid) ?? null
  const myPosition = myReg
    ? (myReg.status === 'confirmed' ? memberConfirmed : waitlist).findIndex((r) => r.id === myReg.id) + 1
    : 0

  return (
    <Page>
      <Link to={`/c/${club.id}`} className="mb-3 inline-block text-sm text-neutral-500">
        ← 일정
      </Link>

      <Card>
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <div className="flex items-center gap-1.5">
              <Badge tone={s.type === 'regular' ? 'blue' : 'neutral'}>{s.type === 'regular' ? '정기' : '번개'}</Badge>
              <h1 className="truncate text-lg font-bold text-neutral-900">{s.title}</h1>
            </div>
            <p className="mt-1 text-neutral-800">
              {formatDateTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}
            </p>
            <p className="text-sm text-neutral-500">
              {s.place || '장소 미정'} · 코트 {s.court_count}면{hostName && ` · 개설 ${hostName}`}
            </p>
          </div>
          <span className="shrink-0 rounded-md bg-neutral-100 px-2 py-1 text-xs font-semibold text-neutral-700">{PHASE_LABEL[phase]}</span>
        </div>
      </Card>

      {phase !== 'canceled' && now >= Date.parse(s.starts_at) - 3 * 3600_000 && now < Date.parse(s.ends_at) + 3 * 3600_000 && (
        <Link to="board" className="mt-3 block">
          <Card className="flex items-center justify-between bg-neutral-900 ring-neutral-900">
            <span className="font-semibold text-white">대진판 열기</span>
            <span className="text-sm text-neutral-300">코트 현황 · 경기 만들기</span>
          </Card>
        </Link>
      )}

      <ActionCard s={s} phase={phase} now={now} tz={tz} myReg={myReg} myPosition={myPosition} onChanged={load} />

      {canManage && phase !== 'canceled' && phase !== 'ended' && <ManageCard s={s} now={now} tz={tz} onChanged={load} />}

      <section className="mt-6">
        <h2 className="mb-2 text-sm font-semibold text-neutral-500">
          참석 {memberConfirmed.length}/{s.capacity}
          {confirmed.length > memberConfirmed.length && ` · 게스트 ${confirmed.length - memberConfirmed.length}`}
        </h2>
        {confirmed.length === 0 ? (
          <p className="text-sm text-neutral-500">아직 신청한 사람이 없어요.</p>
        ) : (
          <Card className="divide-y divide-neutral-100 p-0">
            {confirmed.map((r, i) => (
              <PersonRow key={r.id} index={i + 1} r={r} level={r.user_id ? levels[r.user_id] : undefined} me={r.user_id === uid} />
            ))}
          </Card>
        )}
      </section>

      {waitlist.length > 0 && (
        <section className="mt-6">
          <h2 className="mb-2 text-sm font-semibold text-neutral-500">대기 {waitlist.length}</h2>
          <Card className="divide-y divide-neutral-100 p-0">
            {waitlist.map((r, i) => (
              <PersonRow key={r.id} index={i + 1} r={r} level={r.user_id ? levels[r.user_id] : undefined} me={r.user_id === uid} />
            ))}
          </Card>
        </section>
      )}
      <ErrorText>{error}</ErrorText>
    </Page>
  )
}

function PersonRow({ index, r, level, me }: { index: number; r: RegistrationRow; level?: string; me: boolean }) {
  const name = r.kind === 'guest' ? r.guest_name : r.profiles?.display_name
  return (
    <div className={`flex items-center justify-between gap-2 px-4 py-2.5 ${me ? 'bg-blue-50' : ''}`}>
      <div className="flex min-w-0 items-center gap-2">
        <span className="w-6 shrink-0 text-right text-sm tabular-nums text-neutral-400">{index}</span>
        <span className="truncate font-medium text-neutral-900">{name ?? '이름 없음'}</span>
        {level && <Badge>{level}</Badge>}
        {r.kind === 'guest' && <Badge>게스트</Badge>}
      </div>
      {r.late_eta && <span className="shrink-0 text-sm text-amber-700">늦참 {trimSeconds(r.late_eta)}</span>}
    </div>
  )
}

function ActionCard({
  s,
  phase,
  now,
  tz,
  myReg,
  myPosition,
  onChanged,
}: {
  s: SessionOverview
  phase: ReturnType<typeof sessionPhase>
  now: number
  tz: string
  myReg: RegistrationRow | null
  myPosition: number
  onChanged: () => Promise<void>
}) {
  const [late, setLate] = useState(false)
  const [lateTime, setLateTime] = useState(() => toTimeInput(Date.parse(s.starts_at) + 60 * 60 * 1000, tz))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState('')
  const [confirmCancel, setConfirmCancel] = useState(false)

  const register = async () => {
    setBusy(true)
    setError('')
    setResult('')
    const t0 = performance.now()
    const { data, error } = await supabase.rpc('register', { p_session: s.id, p_late_eta: late ? lateTime : null })
    const ms = Math.round(performance.now() - t0)
    setBusy(false)
    if (error) {
      setError(errorMessage(error))
      return
    }
    const row = (Array.isArray(data) ? data[0] : data) as { status: string; queue_position: number } | undefined
    if (row) {
      setResult(`${row.status === 'confirmed' ? `참석 확정 ${row.queue_position}번째` : `대기 ${row.queue_position}번`} · 서버 응답 ${ms}ms`)
    }
    await onChanged()
  }

  const cancel = async () => {
    if (!myReg) return
    setBusy(true)
    setError('')
    const { error } = await supabase.rpc('cancel_registration', { p_registration: myReg.id })
    setBusy(false)
    setConfirmCancel(false)
    setResult('')
    if (error) setError(errorMessage(error))
    await onChanged()
  }

  const saveLate = async (value: string | null) => {
    if (!myReg) return
    setBusy(true)
    setError('')
    const { error } = await supabase.rpc('set_late_eta', { p_registration: myReg.id, p_late_eta: value })
    setBusy(false)
    if (error) setError(errorMessage(error))
    await onChanged()
  }

  if (phase === 'canceled') {
    return (
      <Card className="mt-3">
        <p className="text-sm text-neutral-600">취소된 운동이에요.</p>
      </Card>
    )
  }

  // 이미 신청함
  if (myReg) {
    return (
      <Card className="mt-3">
        <div className="flex items-center justify-between">
          <p className="text-lg font-bold text-neutral-900">
            {myReg.status === 'confirmed' ? `참석 확정 · ${myPosition}번째` : `대기 ${myPosition}번`}
          </p>
          {myReg.status === 'waitlisted' && <Badge tone="amber">취소자 생기면 자동 확정</Badge>}
        </div>
        {result && <p className="mt-1 text-sm text-neutral-500">{result}</p>}

        {phase !== 'ended' && (
          <div className="mt-4 flex items-end gap-2">
            <Field label="늦참 도착 예정">
              <Input type="time" defaultValue={myReg.late_eta ? trimSeconds(myReg.late_eta) : ''} key={myReg.late_eta ?? 'none'} onBlur={(e) => {
                const v = e.target.value || null
                if (v !== (myReg.late_eta ? trimSeconds(myReg.late_eta) : null)) void saveLate(v)
              }} />
            </Field>
            {myReg.late_eta && (
              <Button variant="secondary" disabled={busy} onClick={() => void saveLate(null)}>
                늦참 취소
              </Button>
            )}
          </div>
        )}

        {phase !== 'ended' && (
          <div className="mt-4">
            {!confirmCancel ? (
              <Button variant="danger" className="w-full" disabled={busy} onClick={() => setConfirmCancel(true)}>
                참석 취소
              </Button>
            ) : (
              <div className="flex gap-2">
                <Button variant="secondary" className="flex-1" disabled={busy} onClick={() => setConfirmCancel(false)}>
                  돌아가기
                </Button>
                <Button variant="danger" className="flex-1" disabled={busy} onClick={() => void cancel()}>
                  정말 취소
                </Button>
              </div>
            )}
            {myReg.status === 'confirmed' && <p className="mt-2 text-xs text-neutral-400">취소하면 대기 1번이 자동으로 확정돼요.</p>}
          </div>
        )}
        <ErrorText>{error}</ErrorText>
      </Card>
    )
  }

  // 아직 신청 안 함
  const opensMs = Date.parse(s.opens_at)
  const canTry = phase === 'open' || phase === 'full'
  const closed = phase === 'in_progress' || phase === 'ended'

  return (
    <Card className="mt-3">
      {phase === 'before_open' && (
        <div className="mb-3 text-center">
          <p className="text-sm text-neutral-500">{formatDateTime(s.opens_at, tz)} 오픈</p>
          <p className="mt-1 text-3xl font-bold tabular-nums text-neutral-900">{formatLeft(opensMs - now)}</p>
        </div>
      )}

      {!closed && (
        <label className="mb-3 flex items-center gap-3 text-sm text-neutral-700">
          <input type="checkbox" checked={late} onChange={(e) => setLate(e.target.checked)} className="h-4 w-4" />
          늦참
          {late && <Input type="time" value={lateTime} onChange={(e) => setLateTime(e.target.value)} className="mt-0 h-9 w-32" />}
        </label>
      )}

      <Button className="h-14 w-full text-lg" disabled={!canTry || busy} onClick={() => void register()}>
        {closed ? '신청 마감' : phase === 'before_open' ? '오픈 전' : busy ? '신청 중…' : phase === 'full' ? '대기 신청' : '참석 신청'}
      </Button>
      {phase === 'full' && <p className="mt-2 text-xs text-neutral-500">정원이 찼어요. 대기로 신청하면 취소자가 생길 때 순서대로 확정돼요.</p>}
      {result && <p className="mt-2 text-sm text-neutral-600">{result}</p>}
      <ErrorText>{error}</ErrorText>
    </Card>
  )
}

function ManageCard({ s, now, tz, onChanged }: { s: SessionOverview; now: number; tz: string; onChanged: () => Promise<void> }) {
  const [capacity, setCapacity] = useState(s.capacity)
  const [editing, setEditing] = useState(false)
  const [confirmCancel, setConfirmCancel] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [info, setInfo] = useState('')

  const [title, setTitle] = useState(s.title)
  const [place, setPlace] = useState(s.place)
  const [date, setDate] = useState(toDateInput(s.starts_at, tz))
  const [start, setStart] = useState(toTimeInput(s.starts_at, tz))
  const [end, setEnd] = useState(toTimeInput(s.ends_at, tz))
  const [courts, setCourts] = useState(s.court_count)
  const [openDate, setOpenDate] = useState(toDateInput(s.opens_at, tz))
  const [openTime, setOpenTime] = useState(toTimeInput(s.opens_at, tz))
  const opened = now >= Date.parse(s.opens_at)

  const run = async (fn: () => PromiseLike<{ error: unknown; data?: unknown }>, okText: (data: unknown) => string) => {
    setBusy(true)
    setError('')
    setInfo('')
    const { error, data } = await fn()
    setBusy(false)
    if (error) {
      setError(errorMessage(error))
      return false
    }
    setInfo(okText(data))
    await onChanged()
    return true
  }

  const changeCapacity = () =>
    run(
      () => supabase.rpc('update_capacity', { p_session: s.id, p_capacity: capacity }),
      (promoted) => (typeof promoted === 'number' && promoted > 0 ? `정원을 바꿨어요. 대기자 ${promoted}명이 확정됐어요.` : '정원을 바꿨어요.'),
    )

  const saveEdit = async (e: FormEvent) => {
    e.preventDefault()
    const ok = await run(
      () =>
        supabase.rpc('update_session', {
          p_session: s.id,
          p_title: title.trim() || s.title,
          p_place: place,
          p_starts_at: zonedToIso(date, start, tz),
          p_ends_at: zonedToIso(date, end, tz),
          p_court_count: courts,
          // 이미 열린 투표는 오픈 시각을 그대로 보낸다 (서버도 변경을 거부)
          p_opens_at: opened ? s.opens_at : zonedToIso(openDate, openTime, tz),
        }),
      () => '일정을 수정했어요.',
    )
    if (ok) setEditing(false)
  }

  const cancelSession = () => run(() => supabase.rpc('cancel_session', { p_session: s.id }), () => '운동을 취소했어요.')

  return (
    <Card className="mt-3">
      <h2 className="text-sm font-semibold text-neutral-500">관리</h2>

      <div className="mt-3 flex items-end gap-2">
        <Field label="정원">
          <Input type="number" min={1} max={200} value={capacity} onChange={(e) => setCapacity(Number(e.target.value))} />
        </Field>
        <Button variant="secondary" disabled={busy || capacity === s.capacity} onClick={() => void changeCapacity()}>
          변경
        </Button>
      </div>
      <p className="mt-1 text-xs text-neutral-400">늘리면 대기자가 순서대로 확정돼요. 현재 확정 인원보다 적게는 줄일 수 없어요.</p>

      {!editing ? (
        <Button variant="secondary" className="mt-4 w-full" onClick={() => setEditing(true)}>
          일정 수정
        </Button>
      ) : (
        <form onSubmit={saveEdit} className="mt-4 space-y-3">
          <Field label="제목">
            <Input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={50} />
          </Field>
          <Field label="장소">
            <Input value={place} onChange={(e) => setPlace(e.target.value)} />
          </Field>
          <Field label="날짜">
            <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
          </Field>
          <div className="grid grid-cols-3 gap-2">
            <Field label="시작">
              <Input type="time" value={start} onChange={(e) => setStart(e.target.value)} required />
            </Field>
            <Field label="끝">
              <Input type="time" value={end} onChange={(e) => setEnd(e.target.value)} required />
            </Field>
            <Field label="코트">
              <Input type="number" min={1} max={30} value={courts} onChange={(e) => setCourts(Number(e.target.value))} required />
            </Field>
          </div>
          <Field label="투표 오픈" hint={opened ? '이미 투표가 열려서 바꿀 수 없어요.' : undefined}>
            <div className="grid grid-cols-2 gap-2">
              <Input type="date" value={openDate} onChange={(e) => setOpenDate(e.target.value)} disabled={opened} required />
              <Input type="time" value={openTime} onChange={(e) => setOpenTime(e.target.value)} disabled={opened} required />
            </div>
          </Field>
          <div className="flex gap-2">
            <Button type="button" variant="secondary" className="flex-1" onClick={() => setEditing(false)}>
              닫기
            </Button>
            <Button type="submit" className="flex-1" disabled={busy}>
              저장
            </Button>
          </div>
        </form>
      )}

      {!confirmCancel ? (
        <Button variant="danger" className="mt-3 w-full" onClick={() => setConfirmCancel(true)}>
          운동 취소
        </Button>
      ) : (
        <div className="mt-3 flex gap-2">
          <Button variant="secondary" className="flex-1" onClick={() => setConfirmCancel(false)}>
            돌아가기
          </Button>
          <Button variant="danger" className="flex-1" disabled={busy} onClick={() => void cancelSession()}>
            정말 취소
          </Button>
        </div>
      )}
      {info && <p className="mt-2 text-sm text-green-700">{info}</p>}
      <ErrorText>{error}</ErrorText>
    </Card>
  )
}
