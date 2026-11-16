import { useState, type FormEvent } from 'react'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { Button, Card, ErrorText, Page } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'

export default function MePage() {
  const { session, profile, refreshProfile } = useAuth()
  const { club, me, reload } = useClub()
  const [name, setName] = useState(profile?.display_name ?? '')
  const [level, setLevel] = useState(me.level ?? '')
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)

  const save = async (e: FormEvent) => {
    e.preventDefault()
    if (!session || !name.trim()) return
    setBusy(true)
    setError('')
    setSaved(false)
    const nameRes = await supabase.from('profiles').update({ display_name: name.trim() }).eq('id', session.user.id)
    const levelRes = await supabase.rpc('set_my_level', { p_club: club.id, p_level: level })
    setBusy(false)
    if (nameRes.error || levelRes.error) {
      setError(errorMessage(nameRes.error ?? levelRes.error))
      return
    }
    await Promise.all([refreshProfile(), reload()])
    setSaved(true)
  }

  return (
    <Page title="내 정보">
      <Card>
        <form onSubmit={save} className="space-y-4">
          <label className="block">
            <span className="text-sm font-medium text-neutral-700">이름</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={30}
              className="mt-1 h-11 w-full rounded-xl border border-neutral-200 px-3 text-[15px] outline-none focus:border-neutral-900"
            />
            <span className="mt-1 block text-xs text-neutral-400">모든 동아리에서 같은 이름으로 보여요.</span>
          </label>
          <label className="block">
            <span className="text-sm font-medium text-neutral-700">급수</span>
            <input
              value={level}
              onChange={(e) => setLevel(e.target.value)}
              maxLength={10}
              placeholder="예: D조, 초심"
              className="mt-1 h-11 w-full rounded-xl border border-neutral-200 px-3 text-[15px] outline-none focus:border-neutral-900"
            />
            <span className="mt-1 block text-xs text-neutral-400">{club.name}에서만 표시돼요. 대진에는 쓰이지 않아요.</span>
          </label>
          <Button type="submit" className="w-full" disabled={busy || !name.trim()}>
            저장
          </Button>
          {saved && <p className="text-sm text-green-700">저장했어요.</p>}
          <ErrorText>{error}</ErrorText>
        </form>
      </Card>
    </Page>
  )
}
