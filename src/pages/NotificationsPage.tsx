import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { IconChevronDown, IconChevronLeft } from '../components/icons'
import { PushCard } from '../components/PushCard'
import { Empty, List, ListSkeleton, Page, SectionTitle } from '../components/ui'
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
  exchange_invite: '교류전 초대',
  exchange_reply: '교류전 응답',
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

/**
 * 알림함: 내 알림 최근 50개
 *   위에 안 읽은 알림, 아래 지난 알림(접어 둠). 알림을 누르면 그것만 읽음, '모두 읽음'으로 한 번에
 *   끝난 운동의 코트·투표 알림과 30일 지난 알림은 서버가 지운다
 */
export default function NotificationsPage() {
  const { club } = useClub()
  const { session } = useAuth()
  const navigate = useNavigate()
  const [items, setItems] = useState<AppNotification[] | null>(null)
  const [showRead, setShowRead] = useState(false)

  const load = useCallback(async () => {
    if (!session) return
    const { data } = await supabase
      .from('notifications')
      .select('id, club_id, session_id, kind, title, body, url, created_at, read_at')
      .eq('user_id', session.user.id)
      .order('created_at', { ascending: false })
      .limit(50)
    setItems((data as AppNotification[] | null) ?? [])
  }, [session])

  useEffect(() => {
    void load()
  }, [load])

  const markRead = async (ids: number[] | null) => {
    const now = new Date().toISOString()
    // 화면은 바로 바꾸고, 헤더 종·앱 아이콘 숫자는 저장이 끝나면 다시 센다
    setItems((prev) => prev?.map((n) => (ids === null || ids.includes(n.id) ? { ...n, read_at: n.read_at ?? now } : n)) ?? prev)
    await supabase.rpc('mark_notifications_read', { p_ids: ids })
    notifyUnreadChanged()
  }

  const open = (n: AppNotification) => {
    if (!n.read_at) void markRead([n.id])
    navigate(n.url)
  }

  const back = (
    <Link to={`/c/${club.id}`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      일정
    </Link>
  )

  const unread = items?.filter((n) => !n.read_at) ?? []
  const read = items?.filter((n) => n.read_at) ?? []

  const row = (n: AppNotification) => (
    <button
      key={n.id}
      type="button"
      onClick={() => open(n)}
      className={`flex w-full gap-3 px-4 py-3 text-left active:bg-floor ${n.read_at ? '' : 'bg-court-50/70'}`}
    >
      <span className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${n.read_at ? 'bg-transparent' : 'bg-court-600'}`} aria-hidden />
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline justify-between gap-2">
          <span className="text-xs font-semibold text-court-600">{KIND_LABEL[n.kind] ?? '알림'}</span>
          <span className="shrink-0 text-xs text-ink-faint">{ago(n.created_at)}</span>
        </span>
        <span className={`mt-0.5 block text-[15px] font-semibold ${n.read_at ? 'text-ink-soft' : 'text-ink'}`}>{n.title}</span>
        <span className="mt-0.5 block text-[13px] leading-relaxed text-ink-soft">{n.body}</span>
      </span>
    </button>
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
        <>
          <SectionTitle
            right={
              unread.length > 0 ? (
                <button type="button" onClick={() => void markRead(null)} className="text-sm font-semibold text-court-600">
                  모두 읽음
                </button>
              ) : undefined
            }
          >
            안 읽은 알림 <span className="score text-[17px]">{unread.length}</span>
          </SectionTitle>
          {unread.length === 0 ? (
            <p className="rounded-2xl border border-dashed border-black/15 px-4 py-4 text-center text-sm text-ink-soft">새 알림을 모두 읽었어요</p>
          ) : (
            <List>{unread.map(row)}</List>
          )}

          {read.length > 0 && (
            <>
              <button
                type="button"
                onClick={() => setShowRead((v) => !v)}
                aria-expanded={showRead}
                className="mt-3 flex h-12 w-full items-center justify-center gap-1 rounded-2xl text-sm font-semibold text-ink-soft active:bg-black/5"
              >
                {showRead ? '지난 알림 접기' : `지난 알림 ${read.length}개 보기`}
                <IconChevronDown className={`h-4 w-4 transition-transform ${showRead ? 'rotate-180' : ''}`} />
              </button>
              {showRead && <List>{read.map(row)}</List>}
            </>
          )}
          <p className="mt-4 text-center text-xs text-ink-faint">끝난 운동의 코트·투표 알림과 30일 지난 알림은 자동으로 지워져요.</p>
        </>
      )}
    </Page>
  )
}
