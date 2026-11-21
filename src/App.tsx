import { useEffect } from 'react'
import { BrowserRouter, Navigate, Outlet, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { AuthProvider, useAuth } from './auth/AuthProvider'
import { ToastProvider } from './components/toast'
import BoardEntryPage from './pages/BoardEntryPage'
import ClubAboutPage from './pages/ClubAboutPage'
import ClubEditPage from './pages/ClubEditPage'
import ClubLayout from './club/ClubLayout'
import { Page, Spinner } from './components/ui'
import { getLastClubId } from './lib/lastClub'
import { notifyUnreadChanged } from './lib/notifications'
import { supabase } from './lib/supabase'
import BoardPage from './pages/BoardPage'
import ClubHomePage from './pages/ClubHomePage'
import ClubsPage from './pages/ClubsPage'
import GuidePage from './pages/GuidePage'
import ClubRequestsAdminPage from './pages/ClubRequestsAdminPage'
import LoginPage from './pages/LoginPage'
import MePage from './pages/MePage'
import FlashNewPage from './pages/FlashNewPage'
import JoinPage from './pages/JoinPage'
import { peekInvite, rememberInvite } from './lib/pendingInvite'
import MembersAdminPage from './pages/MembersAdminPage'
import SessionPage from './pages/SessionPage'
import NotificationsPage from './pages/NotificationsPage'
import TemplatesAdminPage from './pages/TemplatesAdminPage'
import TournamentNewPage from './pages/TournamentNewPage'
import TournamentPage from './pages/TournamentPage'

function RequireAuth() {
  const { session, loading } = useAuth()
  const location = useLocation()
  if (loading) return <Page><Spinner /></Page>
  if (!session) {
    // 초대 링크로 왔으면 로그인하고 돌아왔을 때 이어서 가입하도록 기억
    const m = location.pathname.match(/^\/join\/([^/]+)/)
    if (m) rememberInvite(m[1])
    return <Navigate to="/login" replace />
  }
  return (
    <>
      <ReadFromPush />
      <Outlet />
    </>
  )
}

/** 폰 알림을 눌러 들어온 경우(?read=알림번호): 그 알림을 읽음 처리하고 주소에서 지운다 → 종·앱 아이콘 숫자가 줄어든다 */
function ReadFromPush() {
  const location = useLocation()
  const navigate = useNavigate()
  useEffect(() => {
    const params = new URLSearchParams(location.search)
    const id = Number(params.get('read'))
    if (!Number.isInteger(id) || id <= 0) return
    params.delete('read')
    navigate({ pathname: location.pathname, search: params.toString() ? `?${params}` : '' }, { replace: true })
    void supabase.rpc('mark_notifications_read', { p_ids: [id] }).then(() => notifyUnreadChanged())
  }, [location.search, location.pathname, navigate])
  return null
}

/** 루트: 마지막 동아리가 있으면 거기로, 없으면 동아리 선택 (승인 여부는 ClubLayout이 다시 확인) */
function RootRedirect() {
  const invite = peekInvite()
  if (invite) return <Navigate to={`/join/${invite}`} replace />
  const last = getLastClubId()
  return <Navigate to={last ? `/c/${last}` : '/clubs'} replace />
}

export default function App() {
  return (
    <AuthProvider>
      <ToastProvider>
      {/* GitHub Pages 하위 경로(/repo/) 대응 */}
      <BrowserRouter basename={import.meta.env.BASE_URL.replace(/\/$/, '')}>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route element={<RequireAuth />}>
            <Route index element={<RootRedirect />} />
            <Route path="/clubs" element={<ClubsPage />} />
            <Route path="/join/:token" element={<JoinPage />} />
            <Route path="/admin/clubs" element={<ClubRequestsAdminPage />} />
            <Route path="/c/:clubId" element={<ClubLayout />}>
              <Route index element={<ClubHomePage />} />
              <Route path="me" element={<MePage />} />
              <Route path="board" element={<BoardEntryPage />} />
              <Route path="about" element={<ClubAboutPage />} />
              <Route path="guide" element={<GuidePage />} />
              <Route path="admin/club" element={<ClubEditPage />} />
              <Route path="flash/new" element={<FlashNewPage />} />
              <Route path="tournament/new" element={<TournamentNewPage />} />
              <Route path="notifications" element={<NotificationsPage />} />
              <Route path="s/:sessionId" element={<SessionPage />} />
              <Route path="s/:sessionId/board" element={<BoardPage />} />
              <Route path="s/:sessionId/tournament" element={<TournamentPage />} />
              <Route path="admin/members" element={<MembersAdminPage />} />
              <Route path="admin/templates" element={<TemplatesAdminPage />} />
            </Route>
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
      </ToastProvider>
    </AuthProvider>
  )
}
