import { useCallback, useEffect, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { Badge, Button, Card, ErrorText, Page, Spinner } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'
import type { MemberRole, MemberWithProfile } from '../lib/types'

export default function MembersAdminPage() {
  const { club, isAdmin, reload: reloadClub } = useClub()
  const { session } = useAuth()
  const [members, setMembers] = useState<MemberWithProfile[] | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState<string | null>(null)

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('club_members')
      .select('*, profiles(id, display_name)')
      .eq('club_id', club.id)
      .in('status', ['pending', 'approved'])
      .order('requested_at')
    if (error) setError(errorMessage(error))
    else setMembers(data as MemberWithProfile[])
  }, [club.id])

  useEffect(() => {
    void load()
  }, [load])

  if (!isAdmin) return <Navigate to={`/c/${club.id}`} replace />
  if (!members) return <Page title="회원 관리"><Spinner /></Page>

  const decide = async (userId: string, approve: boolean) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('decide_member', { p_club: club.id, p_user: userId, p_approve: approve })
    if (error) setError(errorMessage(error))
    await load()
    setBusy(null)
  }

  const setRole = async (userId: string, role: MemberRole) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('set_member_role', { p_club: club.id, p_user: userId, p_role: role })
    if (error) setError(errorMessage(error))
    await load()
    if (userId === session?.user.id) await reloadClub() // 본인 운영진 해제 시 화면 권한 갱신
    setBusy(null)
  }

  const pending = members.filter((m) => m.status === 'pending')
  const approved = members.filter((m) => m.status === 'approved')

  return (
    <Page title="회원 관리">
      <ErrorText>{error}</ErrorText>

      <h2 className="mb-2 mt-2 text-sm font-semibold text-neutral-500">가입 신청 {pending.length}</h2>
      {pending.length === 0 && <p className="text-sm text-neutral-500">대기 중인 신청이 없어요.</p>}
      <div className="space-y-2">
        {pending.map((m) => (
          <Card key={m.user_id} className="flex items-center justify-between gap-2">
            <div className="min-w-0">
              <p className="truncate font-semibold text-neutral-900">{m.profiles?.display_name ?? '이름 없음'}</p>
              <p className="text-xs text-neutral-500">{new Date(m.requested_at).toLocaleDateString('ko-KR')} 신청</p>
            </div>
            <div className="flex shrink-0 gap-2">
              <Button variant="danger" disabled={busy === m.user_id} onClick={() => void decide(m.user_id, false)}>
                거절
              </Button>
              <Button disabled={busy === m.user_id} onClick={() => void decide(m.user_id, true)}>
                승인
              </Button>
            </div>
          </Card>
        ))}
      </div>

      <h2 className="mb-2 mt-6 text-sm font-semibold text-neutral-500">회원 {approved.length}</h2>
      <Card className="divide-y divide-neutral-100 p-0">
        {approved.map((m) => (
          <div key={m.user_id} className="flex items-center justify-between gap-2 px-4 py-3">
            <div className="flex min-w-0 items-center gap-2">
              <span className="truncate font-medium text-neutral-900">{m.profiles?.display_name ?? '이름 없음'}</span>
              {m.level && <Badge>{m.level}</Badge>}
              {m.role === 'admin' && <Badge tone="blue">운영진</Badge>}
            </div>
            <button
              className="shrink-0 text-sm text-neutral-500 disabled:opacity-40"
              disabled={busy === m.user_id}
              onClick={() => void setRole(m.user_id, m.role === 'admin' ? 'member' : 'admin')}
            >
              {m.role === 'admin' ? '운영진 해제' : '운영진 지정'}
            </button>
          </div>
        ))}
      </Card>
    </Page>
  )
}
