import { useCallback, useEffect, useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { IconChevronLeft } from '../components/icons'
import { ConfirmButton } from '../components/ConfirmButton'
import { GenderToggle } from '../components/GenderToggle'
import { Sheet } from '../components/Sheet'
import { LevelSelect } from '../components/LevelPicker'
import { useToast } from '../components/toast'
import { Button, Empty, ErrorText, List, ListSkeleton, Page, SectionTitle } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'
import type { MemberRole, MemberWithProfile } from '../lib/types'

export default function MembersAdminPage() {
  const { club, isAdmin, reload: reloadClub } = useClub()
  const { session } = useAuth()
  const [members, setMembers] = useState<MemberWithProfile[] | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const [managing, setManaging] = useState<string | null>(null)
  const toast = useToast()

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('club_members')
      // club_members는 user_id·decided_by 두 곳에서 profiles를 참조하므로 관계를 지정해야 한다
      .select('*, profiles!club_members_user_id_fkey(id, display_name)')
      .eq('club_id', club.id)
      .or('status.in.(pending,approved),banned_at.not.is.null')
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
  if (!members)
    return (
      <Page title="회원 관리" back={back}>
        {error ? (
          <div className="space-y-3">
            <ErrorText>{error}</ErrorText>
            <Button variant="secondary" onClick={() => void load()}>
              다시 불러오기
            </Button>
          </div>
        ) : (
          <ListSkeleton rows={3} />
        )}
      </Page>
    )

  const decide = async (userId: string, approve: boolean) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('decide_member', { p_club: club.id, p_user: userId, p_approve: approve })
    if (error) setError(errorMessage(error))
    else toast.success(approve ? '가입을 승인했어요' : '가입을 거절했어요')
    await load()
    setBusy(null)
  }

  const setLevel = async (userId: string, level: string | null) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('set_member_level', { p_club: club.id, p_user: userId, p_level: level })
    // 목록 아래쪽에서 바꿔도 보이게 토스트로 (위쪽 오류 문구는 스크롤하면 안 보임)
    if (error) toast.error(errorMessage(error))
    else toast.success(level ? `급수를 ${level === '초심' ? '초심으로' : `${level}로`} 바꿨어요` : '급수를 비웠어요')
    await load()
    if (userId === session?.user.id) await reloadClub()
    setBusy(null)
  }

  const setGender = async (userId: string, gender: 'M' | 'F' | null) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('set_member_gender', { p_club: club.id, p_user: userId, p_gender: gender })
    if (error) toast.error(errorMessage(error))
    await load()
    if (userId === session?.user.id) await reloadClub()
    setBusy(null)
  }

  const setRole = async (userId: string, role: MemberRole) => {
    setBusy(userId)
    setError('')
    const { error } = await supabase.rpc('set_member_role', { p_club: club.id, p_user: userId, p_role: role })
    if (error) toast.error(errorMessage(error))
    else toast.success(role === 'admin' ? '운영진으로 지정했어요' : '운영진에서 해제했어요')
    await load()
    if (userId === session?.user.id) await reloadClub() // 본인 운영진 해제 시 화면 권한 갱신
    setBusy(null)
  }

  const remove = async (m: MemberWithProfile, ban: boolean) => {
    setBusy(m.user_id)
    setError('')
    setManaging(null)
    const name = m.profiles?.display_name ?? '회원'
    const { data, error } = await supabase.rpc('remove_member', { p_club: club.id, p_user: m.user_id, p_ban: ban })
    if (error) setError(errorMessage(error))
    else {
      const canceled = (data as number | null) ?? 0
      toast.success(`${name}님을 ${ban ? '강퇴' : '내보냈'}${ban ? '했어요' : '어요'}${canceled > 0 ? `. 다음 운동 신청 ${canceled}건도 취소했어요` : ''}`)
    }
    await load()
    setBusy(null)
  }

  const banApplicant = async (m: MemberWithProfile) => {
    setBusy(m.user_id)
    setError('')
    const { error } = await supabase.rpc('ban_applicant', { p_club: club.id, p_user: m.user_id })
    if (error) setError(errorMessage(error))
    else toast.success(`${m.profiles?.display_name ?? '신청자'}님을 거절했어요. 다시 신청할 수 없어요`)
    await load()
    setBusy(null)
  }

  const unban = async (m: MemberWithProfile) => {
    setBusy(m.user_id)
    setError('')
    const { error } = await supabase.rpc('unban_member', { p_club: club.id, p_user: m.user_id })
    if (error) setError(errorMessage(error))
    else toast.success(`${m.profiles?.display_name ?? '회원'}님 강퇴를 해제했어요. 다시 가입 신청할 수 있어요`)
    await load()
    setBusy(null)
  }

  const pending = members.filter((m) => m.status === 'pending')
  const approved = members.filter((m) => m.status === 'approved')
  const banned = members.filter((m) => m.banned_at && m.status !== 'approved' && m.status !== 'pending')
  const target = managing ? members.find((m) => m.user_id === managing) : undefined
  const isSelf = (m: MemberWithProfile) => m.user_id === session?.user.id

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
                <ConfirmButton
                  label="다시 신청 못 하게 거절"
                  confirmLabel="한 번 더 누르면 차단"
                  className="mt-1 h-7 px-0 text-xs font-medium text-ink-faint underline underline-offset-2"
                  armedClassName="mt-1 h-7 bg-danger px-2 text-xs text-white"
                  disabled={busy === m.user_id}
                  onConfirm={() => void banApplicant(m)}
                />
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
            <div className="min-w-0 flex-1">
              <span className="block truncate font-medium text-ink">{m.profiles?.display_name ?? '이름 없음'}</span>
              {m.role === 'admin' && <span className="block text-xs font-semibold text-court-600">운영진</span>}
            </div>
            <LevelSelect value={m.level} disabled={busy === m.user_id} label={`${m.profiles?.display_name ?? ''} 급수`} onChange={(lv) => void setLevel(m.user_id, lv)} />
            <GenderToggle compact value={m.gender} disabled={busy === m.user_id} label={`${m.profiles?.display_name ?? ''} 성별`} onChange={(g) => void setGender(m.user_id, g)} />
            <button
              className="shrink-0 rounded-lg px-2 py-1.5 text-sm font-medium text-ink-soft active:bg-floor disabled:opacity-40"
              disabled={busy === m.user_id}
              onClick={() => setManaging(m.user_id)}
            >
              관리
            </button>
          </div>
        ))}
      </List>

      {banned.length > 0 && (
        <>
          <SectionTitle right={`${banned.length}명`}>강퇴한 사람</SectionTitle>
          <List>
            {banned.map((m) => (
              <div key={m.user_id} className="flex items-center justify-between gap-2 px-4 py-3">
                <div className="min-w-0">
                  <p className="truncate font-medium text-ink">{m.profiles?.display_name ?? '이름 없음'}</p>
                  <p className="text-xs text-ink-faint">{new Date(m.banned_at!).toLocaleDateString('ko-KR')} 강퇴, 다시 가입 신청할 수 없어요</p>
                </div>
                <Button variant="secondary" className="h-10 shrink-0" disabled={busy === m.user_id} onClick={() => void unban(m)}>
                  해제
                </Button>
              </div>
            ))}
          </List>
        </>
      )}

      {target && (
        <Sheet title={target.profiles?.display_name ?? '회원'} onClose={() => setManaging(null)}>
          <div className="space-y-4 p-4">
            <div>
              <Button
                variant="secondary"
                className="w-full"
                disabled={busy === target.user_id}
                onClick={() => {
                  setManaging(null)
                  void setRole(target.user_id, target.role === 'admin' ? 'member' : 'admin')
                }}
              >
                {target.role === 'admin' ? '운영진 해제' : '운영진으로 지정'}
              </Button>
            </div>
            {isSelf(target) ? (
              <p className="text-sm leading-relaxed text-ink-soft">본인은 내보낼 수 없어요. 동아리를 떠나려면 내 정보의 동아리 나가기를 쓰세요.</p>
            ) : target.role === 'admin' ? (
              <p className="text-sm leading-relaxed text-ink-soft">운영진은 바로 내보낼 수 없어요. 먼저 운영진에서 해제하세요.</p>
            ) : (
              <div className="space-y-3 border-t border-black/[0.06] pt-4">
                <div>
                  <ConfirmButton
                    label="내보내기"
                    confirmLabel="한 번 더 누르면 내보내요"
                    className="h-12 w-full border border-black/10 bg-white text-[15px] text-ink"
                    armedClassName="h-12 w-full bg-ink text-[15px] text-white"
                    disabled={busy === target.user_id}
                    onConfirm={() => void remove(target, false)}
                  />
                  <p className="mt-1.5 text-xs leading-relaxed text-ink-faint">동아리에서 빠져요. 다시 가입 신청은 할 수 있어요.</p>
                </div>
                <div>
                  <ConfirmButton
                    label="강퇴"
                    confirmLabel="한 번 더 누르면 강퇴해요"
                    className="h-12 w-full border border-danger/30 bg-white text-[15px] text-danger"
                    armedClassName="h-12 w-full bg-danger text-[15px] text-white"
                    disabled={busy === target.user_id}
                    onConfirm={() => void remove(target, true)}
                  />
                  <p className="mt-1.5 text-xs leading-relaxed text-ink-faint">동아리에서 빠지고 다시 가입 신청도 못 해요. 아래 강퇴한 사람 목록에서 해제할 수 있어요.</p>
                </div>
                <p className="text-xs leading-relaxed text-ink-faint">두 경우 모두 아직 시작 안 한 운동의 참석·대기 신청은 취소되고, 빈자리는 대기자가 이어받아요. 지난 기록은 남아요.</p>
              </div>
            )}
          </div>
        </Sheet>
      )}
    </Page>
  )
}
