import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { PushCard } from '../components/PushCard'
import { IconPlus } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Empty, ListSkeleton, Page } from '../components/ui'
import { DEFAULT_TZ, dateParts, formatDateTime, formatTime } from '../lib/datetime'
import { serverNow, useServerNow } from '../lib/serverTime'
import { PHASE_LABEL, sessionPhase, type SessionPhase } from '../lib/sessionStatus'
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

  const load = useCallback(async () => {
    // 정기운동 회차가 아직 없으면 만들어 둔다 (멱등. cron이 늦어도 목록이 비지 않게)
    await supabase.rpc('ensure_upcoming_sessions', { p_club: club.id })
    const { data, error } = await supabase
      .from('session_overview')
      .select('*')
      .eq('club_id', club.id)
      .is('canceled_at', null) // 취소된 운동은 목록에서 뺀다
      .gt('ends_at', new Date(serverNow()).toISOString())
      .order('starts_at')
      .limit(30)
    if (error) {
      toast.error(errorMessage(error))
      setSessions([])
    } else setSessions(data as SessionOverview[])
  }, [club.id, toast])

  useEffect(() => {
    void load()
  }, [load])

  // 화면을 켜 둔 사이에 끝난 운동도 바로 사라지게 (종료·취소는 안 보임)
  const visible = sessions?.filter((s) => {
    const phase = sessionPhase(s, now)
    return phase !== 'ended' && phase !== 'canceled'
  })

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

  return (
    <Page
      title="일정"
      action={
        <div className="flex gap-1.5">
          {isAdmin && (
            <Link to="tournament/new" className="inline-flex h-10 items-center gap-1 rounded-xl bg-white pl-2.5 pr-3.5 text-[15px] font-semibold text-court-700 ring-1 ring-court-600/25 active:bg-court-50">
              <IconPlus className="h-4 w-4" />
              자체대회
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
      {!sessions && <ListSkeleton rows={3} />}
      {visible?.length === 0 && (
        <Empty title="예정된 운동이 없어요">
          {isAdmin ? '내 정보 탭의 정기운동 관리에서 정기운동을 등록하면, 투표 오픈 7일 전부터 여기에 보여요.' : '오른쪽 위 번개 버튼으로 운동을 열 수 있어요.'}
        </Empty>
      )}

      <ul className="space-y-2.5">
        {visible?.map((s) => {
          const phase = sessionPhase(s, now)
          const d = dateParts(s.starts_at, tz)
          const full = s.confirmed_count >= s.capacity
          const ratio = Math.min(1, s.confirmed_count / s.capacity)
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
                      {s.kind === 'tournament' ? <Badge tone="court">자체대회</Badge> : s.type === 'flash' && <Badge tone="shuttle">번개</Badge>}
                      <span className="truncate text-[16px] font-bold text-ink">{s.title}</span>
                    </div>
                    <span className={`shrink-0 text-[13px] font-bold ${PHASE_STYLE[phase]}`}>{PHASE_LABEL[phase]}</span>
                  </div>
                  <p className="mt-0.5 truncate text-sm text-ink-soft">
                    {formatTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}
                    {s.place && `, ${s.place}`}
                  </p>

                  {/* 정원 막대 */}
                  <div className="mt-2.5 flex items-center gap-2.5">
                    <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-black/[0.06]">
                      <div className={`h-full rounded-full ${full ? 'bg-shuttle-400' : 'bg-court-500'}`} style={{ width: `${ratio * 100}%` }} />
                    </div>
                    <span className="score shrink-0 text-[15px] font-semibold text-ink">
                      {s.confirmed_count}/{s.capacity}
                      {s.waitlist_count > 0 && <span className="text-ink-soft"> +{s.waitlist_count}</span>}
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
        })}
      </ul>
    </Page>
  )
}
