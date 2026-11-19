import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { ConfirmButton } from '../components/ConfirmButton'
import { Field, Input } from '../components/form'
import { GenderMark, GenderToggle } from '../components/GenderToggle'
import { GuestCapacityField } from '../components/GuestCapacityField'
import { LevelSelect, type Level } from '../components/LevelPicker'
import { IconChevronLeft, IconChevronRight, IconCourt } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, Empty, List, Page, SectionTitle, Skeleton } from '../components/ui'
import { DEFAULT_TZ, formatDateTime, formatTime, toDateInput, toTimeInput, trimSeconds, zonedToIso } from '../lib/datetime'
import { useCountdownNow } from '../lib/serverTime'
import { PHASE_LABEL, sessionPhase, type SessionPhase } from '../lib/sessionStatus'
import { errorMessage, supabase } from '../lib/supabase'
import { resubscribeReload, useLatest, useRefetchOnResume } from '../lib/useResume'
import { STATE_LABEL, tournamentActive } from '../lib/tournament'
import type { Gender } from '../lib/autoDraft'
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
  // 교류전: 두 동아리 이름, 참석자 급수(상대 회원 것도)
  const [clubNames, setClubNames] = useState<Record<string, string>>({})
  const [metaLevels, setMetaLevels] = useState<Record<string, string>>({})
  const [loaded, setLoaded] = useState(false)

  const take = useLatest()
  const load = useCallback(async () => {
    if (!sessionId) return
    const ticket = take()
    const [ov, rs] = await Promise.all([
      supabase.from('session_overview').select('*').eq('id', sessionId).maybeSingle(),
      supabase
        .from('registrations')
        .select(
          'id, session_id, kind, user_id, guest_name, guest_gender, guest_level, added_by, side_club_id, status, seq, late_eta, checked_in_at, created_at, promoted_at, profiles!registrations_user_id_fkey(display_name), adder:profiles!registrations_added_by_fkey(display_name)',
        )
        .eq('session_id', sessionId)
        .neq('status', 'canceled')
        .order('seq'),
    ])
    if (!take.isLatest(ticket)) return // 더 최근 요청이 있으면 이 응답은 버린다
    if (ov.error || rs.error) toast.error(errorMessage(ov.error ?? rs.error))
    setS((ov.data as SessionOverview | null) ?? null)
    setRegs((rs.data as unknown as RegistrationRow[] | null) ?? [])
    setLoaded(true)
  }, [sessionId, toast, take])

  useEffect(() => {
    void load()
  }, [load])
  useRefetchOnResume(load)

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

  const exchangeKey = s?.kind === 'exchange' ? `${s.club_id}|${s.partner_club_id}|${regs.length}` : ''
  useEffect(() => {
    if (!exchangeKey || !s) return
    void supabase
      .from('clubs')
      .select('id, name')
      .in('id', [s.club_id, s.partner_club_id].filter(Boolean) as string[])
      .then(({ data }) => setClubNames(Object.fromEntries(((data ?? []) as { id: string; name: string }[]).map((c) => [c.id, c.name]))))
    void supabase.rpc('session_player_meta', { p_session: s.id }).then(({ data }) => {
      const m: Record<string, string> = {}
      for (const x of (data ?? []) as { registration_id: string; level: string | null }[]) if (x.level) m[x.registration_id] = x.level
      setMetaLevels(m)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [exchangeKey])

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
      .subscribe(resubscribeReload(load))
    return () => {
      if (reloadTimer.current) clearTimeout(reloadTimer.current)
      reloadTimer.current = null
      void supabase.removeChannel(channel)
    }
  }, [sessionId, load])

  const now = useCountdownNow(s ? Date.parse(s.opens_at) : 0)

  const confirmed = useMemo(() => regs.filter((r) => r.status === 'confirmed'), [regs])
  // 대기에는 정원을 차지하는 사람만 들어온다 (게스트 정원 포함 설정이면 게스트도)
  const waitlist = useMemo(() => regs.filter((r) => r.status === 'waitlisted'), [regs])

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

  const phase = sessionPhase(s, now, club.id)
  const exchange = s.kind === 'exchange'
  // 운동 관리(정원·일정·취소)는 주최 동아리 운영진과 연 사람만. 교류전 상대 운영진은 상대 정원만
  const hostSide = s.club_id === club.id
  const canManage = hostSide && (isAdmin || (s.type === 'flash' && s.host_user_id === uid))
  const partnerAdmin = exchange && !hostSide && isAdmin
  const sideOfReg = (r: RegistrationRow) => r.side_club_id ?? s.club_id
  const mySide = exchange ? club.id : s.club_id
  const nameOfClub = (id: string | null) => (id ? (clubNames[id] ?? (id === club.id ? club.name : '상대 동아리')) : '')
  // 정원을 차지한 확정자 (게스트 정원 포함 설정이면 게스트도). 정원 밖 게스트는 번호 없이 목록에만
  const counted = confirmed.filter((r) => (r.kind === 'member' || s.guests_in_capacity) && sideOfReg(r) === mySide)
  const orderOf = new Map(counted.map((r, i) => [r.id, i + 1]))
  const levelOf = (r: RegistrationRow) =>
    r.kind === 'guest' ? (r.guest_level ?? undefined) : exchange ? metaLevels[r.id] : r.user_id ? levels[r.user_id] : undefined
  const myReg = regs.find((r) => r.kind === 'member' && r.user_id === uid) ?? null
  const myWaitlist = waitlist.filter((r) => sideOfReg(r) === mySide)
  const myPosition = myReg ? (myReg.status === 'confirmed' ? counted : myWaitlist).findIndex((r) => r.id === myReg.id) + 1 : 0
  // 게스트 추가: 회원은 투표가 열린 동안, 운영진·번개 개설자는 끝나기 전까지. 대진 공개된 대회는 명단 관리에서
  const guestOpen =
    (s.kind === 'normal' || s.tournament_state === 'draft') &&
    (canManage || partnerAdmin ? phase !== 'canceled' && phase !== 'ended' : phase === 'open' || phase === 'full')
  const boardOpen = phase !== 'canceled' && now >= Date.parse(s.starts_at) - 3 * 3600_000 && now < Date.parse(s.ends_at) + 3 * 3600_000

  return (
    <Page back={back}>
      {/* 운동 정보 */}
      <div className="mb-4">
        <div className="flex items-center gap-2">
          {exchange ? (
            <Badge tone="court">교류전</Badge>
          ) : s.kind === 'tournament' ? (
            <Badge tone="court">자체대회</Badge>
          ) : (
            s.type === 'flash' && <Badge tone="shuttle">번개</Badge>
          )}
          <span className={`text-[13px] font-bold ${phase === 'open' || phase === 'in_progress' ? 'text-court-600' : 'text-ink-soft'}`}>{PHASE_LABEL[phase]}</span>
        </div>
        <h1 className={`mt-1 text-[24px] font-bold leading-tight tracking-tight text-ink ${phase === 'canceled' ? 'line-through opacity-60' : ''}`}>{s.title}</h1>
        <p className="mt-1.5 text-[16px] font-medium text-ink">
          {formatDateTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}
        </p>
        <p className="text-sm text-ink-soft">
          {s.place || '장소 미정'}, 코트 {s.court_count}면{hostName && `, ${hostName}님이 열었어요`}
        </p>
        {exchange && s.partner_club_id && (
          <p className="mt-1 text-[15px] font-semibold text-ink">
            {nameOfClub(s.club_id)} <span className="px-0.5 text-xs font-bold text-ink-faint">vs</span> {nameOfClub(s.partner_club_id)}
          </p>
        )}
      </div>

      {exchange && hostSide && s.partner_status !== 'accepted' && phase !== 'canceled' && (
        <p className="mb-3 rounded-xl bg-shuttle-100 px-3 py-2.5 text-sm text-shuttle-800">
          {s.partner_status === 'declined'
            ? `${nameOfClub(s.partner_club_id)}이(가) 초대를 거절했어요. 아래 운동 관리에서 취소할 수 있어요.`
            : `${nameOfClub(s.partner_club_id)} 운영진의 수락을 기다리고 있어요. 수락하면 그 동아리 회원도 신청할 수 있어요.`}
        </p>
      )}

      {boardOpen && (
        <Link to="board" className="mb-3 flex items-center justify-between rounded-2xl bg-court-600 px-4 py-3.5 text-white active:bg-court-700">
          <span className="flex items-center gap-2 font-semibold">
            <IconCourt className="h-5 w-5" />
            대진판 열기
          </span>
          <IconChevronRight className="h-5 w-5 text-white/70" />
        </Link>
      )}

      {s.kind !== 'normal' && s.tournament_state && phase !== 'canceled' && ((isAdmin && hostSide) || partnerAdmin || s.tournament_state !== 'draft') && (
        <Link to="tournament" className="mb-3 flex items-center justify-between rounded-2xl border border-black/[0.06] bg-white px-4 py-3.5 active:bg-floor">
          <span className="min-w-0">
            <span className="block font-semibold text-ink">{s.tournament_state === 'draft' ? (isAdmin && hostSide ? '대진 짜기' : '참가자 명단') : '대진표 보기'}</span>
            <span className="block truncate text-sm text-ink-soft">
              {STATE_LABEL[s.tournament_state]}, {s.round_count ?? 0}매치
            </span>
          </span>
          <IconChevronRight className="h-5 w-5 shrink-0 text-ink-faint" />
        </Link>
      )}

      <ActionCard s={s} phase={phase} now={now} tz={tz} myReg={myReg} myPosition={myPosition} onChanged={load} />

      {guestOpen && uid && <GuestCard s={s} uid={uid} canManage={canManage || partnerAdmin} regs={regs} onChanged={load} />}

      {canManage && phase !== 'canceled' && phase !== 'ended' && <ManageCard s={s} now={now} tz={tz} onChanged={load} />}
      {partnerAdmin && s.partner_status === 'accepted' && phase !== 'canceled' && phase !== 'ended' && (
        <PartnerCapacityCard s={s} clubName={club.name} onChanged={load} />
      )}

      {(exchange && s.partner_club_id ? [mySide, mySide === s.club_id ? s.partner_club_id : s.club_id] : [s.club_id]).map((side) => {
        const sideConfirmed = confirmed.filter((r) => sideOfReg(r) === side)
        const sideWait = waitlist.filter((r) => sideOfReg(r) === side)
        const sideCounted = sideConfirmed.filter((r) => r.kind === 'member' || s.guests_in_capacity)
        const sideOrder = new Map(sideCounted.map((r, i) => [r.id, i + 1]))
        const cap = side === s.partner_club_id && exchange ? (s.partner_capacity ?? 0) : s.capacity
        const sideGuests = [...sideConfirmed, ...sideWait].filter((r) => r.kind === 'guest').length
        return (
          <div key={side}>
            <SectionTitle right={sideGuests > 0 ? `게스트 ${sideGuests}명 ${s.guests_in_capacity ? '포함' : '별도'}` : undefined}>
              {exchange ? nameOfClub(side) : '참석'} <span className="score text-[17px]">{sideCounted.length}/{cap}</span>
            </SectionTitle>
            {sideConfirmed.length === 0 ? (
              <Empty title="아직 신청한 사람이 없어요" />
            ) : (
              <List>
                {sideConfirmed.map((r) => (
                  <PersonRow key={r.id} index={(exchange ? sideOrder : orderOf).get(r.id) ?? null} r={r} level={levelOf(r)} me={r.user_id === uid} />
                ))}
              </List>
            )}
            {sideWait.length > 0 && (
              <>
                <SectionTitle right="취소자가 생기면 순서대로 확정">
                  {exchange ? `${nameOfClub(side)} 대기` : '대기'} <span className="score text-[17px]">{sideWait.length}</span>
                </SectionTitle>
                <List>
                  {sideWait.map((r, i) => (
                    <PersonRow key={r.id} index={i + 1} r={r} level={levelOf(r)} me={r.user_id === uid} />
                  ))}
                </List>
              </>
            )}
          </div>
        )
      })}
    </Page>
  )
}

