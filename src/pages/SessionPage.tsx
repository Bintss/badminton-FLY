import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { Field, Input } from '../components/form'
import { IconChevronLeft, IconChevronRight, IconCourt } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, List, Page, SectionTitle, Skeleton } from '../components/ui'
import { DEFAULT_TZ, formatDateTime, formatTime, toDateInput, toTimeInput, trimSeconds, zonedToIso } from '../lib/datetime'
import { useCountdownNow } from '../lib/serverTime'
import { PHASE_LABEL, sessionPhase, type SessionPhase } from '../lib/sessionStatus'
import { errorMessage, supabase } from '../lib/supabase'
import type { RegistrationRow, SessionOverview } from '../lib/types'

function splitLeft(ms: number) {
  const total = Math.max(0, Math.ceil(ms / 1000))
  return {
    d: Math.floor(total / 86400),
    h: Math.floor((total % 86400) / 3600),
    m: Math.floor((total % 3600) / 60),
    s: total % 60,
  }
}
const pad = (n: number) => String(n).padStart(2, '0')

export default function SessionPage() {
  const { sessionId } = useParams()
  const { club, isAdmin } = useClub()
  const { session: auth } = useAuth()
  const toast = useToast()
  const tz = club.timezone ?? DEFAULT_TZ
  const uid = auth?.user.id

  const [s, setS] = useState<SessionOverview | null>(null)
  const [regs, setRegs] = useState<RegistrationRow[]>([])
  const [levels, setLevels] = useState<Record<string, string>>({})
  const [hostName, setHostName] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)

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
    if (ov.error || rs.error) toast.error(errorMessage(ov.error ?? rs.error))
    setS((ov.data as SessionOverview | null) ?? null)
    setRegs((rs.data as unknown as RegistrationRow[] | null) ?? [])
    setLoaded(true)
  }, [sessionId, toast])

  useEffect(() => {
    void load()
  }, [load])

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

  const back = (
    <Link to={`/c/${club.id}`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      일정
    </Link>
  )

  if (!loaded) {
    return (
      <Page back={back}>
        <Skeleton className="h-7 w-2/3" />
        <Skeleton className="mt-3 h-4 w-1/2" />
        <Skeleton className="mt-6 h-40 w-full rounded-2xl" />
      </Page>
    )
  }
  if (!s) {
    return (
      <Page back={back}>
        <Empty title="운동을 찾을 수 없어요">취소됐거나 다른 동아리의 운동일 수 있어요.</Empty>
      </Page>
    )
  }

  const phase = sessionPhase(s, now)
  const canManage = isAdmin || (s.type === 'flash' && s.host_user_id === uid)
  const memberConfirmed = confirmed.filter((r) => r.kind === 'member')
  const guests = confirmed.length - memberConfirmed.length
  const myReg = regs.find((r) => r.kind === 'member' && r.user_id === uid) ?? null
  const myPosition = myReg ? (myReg.status === 'confirmed' ? memberConfirmed : waitlist).findIndex((r) => r.id === myReg.id) + 1 : 0
  const boardOpen = phase !== 'canceled' && now >= Date.parse(s.starts_at) - 3 * 3600_000 && now < Date.parse(s.ends_at) + 3 * 3600_000

  return (
    <Page back={back}>
      {/* 운동 정보 */}
      <div className="mb-4">
        <div className="flex items-center gap-2">
          {s.type === 'flash' && <Badge tone="shuttle">번개</Badge>}
          <span className={`text-[13px] font-bold ${phase === 'open' || phase === 'in_progress' ? 'text-court-600' : 'text-ink-soft'}`}>{PHASE_LABEL[phase]}</span>
        </div>
        <h1 className={`mt-1 text-[24px] font-bold leading-tight tracking-tight text-ink ${phase === 'canceled' ? 'line-through opacity-60' : ''}`}>{s.title}</h1>
        <p className="mt-1.5 text-[16px] font-medium text-ink">
          {formatDateTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}
        </p>
        <p className="text-sm text-ink-soft">
          {s.place || '장소 미정'}, 코트 {s.court_count}면{hostName && `, ${hostName}님이 열었어요`}
        </p>
      </div>

      {boardOpen && (
        <Link to="board" className="mb-3 flex items-center justify-between rounded-2xl bg-court-600 px-4 py-3.5 text-white active:bg-court-700">
          <span className="flex items-center gap-2 font-semibold">
            <IconCourt className="h-5 w-5" />
            대진판 열기
          </span>
          <IconChevronRight className="h-5 w-5 text-white/70" />
        </Link>
      )}

      <ActionCard s={s} phase={phase} now={now} tz={tz} myReg={myReg} myPosition={myPosition} onChanged={load} />

      {canManage && phase !== 'canceled' && phase !== 'ended' && <ManageCard s={s} now={now} tz={tz} onChanged={load} />}

      <SectionTitle right={guests > 0 ? `게스트 ${guests}명` : undefined}>
        참석 <span className="score text-[17px]">{memberConfirmed.length}/{s.capacity}</span>
      </SectionTitle>
      {confirmed.length === 0 ? (
        <Empty title="아직 신청한 사람이 없어요" />
      ) : (
        <List>
          {confirmed.map((r, i) => (
            <PersonRow key={r.id} index={i + 1} r={r} level={r.user_id ? levels[r.user_id] : undefined} me={r.user_id === uid} />
          ))}
        </List>
      )}

      {waitlist.length > 0 && (
        <>
          <SectionTitle right="취소자가 생기면 순서대로 확정">
            대기 <span className="score text-[17px]">{waitlist.length}</span>
          </SectionTitle>
          <List>
            {waitlist.map((r, i) => (
              <PersonRow key={r.id} index={i + 1} r={r} level={r.user_id ? levels[r.user_id] : undefined} me={r.user_id === uid} />
            ))}
          </List>
        </>
      )}
    </Page>
  )
}

