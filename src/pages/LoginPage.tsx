import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { Button, ErrorText } from '../components/ui'
import { appRootUrl, errorMessage, isSupabaseConfigured, supabase } from '../lib/supabase'

/** 배드민턴 코트 라인 (복식 기준, 위에서 본 모양) */
function CourtLines() {
  return (
    <svg viewBox="0 0 200 440" className="h-full w-full" aria-hidden>
      <g fill="none" stroke="rgba(255,255,255,0.55)" strokeWidth="2">
        <rect x="10" y="10" width="180" height="420" />
        <line x1="24" y1="10" x2="24" y2="430" />
        <line x1="176" y1="10" x2="176" y2="430" />
        <line x1="10" y1="34" x2="190" y2="34" />
        <line x1="10" y1="406" x2="190" y2="406" />
        <line x1="10" y1="160" x2="190" y2="160" />
        <line x1="10" y1="280" x2="190" y2="280" />
        <line x1="100" y1="10" x2="100" y2="160" />
        <line x1="100" y1="280" x2="100" y2="430" />
      </g>
      <line x1="0" y1="220" x2="200" y2="220" stroke="#fff" strokeWidth="3" strokeDasharray="2 4" />
    </svg>
  )
}

export default function LoginPage() {
  const { session } = useAuth()
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  if (session) return <Navigate to="/" replace />

  const signIn = async () => {
    setBusy(true)
    setError('')
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'kakao',
      options: { redirectTo: appRootUrl() },
    })
    if (error) {
      setError(errorMessage(error))
      setBusy(false)
    }
  }

  return (
    <main className="relative flex min-h-dvh flex-col overflow-hidden bg-court-600 px-6 pb-[max(32px,env(safe-area-inset-bottom))] pt-[max(48px,env(safe-area-inset-top))] text-white">
      <div className="pointer-events-none absolute -right-16 top-10 h-[78%] w-[62%] opacity-90">
        <CourtLines />
      </div>

      <div className="relative mt-auto max-w-md">
        <h1 className="text-[44px] font-extrabold leading-[1.05] tracking-tight">
          배드민턴
          <br />
          동아리
        </h1>
        <p className="mt-4 text-[17px] leading-relaxed text-white/80">
          운동 투표는 정해진 시각에 열리고,
          <br />
          현장 대진은 폰 하나로 짜요.
        </p>
      </div>

      <div className="relative mt-12 w-full max-w-md">
        <Button variant="kakao" className="h-14 w-full text-[16px]" onClick={signIn} disabled={busy || !isSupabaseConfigured}>
          카카오로 시작하기
        </Button>
        {!isSupabaseConfigured && (
          <p className="mt-3 text-sm text-shuttle-100">Supabase 환경변수(VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY)가 설정되지 않았어요.</p>
        )}
        <div className="[&_p]:text-shuttle-100">
          <ErrorText>{error}</ErrorText>
        </div>
      </div>
    </main>
  )
}
