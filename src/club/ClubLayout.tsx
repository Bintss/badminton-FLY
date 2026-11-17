import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import { Link, Navigate, Outlet, useLocation, useParams } from 'react-router-dom'
import { IconCalendar, IconCourt, IconPerson } from '../components/icons'
import { useAuth } from '../auth/AuthProvider'
import { Page, Spinner } from '../components/ui'
import { setLastClubId } from '../lib/lastClub'
import { supabase } from '../lib/supabase'
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

  const allowed = Boolean(state.club && state.me?.status === 'approved')

  useEffect(() => {
    if (!state.loaded || !clubId) return
    setLastClubId(allowed ? clubId : null)
  }, [state.loaded, allowed, clubId])

  if (!state.loaded) return <Page><Spinner /></Page>

  if (!state.club || !state.me || !allowed) {
    return <Navigate to="/clubs" replace />
  }

  const value: ClubState = { club: state.club, me: state.me, isAdmin: state.me.role === 'admin', reload: load }

  return (
    <ClubContext.Provider value={value}>
      <header className="sticky top-0 z-10 border-b border-black/[0.06] bg-floor/90 pt-[env(safe-area-inset-top)] backdrop-blur">
        <div className={`mx-auto flex h-12 items-center px-4 ${wide ? 'max-w-4xl' : 'max-w-md'}`}>
          <Link to={`/c/${state.club.id}/about`} className="flex min-w-0 items-center gap-2" aria-label={`${state.club.name} 소개`}>
            <ClubLogo club={state.club} size={28} />
            <span className="truncate text-[15px] font-bold text-court-700">{state.club.name}</span>
          </Link>
        </div>
      </header>
      <Outlet />
      <TabBar clubId={state.club.id} />
    </ClubContext.Provider>
  )
}

/** 하단 탭: 일정 / 대진판 / 내 정보 */
function TabBar({ clubId }: { clubId: string }) {
  const { pathname } = useLocation()
  const base = `/c/${clubId}`
  const rest = pathname.slice(pathname.indexOf(base) + base.length)
  const active = rest.startsWith('/board') || rest.endsWith('/board') ? 'board' : rest.startsWith('/me') || rest.startsWith('/admin') || rest.startsWith('/about') ? 'me' : 'home'

  const tabs = [
    { key: 'home', to: base, label: '일정', Icon: IconCalendar },
    { key: 'board', to: `${base}/board`, label: '대진판', Icon: IconCourt },
    { key: 'me', to: `${base}/me`, label: '내 정보', Icon: IconPerson },
  ] as const

  return (
    <nav className="fixed inset-x-0 bottom-0 z-30 border-t border-black/[0.08] bg-white/95 pb-[env(safe-area-inset-bottom)] backdrop-blur" aria-label="주 메뉴">
      <div className="mx-auto grid h-16 max-w-md grid-cols-3">
        {tabs.map(({ key, to, label, Icon }) => {
          const on = active === key
          return (
            <Link
              key={key}
              to={to}
              aria-current={on ? 'page' : undefined}
              className={`flex flex-col items-center justify-center gap-0.5 text-[11px] font-semibold ${on ? 'text-court-600' : 'text-ink-faint'}`}
            >
              <Icon className="h-6 w-6" />
              {label}
            </Link>
          )
        })}
      </div>
    </nav>
  )
}