/** 교류전 상대 동아리 운영진: 우리 편 정원 바꾸기 */
function PartnerCapacityCard({ s, clubName, onChanged }: { s: SessionOverview; clubName: string; onChanged: () => Promise<void> }) {
  const toast = useToast()
  const [cap, setCap] = useState(s.partner_capacity ?? 1)
  const [busy, setBusy] = useState(false)
  const save = async () => {
    setBusy(true)
    const { data, error } = await supabase.rpc('update_partner_capacity', { p_session: s.id, p_capacity: cap })
    setBusy(false)
    if (error) toast.error(errorMessage(error))
    else toast.success(typeof data === 'number' && data > 0 ? `정원을 ${cap}명으로 바꿨어요. 대기자 ${data}명이 확정됐어요` : `정원을 ${cap}명으로 바꿨어요`)
    await onChanged()
  }
  return (
    <Card className="mt-3">
      <div className="flex items-end gap-2">
        <div className="flex-1">
          <Field label={`${clubName} 정원`} hint="교류전에서 우리 동아리 자리 수예요. 일정·취소는 주최 동아리 운영진이 관리해요.">
            <Input type="number" min={1} max={200} value={cap} onChange={(e) => setCap(Number(e.target.value))} />
          </Field>
        </div>
        <Button variant="secondary" className="mb-[22px]" disabled={busy || cap === s.partner_capacity} onClick={() => void save()}>
          변경
        </Button>
      </div>
    </Card>
  )
}