function PersonRow({ index, r, level, me }: { index: number; r: RegistrationRow; level?: string; me: boolean }) {
  const name = r.kind === 'guest' ? r.guest_name : r.profiles?.display_name
  return (
    <div className={`flex items-center justify-between gap-2 px-4 py-3 ${me ? 'bg-court-50' : ''}`}>
      <div className="flex min-w-0 items-center gap-2.5">
        <span className="score w-6 shrink-0 text-right text-[17px] font-semibold text-ink-faint">{index}</span>
        <span className="truncate font-medium text-ink">{name ?? '이름 없음'}</span>
        {me && <Badge tone="court">나</Badge>}
        {level && <Badge tone="outline">{level}</Badge>}
        {r.kind === 'guest' && <Badge>게스트</Badge>}
      </div>
      {r.late_eta && <span className="shrink-0 text-sm font-medium text-shuttle-800">늦참 {trimSeconds(r.late_eta)}</span>}
    </div>
  )
}

function Countdown({ ms }: { ms: number }) {
  const { d, h, m, s } = splitLeft(ms)
  return (
    <div className="score flex items-baseline justify-center gap-1 text-[56px] font-semibold leading-none text-ink" aria-live="off">
      {d > 0 && (
        <>
          <span>{d}</span>
          <span className="mr-2 text-[22px] text-ink-soft">일</span>
        </>
      )}
      <span>{pad(h)}</span>
      <span className="text-ink-faint">:</span>
      <span>{pad(m)}</span>
      <span className="text-ink-faint">:</span>
      <span className={ms < 60_000 ? 'text-court-600' : ''}>{pad(s)}</span>
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
  phase: SessionPhase
  now: number
  tz: string
  myReg: RegistrationRow | null
  myPosition: number
  onChanged: () => Promise<void>
}) {
  const toast = useToast()
  const [late, setLate] = useState(false)
  const [lateTime, setLateTime] = useState(() => toTimeInput(Date.parse(s.starts_at) + 60 * 60 * 1000, tz))
  const [busy, setBusy] = useState(false)
  const [latency, setLatency] = useState<number | null>(null)
  const [confirmCancel, setConfirmCancel] = useState(false)

  const register = async () => {
    setBusy(true)
    const t0 = performance.now()
    const { data, error } = await supabase.rpc('register', { p_session: s.id, p_late_eta: late ? lateTime : null })
    const ms = Math.round(performance.now() - t0)
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    setLatency(ms)
    const row = (Array.isArray(data) ? data[0] : data) as { status: string; queue_position: number } | undefined
    if (row) toast.success(row.status === 'confirmed' ? `참석 확정, ${row.queue_position}번째예요` : `대기 ${row.queue_position}번으로 신청했어요`)
    await onChanged()
  }

  const cancel = async () => {
    if (!myReg) return
    setBusy(true)
    const { error } = await supabase.rpc('cancel_registration', { p_registration: myReg.id })
    setBusy(false)
    setConfirmCancel(false)
    setLatency(null)
    if (error) toast.error(errorMessage(error))
    else toast.info('참석을 취소했어요')
    await onChanged()
  }

  const saveLate = async (value: string | null) => {
    if (!myReg) return
    setBusy(true)
    const { error } = await supabase.rpc('set_late_eta', { p_registration: myReg.id, p_late_eta: value })
    setBusy(false)
    if (error) toast.error(errorMessage(error))
    else toast.success(value ? `늦참 ${value} 도착으로 저장했어요` : '늦참을 취소했어요')
    await onChanged()
  }

  if (phase === 'canceled') {
    return (
      <Card className="bg-floor">
        <p className="text-sm text-ink-soft">취소된 운동이에요.</p>
      </Card>
    )
  }

  // 이미 신청함
  if (myReg) {
    const isConfirmed = myReg.status === 'confirmed'
    return (
      <Card className={isConfirmed ? 'border-court-200 bg-court-50' : 'border-shuttle-400/40 bg-shuttle-100/60'}>
        <p className={`text-[13px] font-bold ${isConfirmed ? 'text-court-700' : 'text-shuttle-800'}`}>{isConfirmed ? '참석 확정' : '대기 중'}</p>
        <p className="mt-0.5 flex items-baseline gap-1 text-ink">
          <span className="score text-[40px] font-semibold leading-none">{myPosition}</span>
          <span className="text-[17px] font-semibold">{isConfirmed ? '번째' : '번 대기'}</span>
        </p>
        {!isConfirmed && <p className="mt-1 text-sm text-ink-soft">앞사람이 취소하면 자동으로 확정돼요.</p>}
        {latency !== null && <p className="mt-1 text-xs text-ink-faint">서버 응답 {latency}ms</p>}

        {phase !== 'ended' && (
          <>
            <div className="mt-4 flex items-end gap-2">
              <div className="flex-1">
                <Field label="늦참 도착 예정">
                  <Input
                    type="time"
                    defaultValue={myReg.late_eta ? trimSeconds(myReg.late_eta) : ''}
                    key={myReg.late_eta ?? 'none'}
                    onBlur={(e) => {
                      const v = e.target.value || null
                      if (v !== (myReg.late_eta ? trimSeconds(myReg.late_eta) : null)) void saveLate(v)
                    }}
                  />
                </Field>
              </div>
              {myReg.late_eta && (
                <Button variant="secondary" disabled={busy} onClick={() => void saveLate(null)}>
                  늦참 취소
                </Button>
              )}
            </div>

            <div className="mt-4">
              {!confirmCancel ? (
                <Button variant="ghost" className="w-full text-danger" disabled={busy} onClick={() => setConfirmCancel(true)}>
                  참석 취소
                </Button>
              ) : (
                <div className="flex gap-2">
                  <Button variant="secondary" className="flex-1" disabled={busy} onClick={() => setConfirmCancel(false)}>
                    돌아가기
                  </Button>
                  <Button variant="danger" className="flex-1" disabled={busy} onClick={() => void cancel()}>
                    참석 취소하기
                  </Button>
                </div>
              )}
              {confirmCancel && isConfirmed && <p className="mt-2 text-center text-xs text-ink-soft">취소하면 대기 1번이 자동으로 확정돼요.</p>}
            </div>
          </>
        )}
      </Card>
    )
  }

  // 아직 신청 안 함
  const opensMs = Date.parse(s.opens_at)
  const canTry = phase === 'open' || phase === 'full'
  const closed = phase === 'in_progress' || phase === 'ended'

  return (
    <Card>
      {phase === 'before_open' && (
        <div className="pb-4 pt-1 text-center">
          <p className="text-sm font-medium text-ink-soft">{formatDateTime(s.opens_at, tz)}에 투표가 열려요</p>
          <div className="mt-2">
            <Countdown ms={opensMs - now} />
          </div>
        </div>
      )}

      {!closed && (
        <div className="mb-3 flex min-h-12 items-center gap-3">
          <label className="flex items-center gap-2 text-[15px] font-medium text-ink">
            <input type="checkbox" checked={late} onChange={(e) => setLate(e.target.checked)} className="h-5 w-5 accent-court-600" />
            늦게 도착해요
          </label>
          {late && <Input type="time" value={lateTime} onChange={(e) => setLateTime(e.target.value)} className="mt-0 h-10 w-32" aria-label="도착 예정 시각" />}
        </div>
      )}

      <Button className="h-14 w-full text-[17px]" disabled={!canTry || busy} onClick={() => void register()}>
        {closed ? '신청 마감' : phase === 'before_open' ? '오픈 전' : busy ? '신청하는 중' : phase === 'full' ? '대기 신청' : '참석 신청'}
      </Button>
      {phase === 'full' && <p className="mt-2 text-center text-xs text-ink-soft">정원이 찼어요. 대기로 신청하면 취소자가 생길 때 순서대로 확정돼요.</p>}
    </Card>
  )
}

