import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { PushCard } from '../components/PushCard'
import { IconChevronDown, IconPlus } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Empty, ListSkeleton, Page } from '../components/ui'
import { DEFAULT_TZ, dateParts, formatDateTime, formatTime } from '../lib/datetime'
import { serverNow, useServerNow } from '../lib/serverTime'
import { PHASE_LABEL, sessionPhase, sideCounts, type SessionPhase } from '../lib/sessionStatus'
import { errorMessage, supabase } from '../lib/supabase'
import type { SessionOverview } from '../lib/types'

const PHASE_STYLE: Record<SessionPhase, string> = {
  canceled: 'text-ink-faint',
  before_open: 'text-ink-soft',
  open: 'text-court-600',
  full: 'text-shuttle-800',
  in_progress: 'text-court-600',
  ended: 'text-ink-faint',
}

export default function ClubHomePage() {
  const { club, isAdmin } = useClub()
  const tz = club.timezone ?? DEFAULT_TZ
  const toast = useToast()
  const now = useServerNow()
  const [sessions, setSessions] = useState<SessionOverview[] | null>(null)
  // 교류전: 상대 동아리 이름, 우리가 받은 초대 (운영진)
  const [clubNames, setClubNames] = useState<Record<string, string>>({})
  const [invites, setInvites] = useState<SessionOverview[]>([])

  const load = useCallback(async () => {
    // 정기운동 회차가 아직 없으면 만들어 둔다 (멱등. cron이 늦어도 목록이 비지 않게)
    await supabase.rpc('ensure_upcoming_sessions', { p_club: club.id })
    const nowIso = new Date(serverNow()).toISOString()
    const [{ data, error }, inv] = await Promise.all([
      supabase
        .from('session_overview')
        .select('*')
        // 우리 운동 + 우리가 수락한 교류전
        .or(`club_id.eq.${club.id},and(partner_club_id.eq.${club.id},partner_status.eq.accepted)`)
        .is('canceled_at', null) // 취소된 운동은 목록에서 뺀다
        .gt('ends_at', nowIso)
        .order('starts_at')
        .limit(30),
      isAdmin
        ? supabase
            .from('session_overview')
            .select('*')
            .eq('partner_club_id', club.id)
            .eq('partner_status', 'invited')
            .is('canceled_at', null)
            .gt('ends_at', nowIso)
            .order('starts_at')
        : Promise.resolve({ data: [] as SessionOverview[] }),
    ])
    const rows = (data as SessionOverview[] | null) ?? []
    const invs = (inv.data as SessionOverview[] | null) ?? []
    const ids = [...new Set([...rows, ...invs].flatMap((x) => (x.kind === 'exchange' ? [x.club_id, x.partner_club_id] : [])).filter(Boolean) as string[])]
    if (ids.length > 0) {
      const { data: cn } = await supabase.from('clubs').select('id, name').in('id', ids)
      setClubNames(Object.fromEntries(((cn ?? []) as { id: string; name: string }[]).map((c) => [c.id, c.name])))
    }
    setInvites(invs)
    if (error) {
      toast.error(errorMessage(error))
      setSessions([])
    } else setSessions(rows)
  }, [club.id, isAdmin, toast])

  const respond = async (s: SessionOverview, accept: boolean) => {
    const { error } = await supabase.rpc('respond_exchange', { p_session: s.id, p_accept: accept })
    if (error) toast.error(errorMessage(error))
    else toast.success(accept ? '교류전을 수락했어요. 회원들에게 알림이 갔어요' : '교류전 초대를 거절했어요')
    await load()
  }

  useEffect(() => {
    void load()
  }, [load])

  // 화면을 켜 둔 사이에 끝난 운동도 바로 사라지게 (종료·취소는 안 보임)
  const visible = sessions?.filter((s) => {
    const phase = sessionPhase(s, now)
    return phase !== 'ended' && phase !== 'canceled'
  })
  // 앞으로 7일 안에 시작하는 운동(진행 중 포함)만 펼쳐 두고, 그 뒤는 접어 둔다
  const weekEnd = now + 7 * 86400_000
  const thisWeek = visible?.filter((s) => Date.parse(s.starts_at) < weekEnd) ?? []
  const later = visible?.filter((s) => Date.parse(s.starts_at) >= weekEnd) ?? []
  const [showLater, setShowLater] = useState(false)

  // 홈 위 '알림 받기' 안내: 닫으면 이 기기에서 다시 안 보임 (내 정보에서 언제든 켤 수 있음)
  const [pushPromptHidden, setPushPromptHidden] = useState(() => {
    try {
      return localStorage.getItem('push-prompt-hidden') === '1'
    } catch {
      return false
    }
  })
  const hidePushPrompt = () => {
    setPushPromptHidden(true)
    try {
      localStorage.setItem('push-prompt-hidden', '1')
    } catch {
      /* 저장 못 해도 이번에는 숨김 */
    }
  }

  const renderItem = (s: SessionOverview) => {
    const phase = sessionPhase(s, now, club.id)
    const d = dateParts(s.starts_at, tz)
    const c = sideCounts(s, club.id)
    const full = c.confirmed >= c.capacity
    const ratio = c.capacity > 0 ? Math.min(1, c.confirmed / c.capacity) : 0
    const other = s.kind === 'exchange' ? clubNames[s.club_id === club.id ? (s.partner_club_id ?? '') : s.club_id] : null
    return (
      <li key={s.id}>
        <Link
          to={`s/${s.id}`}
          className="flex gap-3.5 rounded-2xl border border-black/[0.06] bg-white p-3.5 active:bg-floor"
        >
          {/* 날짜 블록 */}
          <div className={`flex w-14 shrink-0 flex-col items-center justify-center rounded-xl py-2 ${d.isToday ? 'bg-court-600 text-white' : 'bg-floor text-ink'}`}>
            <span className={`text-[11px] font-semibold ${d.isToday ? 'text-white/80' : 'text-ink-soft'}`}>{d.isToday ? '오늘' : `${d.month}월`}</span>
            <span className="score text-[30px] font-semibold leading-none">{d.day}</span>
            <span className={`text-[11px] font-semibold ${d.isToday ? 'text-white/80' : 'text-ink-soft'}`}>{d.weekday}</span>
          </div>

          <div className="min-w-0 flex-1">
            <div className="flex items-start justify-between gap-2">
              <div className="flex min-w-0 items-center gap-1.5">
                {s.kind === 'exchange' ? (
                  <Badge tone="court">교류전</Badge>
                ) : s.kind === 'tournament' ? (
                  <Badge tone="court">자체대회</Badge>
                ) : (
                  s.type === 'flash' && <Badge tone="shuttle">번개</Badge>
                )}
                <span className="truncate text-[16px] font-bold text-ink">{s.title}</span>
              </div>
              <span className={`shrink-0 text-[13px] font-bold ${PHASE_STYLE[phase]}`}>{PHASE_LABEL[phase]}</span>
            </div>
            <p className="mt-0.5 truncate text-sm text-ink-soft">
              {other && <span className="font-semibold text-ink">vs {other}, </span>}
              {formatTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}
              {s.place && `, ${s.place}`}
            </p>

            {/* 정원 막대 */}
            <div className="mt-2.5 flex items-center gap-2.5">
              <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-black/[0.06]">
                <div className={`h-full rounded-full ${full ? 'bg-shuttle-400' : 'bg-court-500'}`} style={{ width: `${ratio * 100}%` }} />
              </div>
              <span className="score shrink-0 text-[15px] font-semibold text-ink">
                {c.confirmed}/{c.capacity}
                {c.waitlist > 0 && <span className="text-ink-soft"> +{c.waitlist}</span>}
              </span>
            </div>

            <div className="mt-1.5 flex min-h-5 items-center justify-between text-xs">
              <span className="text-ink-faint">{phase === 'before_open' ? `${formatDateTime(s.opens_at, tz)} 투표 오픈` : `코트 ${s.court_count}면`}</span>
              {s.my_status === 'confirmed' && <Badge tone="court">참석</Badge>}
              {s.my_status === 'waitlisted' && <Badge tone="shuttle">대기 중</Badge>}
            </div>
          </div>
        </Link>
      </li>
    )
  }

  return (
    <Page
      title="일정"
      action={
        <div className="flex gap-1.5">
          {isAdmin && (
            <Link to="tournament/new" className="inline-flex h-10 items-center gap-1 rounded-xl bg-white pl-2.5 pr-3.5 text-[15px] font-semibold text-court-700 ring-1 ring-court-600/25 active:bg-court-50">
              <IconPlus className="h-4 w-4" />
              대회
            </Link>
          )}
          <Link to="flash/new" className="inline-flex h-10 items-center gap-1 rounded-xl bg-court-600 pl-2.5 pr-3.5 text-[15px] font-semibold text-white active:bg-court-700">
            <IconPlus className="h-4 w-4" />
            번개
          </Link>
        </div>
      }
    >
      {!pushPromptHidden && (
        <div className="mb-3">
          <PushCard compact onDismiss={hidePushPrompt} />
        </div>
      )}
      {invites.map((inv) => (
        <div key={inv.id} className="mb-3 rounded-2xl border border-court-200 bg-court-50 p-4">
          <p className="text-[13px] font-bold text-court-700">교류전 초대</p>
          <p className="mt-1 text-[16px] font-bold text-ink">
            {clubNames[inv.club_id] ?? '다른 동아리'}에서 '{inv.title}'에 초대했어요
          </p>
          <p className="mt-0.5 text-sm text-ink-soft">
            {formatDateTime(inv.starts_at, tz)}~{formatTime(inv.ends_at, tz)}
            {inv.place && `, ${inv.place}`}, 우리 정원 {inv.partner_capacity}명
          </p>
          <p className="mt-1 text-xs text-ink-faint">수락하면 우리 회원들에게 알림이 가고 신청할 수 있어요. 대진은 주최 운영진이 짜요.</p>
          <div className="mt-3 flex gap-2">
            <Button variant="secondary" className="flex-1" onClick={() => void respond(inv, false)}>
              거절
            </Button>
            <Button className="flex-1" onClick={() => void respond(inv, true)}>
              수락
            </Button>
          </div>
        </div>
      ))}
      {!sessions && <ListSkeleton rows={3} />}
      {visible?.length === 0 && (
        <Empty title="예정된 운동이 없어요">
          {isAdmin ? '내 정보 탭의 정기운동 관리에서 정기운동을 등록하면, 투표 오픈 7일 전부터 여기에 보여요.' : '오른쪽 위 번개 버튼으로 운동을 열 수 있어요.'}
        </Empty>
      )}

      {thisWeek.length > 0 && <ul className="space-y-2.5">{thisWeek.map(renderItem)}</ul>}
      {visible && visible.length > 0 && thisWeek.length === 0 && (
        <p className="mb-2.5 rounded-2xl border border-dashed border-black/15 px-4 py-4 text-center text-sm text-ink-soft">이번 주(7일 안)에는 운동이 없어요.</p>
      )}

      {later.length > 0 && (
        <>
          <button
            type="button"
            onClick={() => setShowLater((v) => !v)}
            aria-expanded={showLater}
            className="mt-2.5 flex h-12 w-full items-center justify-center gap-1 rounded-2xl text-sm font-semibold text-ink-soft active:bg-black/5"
          >
            {showLater ? '7일 뒤 운동 접기' : `7일 뒤 운동 ${later.length}개 더 보기`}
            <IconChevronDown className={`h-4 w-4 transition-transform ${showLater ? 'rotate-180' : ''}`} />
          </button>
          {showLater && <ul className="space-y-2.5">{later.map(renderItem)}</ul>}
        </>
      )}
    </Page>
  )
}
