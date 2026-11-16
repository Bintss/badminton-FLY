import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { Button, ErrorText, Page } from '../components/ui'
import { appRootUrl, errorMessage, isSupabaseConfigured, supabase } from '../lib/supabase'

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
    <Page>
      <div className="flex min-h-[80dvh] flex-col justify-center">
        <h1 className="text-2xl font-bold text-neutral-900">배드민턴 운동</h1>
        <p className="mt-2 text-neutral-600">운동 투표와 현장 대진을 한 곳에서.</p>
        <Button variant="kakao" className="mt-10 w-full" onClick={signIn} disabled={busy || !isSupabaseConfigured}>
          카카오로 시작하기
        </Button>
        {!isSupabaseConfigured && (
          <ErrorText>Supabase 환경변수(VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY)가 설정되지 않았어요.</ErrorText>
        )}
        <ErrorText>{error}</ErrorText>
      </div>
    </Page>
  )
}
