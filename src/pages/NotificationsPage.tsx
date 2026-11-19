import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { IconChevronLeft } from '../components/icons'
import { PushCard } from '../components/PushCard'
import { Empty, List, ListSkeleton, Page } from '../components/ui'
import { notifyUnreadChanged, type AppNotification } from '../lib/notifications'
import { supabase } from '../lib/supabase'

const KIND_LABEL: Record<string, string> = {
  join_request: '가입 신청',
  join_approved: '가입 승인',
  vote_created: '새 운동',
  vote_soon: '투표 곧 오픈',
  court_assigned: '코트 배정',
  court_next: '코트 대기',
  club_request: '개설 신청',
  club_decided: '동아리 개설',
  club_deleted: '동아리 삭제',
}

function ago(iso: string) {
  const min = Math.floor((Date.now() - Date.parse(iso)) / 60_000)
  if (min < 1) return '방금'
  if (min < 60) return `${min}분 전`
  const h = Math.floor(min / 60)
  if (h < 24) return `${h}시간 전`
  const d = Math.floor(h / 24)
  return d < 7 ? `${d}일 전` : new Date(iso).toLocaleDateString('ko-KR', { month: 'numeric', day: 'numeric' })
}

/** 알림함: 내 알림 최근 50개. 열면 모두 읽음으로 바뀐다 (읽지 않았던 건 강조 유지) */
export default function NotificationsPage() {
  const { club } = useClub()
  const { session } = useAuth()
  const navigate = useNavigate()
  const [items, setItems] = useState<AppNotification[] | null>(null)
  const [unreadAtOpen, setUnreadAtOpen] = useState<Set<number>>(new Set())

  const load = useCallback(async () => {
    if (!session) return
    const { data } = await supabase
      .from('notifications')
      .select('id, club_id, session_id, kind, title, body, url, created_at, read_at')
      .eq('user_id', session.user.id)
      .order('created_at', { ascending: false })
      .limit(50)
    const rows = (data as AppNotification[] | null) ?? []
    setItems(rows)
    return rows
  }, [session])

  useEffect(() => {
    void load().then((rows) => {
      const unread = (rows ?? []).filter((n) => !n.read_at).map((n) => n.id)
      setUnreadAtOpen(new Set(unread))
      // 모두 읽음 처리가 끝나면 헤더 종·앱 아이콘 숫자를 바로 줄인다 (실시간 신호를 기다리지 않음)
      if (unread.length) void supabase.rpc('mark_notifications_read', { p_ids: null }).then(() => notifyUnreadChanged())
    })
  }, [load])

  const back = (
    <Link to={`/c/${club.id}`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      일정
    </Link>
  )

  return (
    <Page title="알림" back={back}>
      <div className="mb-4">
        <PushCard compact />
      </div>
      {!items ? (
        <ListSkeleton rows={4} />
      ) : items.length === 0 ? (
        <Empty title="아직 알림이 없어요">투표가 열리기 10분 전, 내 경기가 코트에 들어갔을 때 여기와 폰으로 알려드려요.</Empty>
      ) : (
        <List>
          {items.map((n) => (
            <button
              key={n.id}
              type="button"
              onClick={() => navigate(n.url)}
              className={`flex w-full gap-3 px-4 py-3 text-left active:bg-floor ${unreadAtOpen.has(n.id) ? 'bg-court-50/70' : ''}`}
            >
              <span className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${unreadAtOpen.has(n.id) ? 'bg-court-600' : 'bg-transparent'}`} aria-hidden />
              <span className="min-w-0 flex-1">
                <span className="flex items-baseline justify-between gap-2">
                  <span className="text-xs font-semibold text-court-600">{KIND_LABEL[n.kind] ?? '알림'}</span>
                  <span className="shrink-0 text-xs text-ink-faint">{ago(n.created_at)}</span>
                </span>
                <span className="mt-0.5 block text-[15px] font-semibold text-ink">{n.title}</span>
                <span className="mt-0.5 block text-[13px] leading-relaxed text-ink-soft">{n.body}</span>
              </span>
            </button>
          ))}
        </List>
      )}
    </Page>
  )
}
