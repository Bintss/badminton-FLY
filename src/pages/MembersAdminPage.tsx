import { useCallback, useEffect, useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { IconChevronLeft } from '../components/icons'
import { GenderToggle } from '../components/GenderToggle'
import { useToast } from '../components/toast'
import { Badge, Button, Empty, ErrorText, List, ListSkeleton, Page, SectionTitle } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'
import type { MemberRole, MemberWithProfile } from '../lib/types'

export default function MembersAdminPage() {
  const { club, isAdmin, reload: reloadClub } = useClub()
  const { session } = useAuth()
  const [members, setMembers] = useState<MemberWithProfile[] | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const toast = useToast()

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

  const back = (
    <Link to={`/c/${club.id}/me`} className="-ml-1 inline-flex items-center gap-0.5 text-sm font-medium text-ink-soft">
      <IconChevronLeft className="h-4 w-4" />
      내 정보
    </Link>
  )
  if (!isAdmin) return <Navigate to={`/c/${club.id}`} replace />
  if (!members) return <Page title="회원 관리" back={back}><ListSkeleton rows={3} /></Page>

  const decide = async (userId: string, approve: boolean) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('decide_member', { p_club: club.id, p_user: userId, p_approve: approve })
    if (error) setError(errorMessage(error))
    else toast.success(approve ? '가입을 승인했어요' : '가입을 거절했어요')
    await load()
    setBusy(null)
  }

  const setGender = async (userId: string, gender: 'M' | 'F' | null) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('set_member_gender', { p_club: club.id, p_user: userId, p_gender: gender })
    if (error) setError(errorMessage(error))
    await load()
    if (userId === session?.user.id) await reloadClub()
    setBusy(null)
  }

  const setRole = async (userId: string, role: MemberRole) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('set_member_role', { p_club: club.id, p_user: userId, p_role: role })
    if (error) setError(errorMessage(error))
    else toast.success(role === 'admin' ? '운영진으로 지정했어요' : '운영진에서 해제했어요')
    await load()
    if (userId === session?.user.id) await reloadClub() // 본인 운영진 해제 시 화면 권한 갱신
    setBusy(null)
  }

  const pending = members.filter((m) => m.status === 'pending')
  const approved = members.filter((m) => m.status === 'approved')

  return (
    <Page title="회원 관리" back={back}>
      <ErrorText>{error}</ErrorText>

      <SectionTitle right={pending.length > 0 ? `${pending.length}명` : undefined}>가입 신청</SectionTitle>
      {pending.length === 0 ? (
        <Empty title="기다리는 신청이 없어요" />
      ) : (
        <List>
          {pending.map((m) => (
            <div key={m.user_id} className="flex items-center justify-between gap-2 px-4 py-3">
              <div className="min-w-0">
                <p className="truncate font-semibold text-ink">{m.profiles?.display_name ?? '이름 없음'}</p>
                <p className="text-xs text-ink-faint">{new Date(m.requested_at).toLocaleDateString('ko-KR')} 신청</p>
              </div>
              <div className="flex shrink-0 gap-2">
                <Button variant="danger" className="h-10" disabled={busy === m.user_id} onClick={() => void decide(m.user_id, false)}>
                  거절
                </Button>
                <Button className="h-10" disabled={busy === m.user_id} onClick={() => void decide(m.user_id, true)}>
                  승인
                </Button>
              </div>
            </div>
          ))}
        </List>
      )}

      <SectionTitle right={`${approved.length}명`}>회원</SectionTitle>
      <List>
        {approved.map((m) => (
          <div key={m.user_id} className="flex items-center justify-between gap-2 px-4 py-3">
            <div className="flex min-w-0 flex-1 items-center gap-2">
              <span className="truncate font-medium text-ink">{m.profiles?.display_name ?? '이름 없음'}</span>
              {m.role === 'admin' && <Badge tone="court">운영진</Badge>}
              {m.level && <Badge tone="outline">{m.level}</Badge>}
            </div>
            <GenderToggle compact value={m.gender} disabled={busy === m.user_id} label={`${m.profiles?.display_name ?? ''} 성별`} onChange={(g) => void setGender(m.user_id, g)} />
            <button
              className="shrink-0 rounded-lg px-2 py-1 text-sm font-medium text-ink-soft active:bg-floor disabled:opacity-40"
              disabled={busy === m.user_id}
              onClick={() => void setRole(m.user_id, m.role === 'admin' ? 'member' : 'admin')}
            >
              {m.role === 'admin' ? '운영진 해제' : '운영진 지정'}
            </button>
          </div>
        ))}
      </List>
    </Page>
  )
}