function ManageCard({ s, now, tz, onChanged }: { s: SessionOverview; now: number; tz: string; onChanged: () => Promise<void> }) {
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [capacity, setCapacity] = useState(s.capacity)
  const [editing, setEditing] = useState(false)
  const [confirmCancel, setConfirmCancel] = useState(false)
  const [busy, setBusy] = useState(false)

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
    const { error, data } = await fn()
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return false
    }
    toast.success(okText(data))
    await onChanged()
    return true
  }

  const changeCapacity = () =>
    run(
      () => supabase.rpc('update_capacity', { p_session: s.id, p_capacity: capacity }),
      (promoted) => (typeof promoted === 'number' && promoted > 0 ? `정원을 ${capacity}명으로 바꿨어요. 대기자 ${promoted}명이 확정됐어요` : `정원을 ${capacity}명으로 바꿨어요`),
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
      () => '일정을 수정했어요',
    )
    if (ok) setEditing(false)
  }

  const cancelSession = () => run(() => supabase.rpc('cancel_session', { p_session: s.id }), () => '운동을 취소했어요')

  return (
    <Card className="mt-3">
      <button className="flex w-full items-center justify-between text-left" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="font-semibold text-ink">운동 관리</span>
        <span className="text-sm text-ink-faint">{open ? '접기' : '정원, 일정 수정, 취소'}</span>
      </button>

      {open && (
        <div className="mt-4 border-t border-black/[0.06] pt-4">
          <div className="flex items-end gap-2">
            <div className="flex-1">
              <Field label="정원" hint="늘리면 대기자가 순서대로 확정돼요. 현재 확정 인원보다 적게는 못 줄여요.">
                <Input type="number" min={1} max={200} value={capacity} onChange={(e) => setCapacity(Number(e.target.value))} />
              </Field>
            </div>
            <Button variant="secondary" className="mb-[22px]" disabled={busy || capacity === s.capacity} onClick={() => void changeCapacity()}>
              변경
            </Button>
          </div>

          {!editing ? (
            <Button variant="secondary" className="mt-4 w-full" onClick={() => setEditing(true)}>
              일정 수정
            </Button>
          ) : (
            <form onSubmit={saveEdit} className="mt-4 space-y-3 rounded-xl bg-floor p-3">
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
              <div className="flex gap-2 pt-1">
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
            <Button variant="ghost" className="mt-2 w-full text-danger" onClick={() => setConfirmCancel(true)}>
              운동 취소
            </Button>
          ) : (
            <div className="mt-3 flex gap-2">
              <Button variant="secondary" className="flex-1" onClick={() => setConfirmCancel(false)}>
                돌아가기
              </Button>
              <Button variant="danger" className="flex-1" disabled={busy} onClick={() => void cancelSession()}>
                운동 취소하기
              </Button>
            </div>
          )}
        </div>
      )}
    </Card>
  )
}