function PersonRow({ index, r, level, me }: { index: number | null; r: RegistrationRow; level?: string; me: boolean }) {
  const name = r.kind === 'guest' ? r.guest_name : r.profiles?.display_name
  return (
    <div className={`flex items-center justify-between gap-2 px-4 py-3 ${me ? 'bg-court-50' : ''}`}>
      <div className="flex min-w-0 items-center gap-2.5">
        <span className="score w-6 shrink-0 text-right text-[17px] font-semibold text-ink-faint">{index ?? ''}</span>
        <span className="min-w-0">
          <span className="flex min-w-0 items-center gap-2">
            <span className="truncate font-medium text-ink">{name ?? '이름 없음'}</span>
            {me && <Badge tone="court">나</Badge>}
            {level && <Badge tone="outline">{level}</Badge>}
            {r.kind === 'guest' && <Badge>게스트</Badge>}
          </span>
          {r.kind === 'guest' && r.adder?.display_name && <span className="block truncate text-xs text-ink-faint">{r.adder.display_name}님 손님</span>}
        </span>
      </div>
      {r.late_eta && <span className="shrink-0 text-sm font-medium text-shuttle-800">늦참 {trimSeconds(r.late_eta)}</span>}
    </div>
  )
}

/** 게스트 데려오기: 이름·성별 넣고 추가, 내가 데려온 게스트(운영진은 전체) 취소 */
function GuestCard({
  s,
  uid,
  canManage,
  regs,
  onChanged,
}: {
  s: SessionOverview
  uid: string
  canManage: boolean
  regs: RegistrationRow[]
  onChanged: () => Promise<void>
}) {
  const toast = useToast()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState('')
  const [gender, setGender] = useState<Gender | null>(null)
  const [level, setLevel] = useState<Level | null>(null)
  const [busy, setBusy] = useState(false)
  const mine = regs.filter((r) => r.kind === 'guest' && (canManage || r.added_by === uid))
  const myCount = regs.filter((r) => r.kind === 'guest' && r.added_by === uid).length
  const limitReached = !canManage && myCount >= 3

  const add = async (e: FormEvent) => {
    e.preventDefault()
    if (!name.trim()) return
    setBusy(true)
    const { data, error } = await supabase.rpc('add_vote_guest', { p_session: s.id, p_name: name.trim(), p_gender: gender, p_level: level })
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    const row = (Array.isArray(data) ? data[0] : data) as { status: string; queue_position: number | null } | undefined
    toast.success(
      row?.status === 'waitlisted'
        ? `정원이 차서 ${name.trim()}님은 대기 ${row.queue_position ?? ''}번이에요`
        : `게스트 ${name.trim()}님을 넣었어요`,
    )
    setName('')
    setGender(null)
    setLevel(null)
    await onChanged()
  }

  const remove = async (r: RegistrationRow) => {
    setBusy(true)
    const { error } = await supabase.rpc('cancel_registration', { p_registration: r.id })
    setBusy(false)
    if (error) toast.error(errorMessage(error))
    else toast.info(`게스트 ${r.guest_name}님을 뺐어요`)
    await onChanged()
  }

  return (
    <Card className="mt-3">
      <button className="flex w-full items-center justify-between gap-3 text-left" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="font-semibold text-ink">게스트 데려오기</span>
        <span className="shrink-0 text-sm text-ink-faint">{open ? '접기' : mine.length > 0 ? `${canManage ? '게스트' : '내 게스트'} ${mine.length}명` : s.guests_in_capacity ? '정원에 포함' : '정원과 별도'}</span>
      </button>

      {open && (
        <div className="mt-3 border-t border-black/[0.06] pt-3">
          <p className="text-xs leading-relaxed text-ink-soft">
            {s.guests_in_capacity
              ? '이 운동은 게스트도 정원에 포함돼요. 정원이 차면 게스트도 대기로 들어가요.'
              : '이 운동은 게스트가 정원과 상관없이 참석해요.'}
            {!canManage && ' 한 사람당 3명까지예요.'}
          </p>

          {mine.length > 0 && (
            <div className="mt-3 divide-y divide-black/[0.06] rounded-xl bg-floor">
              {mine.map((r) => (
                <div key={r.id} className="flex items-center gap-2 px-3 py-2">
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-1.5">
                      <span className="truncate text-[15px] font-medium text-ink">{r.guest_name}</span>
                      {r.guest_gender && <GenderMark g={r.guest_gender} />}
                      {r.guest_level && <Badge tone="outline">{r.guest_level}</Badge>}
                      {r.status === 'waitlisted' && <Badge tone="shuttle">대기</Badge>}
                    </span>
                    {canManage && r.added_by !== uid && r.adder?.display_name && (
                      <span className="block truncate text-xs text-ink-faint">{r.adder.display_name}님 손님</span>
                    )}
                  </span>
                  <ConfirmButton
                    label="빼기"
                    ariaLabel={`게스트 ${r.guest_name} 빼기`}
                    confirmLabel="빼기"
                    className="h-9 shrink-0 bg-black/[0.05] px-3 text-sm text-ink-soft"
                    armedClassName="h-9 shrink-0 bg-danger px-3 text-sm text-white"
                    disabled={busy}
                    onConfirm={() => void remove(r)}
                  />
                </div>
              ))}
            </div>
          )}

          {limitReached ? (
            <p className="mt-3 text-center text-sm text-ink-soft">게스트를 3명 모두 넣었어요.</p>
          ) : (
            <form onSubmit={add} className="mt-3 space-y-2">
              <Input value={name} onChange={(e) => setName(e.target.value)} maxLength={30} placeholder="게스트 이름" aria-label="게스트 이름" className="!mt-0" />
              <div className="flex items-center gap-2">
                <GenderToggle compact value={gender} onChange={setGender} label="게스트 성별" />
                <LevelSelect value={level} onChange={setLevel} label="게스트 급수" />
                <Button type="submit" variant="secondary" className="ml-auto" disabled={busy || !name.trim()}>
                  추가
                </Button>
              </div>
              <p className="text-xs text-ink-faint">성별·급수는 대진 짤 때 써요. 모르면 비워두세요.</p>
            </form>
          )}
        </div>
      )}
    </Card>
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
  const [busy, setBusy] = useState(false)
  const [latency, setLatency] = useState<number | null>(null)
  const [confirmCancel, setConfirmCancel] = useState(false)
  const [myTournamentGames, setMyTournamentGames] = useState(0)

  // 대진이 공개된 대회에서 취소하려 하면, 내가 든 시작 전 대회 경기 수를 알려준다
  const askCancel = async () => {
    setConfirmCancel(true)
    setMyTournamentGames(0)
    if (!myReg || !tournamentActive(s)) return
    const { count } = await supabase
      .from('match_players')
      .select('match_id, matches!inner(phase, status)', { count: 'exact', head: true })
      .eq('registration_id', myReg.id)
      .eq('matches.phase', 'scheduled')
      .eq('matches.status', 'queued')
    setMyTournamentGames(count ?? 0)
  }

  const register = async () => {
    setBusy(true)
    const t0 = performance.now()
    const { data, error } = await supabase.rpc('register', { p_session: s.id, p_late_eta: null })
    const ms = Math.round(performance.now() - t0)
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    setLatency(ms)
    const row = (Array.isArray(data) ? data[0] : data) as { status: string; queue_position: number } | undefined
    if (row) toast.success(row.status === 'confirmed' ? `참석 확정, ${row.queue_position}번째예요. 늦게 오면 도착 시각을 남겨주세요` : `대기 ${row.queue_position}번으로 신청했어요`)
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
    else toast.success(value ? `${value} 도착 예정으로 남겼어요` : '늦참 표시를 지웠어요')
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
            <LateEta s={s} tz={tz} value={myReg.late_eta ? trimSeconds(myReg.late_eta) : null} busy={busy} onSave={saveLate} />

            <div className="mt-4">
              {!confirmCancel ? (
                <Button variant="ghost" className="w-full text-danger" disabled={busy} onClick={() => void askCancel()}>
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
              {confirmCancel && myTournamentGames > 0 && (
                <p className="mt-2 rounded-lg bg-shuttle-100 px-3 py-2 text-center text-[13px] font-medium text-shuttle-800">
                  대회 경기 {myTournamentGames}개에 들어 있어요. 취소하면 운영진이 다른 사람으로 바꿔야 해요.
                </p>
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

      <Button className="h-14 w-full text-[17px]" disabled={!canTry || busy} onClick={() => void register()}>
        {closed ? '신청 마감' : phase === 'before_open' ? '오픈 전' : busy ? '신청하는 중' : phase === 'full' ? '대기 신청' : '참석 신청'}
      </Button>
      {phase === 'full' && <p className="mt-2 text-center text-xs text-ink-soft">정원이 찼어요. 취소자가 생기면 대기 순서대로 확정돼요.</p>}
      {!closed && phase !== 'full' && <p className="mt-2 text-center text-xs text-ink-faint">늦게 오면 신청한 뒤에 도착 시각을 남길 수 있어요.</p>}
    </Card>
  )
}

/** 신청 후 늦참 표시: 빠른 선택(30분·1시간·1시간 30분 늦게) 또는 직접 시각. 이미 있으면 바꾸기·지우기 */
function LateEta({
  s,
  tz,
  value,
  busy,
  onSave,
}: {
  s: SessionOverview
  tz: string
  value: string | null
  busy: boolean
  onSave: (v: string | null) => Promise<void>
}) {
  const [open, setOpen] = useState(false)
  const [custom, setCustom] = useState('')
  const start = Date.parse(s.starts_at)
  const end = Date.parse(s.ends_at)
  const quick = [30, 60, 90]
    .map((min) => ({ min, at: start + min * 60_000 }))
    .filter((q) => q.at < end)
    .map((q) => ({ label: q.min < 60 ? `${q.min}분` : q.min % 60 ? `${Math.floor(q.min / 60)}시간 ${q.min % 60}분` : `${q.min / 60}시간`, time: toTimeInput(q.at, tz) }))

  const save = async (v: string | null) => {
    await onSave(v)
    setOpen(false)
    setCustom('')
  }

  return (
    <div className="mt-4 rounded-xl bg-white/70 p-3 ring-1 ring-black/[0.05]">
      {value && !open ? (
        <div className="flex items-center justify-between gap-2">
          <div>
            <p className="text-[13px] font-semibold text-ink-soft">늦참</p>
            <p className="text-[17px] font-bold text-shuttle-800">
              <span className="score text-[22px]">{value}</span> 도착 예정
            </p>
          </div>
          <div className="flex shrink-0 gap-1.5">
            <Button variant="secondary" className="h-10 px-3 text-sm" disabled={busy} onClick={() => setOpen(true)}>
              바꾸기
            </Button>
            <Button variant="ghost" className="h-10 px-3 text-sm text-ink-soft" disabled={busy} onClick={() => void save(null)}>
              지우기
            </Button>
          </div>
        </div>
      ) : !open ? (
        <button type="button" onClick={() => setOpen(true)} className="flex w-full items-center justify-between text-left">
          <span>
            <span className="block text-[15px] font-semibold text-ink">늦게 도착하나요?</span>
            <span className="block text-[13px] text-ink-soft">대진 짤 때 참고해요</span>
          </span>
          <span className="shrink-0 rounded-lg bg-court-600 px-3 py-2 text-sm font-semibold text-white">늦참 표시</span>
        </button>
      ) : (
        <div>
          <div className="flex items-center justify-between">
            <p className="text-[15px] font-semibold text-ink">운동 시작보다 얼마나 늦어요?</p>
            <button type="button" onClick={() => setOpen(false)} className="text-sm font-medium text-ink-soft">
              닫기
            </button>
          </div>
          <div className="mt-2 grid grid-cols-3 gap-1.5">
            {quick.map((q) => (
              <button
                key={q.time}
                type="button"
                disabled={busy}
                onClick={() => void save(q.time)}
                className={`flex h-14 flex-col items-center justify-center rounded-xl text-[14px] font-semibold disabled:opacity-40 ${value === q.time ? 'bg-court-600 text-white' : 'bg-floor text-ink active:bg-black/10'}`}
              >
                {q.label}
                <span className={`score text-[13px] font-medium ${value === q.time ? 'text-white/80' : 'text-ink-faint'}`}>{q.time}</span>
              </button>
            ))}
          </div>
          <div className="mt-2 flex items-center gap-1.5">
            <Input type="time" value={custom} onChange={(e) => setCustom(e.target.value)} className="!mt-0 min-w-0 flex-1" aria-label="도착 예정 시각 직접 입력" />
            <Button className="shrink-0" disabled={busy || !custom} onClick={() => void save(custom)}>
              이 시각으로
            </Button>
          </div>
        </div>
      )}
    </div>
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

  const toggleGuests = (on: boolean) =>
    run(
      () => supabase.rpc('set_guests_in_capacity', { p_session: s.id, p_on: on }),
      (n) =>
        on
          ? '이제 게스트도 정원에 포함돼요. 이미 확정된 사람은 그대로예요'
          : typeof n === 'number' && n > 0
            ? `게스트를 정원에서 뺐어요. 대기하던 ${n}명이 확정됐어요`
            : '게스트를 정원에서 뺐어요',
    )

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
        <span className="text-sm text-ink-faint">{open ? '접기' : '정원, 게스트, 일정 수정, 취소'}</span>
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

          <div className="mt-1">
            <GuestCapacityField checked={s.guests_in_capacity} disabled={busy} onChange={(v) => void toggleGuests(v)} />
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
