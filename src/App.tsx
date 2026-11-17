import { BrowserRouter, Navigate, Outlet, Route, Routes } from 'react-router-dom'
import { AuthProvider, useAuth } from './auth/AuthProvider'
import { ToastProvider } from './components/toast'
import BoardEntryPage from './pages/BoardEntryPage'
import ClubLayout from './club/ClubLayout'
import { Page, Spinner } from './components/ui'
import { getLastClubId } from './lib/lastClub'
import BoardPage from './pages/BoardPage'
import ClubHomePage from './pages/ClubHomePage'
import ClubsPage from './pages/ClubsPage'
import LoginPage from './pages/LoginPage'
import MePage from './pages/MePage'
import FlashNewPage from './pages/FlashNewPage'
import MembersAdminPage from './pages/MembersAdminPage'
import SessionPage from './pages/SessionPage'
import TemplatesAdminPage from './pages/TemplatesAdminPage'

function RequireAuth() {
  const { session, loading } = useAuth()
  if (loading) return <Page><Spinner /></Page>
  if (!session) return <Navigate to="/login" replace />
  return <Outlet />
}

/** 루트: 마지막 동아리가 있으면 거기로, 없으면 동아리 선택 (승인 여부는 ClubLayout이 다시 확인) */
function RootRedirect() {
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
            <Route path="/c/:clubId" element={<ClubLayout />}>
              <Route index element={<ClubHomePage />} />
              <Route path="me" element={<MePage />} />
              <Route path="board" element={<BoardEntryPage />} />
              <Route path="flash/new" element={<FlashNewPage />} />
              <Route path="s/:sessionId" element={<SessionPage />} />
              <Route path="s/:sessionId/board" element={<BoardPage />} />
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
