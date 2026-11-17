import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { Badge, Card, ErrorText, Page, Spinner } from '../components/ui'
import { DEFAULT_TZ, formatDateTime, formatTime } from '../lib/datetime'
import { serverNow, useServerNow } from '../lib/serverTime'
import { PHASE_LABEL, sessionPhase, type SessionPhase } from '../lib/sessionStatus'
import { errorMessage, supabase } from '../lib/supabase'
import type { SessionOverview } from '../lib/types'

const PHASE_TONE: Record<SessionPhase, string> = {
  canceled: 'bg-neutral-100 text-neutral-500',
  before_open: 'bg-neutral-100 text-neutral-700',
  open: 'bg-green-100 text-green-800',
  full: 'bg-amber-100 text-amber-800',
  in_progress: 'bg-blue-100 text-blue-800',
  ended: 'bg-neutral-100 text-neutral-500',
}

export default function ClubHomePage() {
  const { club, isAdmin } = useClub()
  const tz = club.timezone ?? DEFAULT_TZ
  const now = useServerNow()
  const [sessions, setSessions] = useState<SessionOverview[] | null>(null)
  const [pendingCount, setPendingCount] = useState(0)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    // 정기운동 회차가 아직 없으면 만들어 둔다 (멱등. cron이 늦어도 목록이 비지 않게)
    await supabase.rpc('ensure_upcoming_sessions', { p_club: club.id })
    const { data, error } = await supabase
      .from('session_overview')
      .select('*')
      .eq('club_id', club.id)
      .gt('ends_at', new Date(serverNow()).toISOString())
      .order('starts_at')
      .limit(30)
    if (error) setError(errorMessage(error))
    else setSessions(data as SessionOverview[])
  }, [club.id])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    if (!isAdmin) return
    supabase
      .from('club_members')
      .select('user_id', { count: 'exact', head: true })
      .eq('club_id', club.id)
      .eq('status', 'pending')
      .then(({ count }) => setPendingCount(count ?? 0))
  }, [club.id, isAdmin])

  return (
    <Page
      title="일정"
      action={
        <Link to="flash/new" className="rounded-xl bg-neutral-900 px-3 py-2 text-sm font-semibold text-white">
          + 번개
        </Link>
      }
    >
      <ErrorText>{error}</ErrorText>
      {!sessions && !error && <Spinner />}
      {sessions?.length === 0 && (
        <Card>
          <p className="text-sm text-neutral-500">예정된 운동이 없어요.</p>
          {isAdmin && <p className="mt-1 text-xs text-neutral-400">아래 정기운동 관리에서 정기운동을 등록하면 투표 오픈 7일 전부터 여기에 나타나요.</p>}
        </Card>
      )}

      <div className="space-y-2">
        {sessions?.map((s) => {
          const phase = sessionPhase(s, now)
          const dim = phase === 'canceled'
          return (
            <Link key={s.id} to={`s/${s.id}`} className="block">
            <Card className={`active:bg-neutral-50 ${dim ? 'opacity-50' : ''}`}>
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <div className="flex items-center gap-1.5">
                    <Badge tone={s.type === 'regular' ? 'blue' : 'neutral'}>{s.type === 'regular' ? '정기' : '번개'}</Badge>
                    <span className="truncate font-semibold text-neutral-900">{s.title}</span>
                  </div>
                  <p className="mt-1 text-sm text-neutral-700">
                    {formatDateTime(s.starts_at, tz)}~{formatTime(s.ends_at, tz)}
                  </p>
                  <p className="text-sm text-neutral-500">
                    {s.place || '장소 미정'} · 코트 {s.court_count}면
                  </p>
                </div>
                <span className={`shrink-0 rounded-md px-2 py-1 text-xs font-semibold ${PHASE_TONE[phase]}`}>{PHASE_LABEL[phase]}</span>
              </div>

              <div className="mt-3 flex items-center justify-between text-sm">
                <span className="text-neutral-700">
                  확정 <b>{s.confirmed_count}</b>/{s.capacity}
                  {s.waitlist_count > 0 && <span className="text-neutral-500"> · 대기 {s.waitlist_count}</span>}
                </span>
                {phase === 'before_open' && <span className="text-neutral-500">{formatDateTime(s.opens_at, tz)} 오픈</span>}
                {s.my_status === 'confirmed' && <Badge tone="blue">참석 확정</Badge>}
                {s.my_status === 'waitlisted' && <Badge tone="amber">대기 중</Badge>}
              </div>
            </Card>
            </Link>
          )
        })}
      </div>

      <nav className="mt-6 space-y-2">
        <Link to="me" className="block">
          <Card className="flex items-center justify-between">
            <span className="font-medium text-neutral-900">내 정보</span>
            <span className="text-sm text-neutral-400">이름·급수</span>
          </Card>
        </Link>
        {isAdmin && (
          <>
            <Link to="admin/templates" className="block">
              <Card className="flex items-center justify-between">
                <span className="font-medium text-neutral-900">정기운동 관리</span>
                <span className="text-sm text-neutral-400">요일·시간·투표 오픈</span>
              </Card>
            </Link>
            <Link to="admin/members" className="block">
              <Card className="flex items-center justify-between">
                <span className="font-medium text-neutral-900">회원 관리</span>
                {pendingCount > 0 ? <Badge tone="amber">가입 신청 {pendingCount}</Badge> : <span className="text-sm text-neutral-400">가입 승인·운영진</span>}
              </Card>
            </Link>
          </>
        )}
      </nav>
    </Page>
  )
}
