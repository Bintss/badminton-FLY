import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import { Link, Navigate, Outlet, useLocation, useNavigate, useParams } from 'react-router-dom'
import { IconBell, IconCalendar, IconCourt, IconPerson } from '../components/icons'
import { useUnreadCount } from '../lib/notifications'
import { syncPushSubscription } from '../lib/push'
import { useAuth } from '../auth/AuthProvider'
import { ListSkeleton, Page, Spinner } from '../components/ui'
import { Sheet } from '../components/Sheet'
import { setLastClubId } from '../lib/lastClub'
import { errorMessage, supabase } from '../lib/supabase'
import { CLUB_COLUMNS, type Club, type ClubMember } from '../lib/types'
import { ClubLogo } from '../components/ClubLogo'

interface ClubState {
  club: Club
  me: ClubMember
  isAdmin: boolean
  reload: () => Promise<void>
}

const ClubContext = createContext<ClubState | null>(null)

// eslint-disable-next-line react-refresh/only-export-components
export function useClub() {
  const ctx = useContext(ClubContext)
  if (!ctx) throw new Error('useClub must be used within ClubLayout')
  return ctx
}

/** /c/:clubId 이하: 승인된 회원만 들어올 수 있다 (실제 차단은 RLS, 여기는 화면 분기) */
export default function ClubLayout() {
  const { clubId } = useParams()
  const { session } = useAuth()
  const { pathname } = useLocation()
  const wide = pathname.endsWith('/board') && pathname.includes('/s/') // 대진판은 가로 화면에서 넓게
  const [state, setState] = useState<{ club: Club | null; me: ClubMember | null; loaded: boolean }>({
    club: null,
    me: null,
    loaded: false,
  })

  const load = useCallback(async () => {
    if (!clubId || !session) return
    const [club, me] = await Promise.all([
      supabase.from('clubs').select(CLUB_COLUMNS).eq('id', clubId).maybeSingle(),
      supabase.from('club_members').select('*').eq('club_id', clubId).eq('user_id', session.user.id).maybeSingle(),
    ])
    setState({ club: club.data as Club | null, me: me.data as ClubMember | null, loaded: true })
  }, [clubId, session])

  useEffect(() => {
    void load()
  }, [load])

  // 이 기기에 알림이 켜져 있으면 지금 로그인한 계정으로 구독을 맞춘다
  useEffect(() => {
    if (session) void syncPushSubscription()
  }, [session])

  const allowed = Boolean(state.club && state.me?.status === 'approved')

  useEffect(() => {
    if (!state.loaded || !clubId) return
    setLastClubId(allowed ? clubId : null)
  }, [state.loaded, allowed, clubId])

  if (!state.loaded) return <Page><Spinner /></Page>

  if (!state.club) return <Navigate to="/clubs" replace />
  // 회원이 아닌 사람이 공유받은 링크로 들어온 경우: 말없이 목록으로 보내지 않고 가입 신청으로 안내
  if (!state.me || !allowed) return <NotMember club={state.club} me={state.me} sharedSession={pathname.includes('/s/')} onChanged={load} />

  const value: ClubState = { club: state.club, me: state.me, isAdmin: state.me.role === 'admin', reload: load }

  return (
    <ClubContext.Provider value={value}>
      <header className="sticky top-0 z-10 border-b border-black/[0.06] bg-floor/90 pt-[env(safe-area-inset-top)] backdrop-blur">
        <div className={`mx-auto flex h-12 items-center px-4 ${wide ? 'max-w-4xl' : 'max-w-md'}`}>
          <Link to={`/c/${state.club.id}/about`} className="flex min-w-0 items-center gap-2" aria-label={`${state.club.name} 소개`}>
            <ClubLogo club={state.club} size={28} />
            <span className="truncate text-[15px] font-bold text-court-700">{state.club.name}</span>
          </Link>
          <Bell clubId={state.club.id} />
        </div>
      </header>
      <Outlet />
      <TabBar clubId={state.club.id} />
    </ClubContext.Provider>
  )
}

/** 헤더 오른쪽 알림 종: 안 읽은 알림 수 */
function Bell({ clubId }: { clubId: string }) {
  const unread = useUnreadCount()
  return (
    <Link
      to={`/c/${clubId}/notifications`}
      aria-label={unread ? `알림 ${unread}개 안 읽음` : '알림'}
      className="relative -mr-2 ml-auto flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-ink-soft active:bg-black/5"
    >
      <IconBell className="h-6 w-6" />
      {unread > 0 && (
        <span className="absolute right-1 top-1.5 min-w-[18px] rounded-full bg-danger px-1 text-center text-[11px] font-bold leading-[18px] text-white">
          {unread > 99 ? '99+' : unread}
        </span>
      )}
    </Link>
  )
}

