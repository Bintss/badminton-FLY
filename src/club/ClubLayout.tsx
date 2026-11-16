import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import { Link, Navigate, Outlet, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { Page, Spinner } from '../components/ui'
import { setLastClubId } from '../lib/lastClub'
import { supabase } from '../lib/supabase'
import type { Club, ClubMember } from '../lib/types'

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
  const [state, setState] = useState<{ club: Club | null; me: ClubMember | null; loaded: boolean }>({
    club: null,
    me: null,
    loaded: false,
  })

  const load = useCallback(async () => {
    if (!clubId || !session) return
    const [club, me] = await Promise.all([
      supabase.from('clubs').select('id, name, created_at').eq('id', clubId).maybeSingle(),
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
      <div className="sticky top-0 z-10 border-b border-neutral-200 bg-white/90 backdrop-blur">
        <div className="mx-auto flex h-12 max-w-md items-center justify-between px-4">
          <Link to={`/c/${state.club.id}`} className="truncate font-bold text-neutral-900">
            {state.club.name}
          </Link>
          <Link to="/clubs" className="text-sm text-neutral-500">
            동아리 전환
          </Link>
        </div>
      </div>
      <Outlet />
    </ClubContext.Provider>
  )
}