/** 하단 탭: 일정 / 대진판 / 내 정보. 내 정보를 빠르게 두 번 누르면 동아리 전환 */
function TabBar({ clubId }: { clubId: string }) {
  const { pathname } = useLocation()
  const lastMeTap = useRef(0)
  const [switching, setSwitching] = useState(false)
  const base = `/c/${clubId}`
  const rest = pathname.slice(pathname.indexOf(base) + base.length)
  const active = rest.startsWith('/board') || rest.endsWith('/board') ? 'board' : rest.startsWith('/me') || rest.startsWith('/admin') || rest.startsWith('/about') ? 'me' : 'home'

  const tabs = [
    { key: 'home', to: base, label: '일정', Icon: IconCalendar },
    { key: 'board', to: `${base}/board`, label: '대진판', Icon: IconCourt },
    { key: 'me', to: `${base}/me`, label: '내 정보', Icon: IconPerson },
  ] as const

  return (
    <>
      <nav className="fixed inset-x-0 bottom-0 z-30 border-t border-black/[0.08] bg-white/95 pb-[env(safe-area-inset-bottom)] backdrop-blur" aria-label="주 메뉴">
        <div className="mx-auto grid h-16 max-w-md grid-cols-3">
          {tabs.map(({ key, to, label, Icon }) => {
            const on = active === key
            return (
              <Link
                key={key}
                to={to}
                aria-current={on ? 'page' : undefined}
                onClick={(e) => {
                  if (key !== 'me') return
                  const now = Date.now()
                  if (now - lastMeTap.current < 400) {
                    e.preventDefault()
                    lastMeTap.current = 0
                    setSwitching(true)
                  } else lastMeTap.current = now
                }}
                // touch-manipulation: 두 번 눌러도 화면 확대가 되지 않게
                className={`flex touch-manipulation flex-col items-center justify-center gap-0.5 text-[11px] font-semibold ${on ? 'text-court-600' : 'text-ink-faint'}`}
              >
                <Icon className="h-6 w-6" />
                {label}
              </Link>
            )
          })}
        </div>
      </nav>
      {/* nav의 backdrop-blur가 fixed 자식의 기준이 되므로 시트는 nav 밖에 */}
      {switching && <ClubSwitcher currentId={clubId} onClose={() => setSwitching(false)} />}
    </>
  )
}

/** 동아리 빠른 전환: 내가 승인된 동아리 목록 */
function ClubSwitcher({ currentId, onClose }: { currentId: string; onClose: () => void }) {
  const { session } = useAuth()
  const navigate = useNavigate()
  const [clubs, setClubs] = useState<Pick<Club, 'id' | 'name' | 'logo_path'>[] | null>(null)

  useEffect(() => {
    if (!session) return
    void supabase
      .from('club_members')
      .select('clubs(id, name, logo_path)')
      .eq('user_id', session.user.id)
      .eq('status', 'approved')
      .then(({ data }) => {
        const rows = ((data ?? []) as unknown as { clubs: Pick<Club, 'id' | 'name' | 'logo_path'> | null }[])
          .map((r) => r.clubs)
          .filter((c): c is Pick<Club, 'id' | 'name' | 'logo_path'> => !!c)
          .sort((a, b) => a.name.localeCompare(b.name, 'ko'))
        setClubs(rows)
      })
  }, [session])

  const go = (id: string) => {
    onClose()
    if (id === currentId) return
    setLastClubId(id)
    navigate(`/c/${id}`)
  }

  return (
    <Sheet title="동아리 전환" onClose={onClose}>
      <div className="p-4">
        {!clubs ? (
          <ListSkeleton rows={2} />
        ) : (
          <div className="divide-y divide-black/[0.06] overflow-hidden rounded-2xl bg-white ring-1 ring-black/[0.06]">
            {clubs.map((c) => (
              <button key={c.id} type="button" onClick={() => go(c.id)} className="flex w-full items-center gap-3 px-4 py-3 text-left active:bg-floor">
                <ClubLogo club={c} size={36} />
                <span className="min-w-0 flex-1 truncate font-semibold text-ink">{c.name}</span>
                {c.id === currentId && <span className="shrink-0 text-sm font-semibold text-court-600">지금 동아리</span>}
              </button>
            ))}
          </div>
        )}
        <Link to="/clubs" onClick={onClose} className="mt-3 flex h-12 items-center justify-center rounded-2xl text-sm font-semibold text-ink-soft active:bg-black/5">
          동아리 목록 (가입·개설 신청)
        </Link>
      </div>
    </Sheet>
  )
}

/** 회원이 아닐 때: 공유받은 운동 링크 등으로 들어오면 가입 신청으로 안내 */
function NotMember({ club, me, sharedSession, onChanged }: { club: Club; me: ClubMember | null; sharedSession: boolean; onChanged: () => Promise<void> }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const request = async () => {
    setBusy(true)
    setError(null)
    const { error } = await supabase.rpc('request_join', { p_club: club.id })
    setBusy(false)
    if (error) setError(errorMessage(error))
    await onChanged()
  }
  const banned = !!me?.banned_at
  const pending = me?.status === 'pending'
  return (
    <Page title="동아리 가입">
      <div className="flex flex-col items-center rounded-2xl bg-white px-5 py-8 text-center">
        <ClubLogo club={club} size={72} />
        <p className="mt-4 text-[20px] font-bold text-ink">{club.name}</p>
        {banned ? (
          <p className="mt-2 text-sm text-ink-soft">이 동아리에는 가입할 수 없어요.</p>
        ) : pending ? (
          <p className="mt-2 text-sm text-ink-soft">가입 신청을 보냈어요. 운영진이 승인하면 바로 볼 수 있어요.</p>
        ) : (
          <>
            <p className="mt-2 text-sm text-ink-soft">
              {sharedSession ? '공유받은 운동은 이 동아리 회원만 볼 수 있어요. 가입 신청하고 승인되면 참석할 수 있어요.' : '이 동아리 회원만 볼 수 있어요.'}
            </p>
            <button
              type="button"
              disabled={busy}
              onClick={() => void request()}
              className="mt-6 h-14 w-full rounded-2xl bg-court-600 text-[17px] font-semibold text-white active:bg-court-700 disabled:opacity-60"
            >
              {busy ? '신청하는 중' : '가입 신청'}
            </button>
          </>
        )}
        {error && <p className="mt-3 text-sm text-danger">{error}</p>}
      </div>
      <Link to="/clubs" className="mt-4 block text-center text-sm font-medium text-ink-soft underline underline-offset-2">
        동아리 목록으로
      </Link>
    </Page>
  )
}
