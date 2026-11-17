import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { useClub } from '../club/ClubLayout'
import { Field, Input } from '../components/form'
import { ConfirmButton } from '../components/ConfirmButton'
import { GenderToggle } from '../components/GenderToggle'
import { setLastClubId } from '../lib/lastClub'
import { LevelPicker } from '../components/LevelPicker'
import { IconChevronRight } from '../components/icons'
import { useToast } from '../components/toast'
import { Badge, Button, Card, List, Page, SectionTitle } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'

export default function MePage() {
  const { session, profile, refreshProfile, signOut } = useAuth()
  const { club, me, isAdmin, reload } = useClub()
  const toast = useToast()
  const [name, setName] = useState(profile?.display_name ?? '')
  const [level, setLevel] = useState<string | null>(me.level ?? null)
  const [gender, setGender] = useState(me.gender ?? null)
  const [busy, setBusy] = useState(false)
  const [pendingCount, setPendingCount] = useState(0)
  const navigate = useNavigate()

  const leave = async () => {
    setBusy(true)
    const { error } = await supabase.rpc('leave_club', { p_club: club.id })
    setBusy(false)
    if (error) {
      toast.error(errorMessage(error))
      return
    }
    setLastClubId(null)
    toast.success(`${club.name}에서 나왔어요`)
    navigate('/clubs', { replace: true })
  }

  useEffect(() => {
    if (!isAdmin) return
    supabase
      .from('club_members')
      .select('user_id', { count: 'exact', head: true })
      .eq('club_id', club.id)
      .eq('status', 'pending')
      .then(({ count }) => setPendingCount(count ?? 0))
  }, [club.id, isAdmin])

  const dirty = name.trim() !== (profile?.display_name ?? '') || level !== (me.level ?? null) || gender !== (me.gender ?? null)

  const save = async (e: FormEvent) => {
    e.preventDefault()
    if (!session || !name.trim()) return
    setBusy(true)
    const nameRes = await supabase.from('profiles').update({ display_name: name.trim() }).eq('id', session.user.id)
    const levelRes = await supabase.rpc('set_my_level', { p_club: club.id, p_level: level })
    const genderRes = await supabase.rpc('set_my_gender', { p_club: club.id, p_gender: gender })
    setBusy(false)
    if (nameRes.error || levelRes.error || genderRes.error) {
      toast.error(errorMessage(nameRes.error ?? levelRes.error ?? genderRes.error))
      return
    }
    await Promise.all([refreshProfile(), reload()])
    toast.success('저장했어요')
  }

  return (
    <Page title="내 정보">
      <Card>
        <form onSubmit={save} className="space-y-4">
          <Field label="이름" hint="모든 동아리에서 같은 이름으로 보여요.">
            <Input value={name} onChange={(e) => setName(e.target.value)} maxLength={30} />
          </Field>
          <Field label={`급수 (${club.name})`} asGroup hint="자체대회 자동 대진에서 두 팀 실력을 맞출 때 써요. 고른 걸 다시 누르면 비워져요.">
            <LevelPicker value={level} onChange={setLevel} />
          </Field>
          <Field label="성별" asGroup hint="자체대회에서 혼복·남복·여복을 짤 때 써요.">
            <div>
              <GenderToggle value={gender} onChange={setGender} />
            </div>
          </Field>
          <Button type="submit" className="w-full" disabled={busy || !name.trim() || !dirty}>
            저장
          </Button>
        </form>
      </Card>

      {isAdmin && (
        <>
          <SectionTitle>운영</SectionTitle>
          <List>
            <MenuRow to={`/c/${club.id}/admin/club`} label="동아리 정보 수정" sub="로고, 소개, 장소" />
            <MenuRow to={`/c/${club.id}/admin/templates`} label="정기운동 관리" sub="요일, 시간, 투표 오픈" />
            <MenuRow
              to={`/c/${club.id}/admin/members`}
              label="회원 관리"
              sub={pendingCount > 0 ? undefined : '가입 승인, 운영진 지정'}
              badge={pendingCount > 0 ? <Badge tone="shuttle">가입 신청 {pendingCount}</Badge> : undefined}
            />
          </List>
        </>
      )}

      <SectionTitle>계정</SectionTitle>
      <List>
        <MenuRow to={`/c/${club.id}/about`} label="동아리 소개" sub="장소, 정기운동, 연락 링크" />
        <MenuRow to="/clubs" label="동아리 전환" sub="다른 동아리 가입, 새 동아리 만들기" />
        <button className="flex w-full items-center justify-between px-4 py-4 text-left active:bg-floor" onClick={() => void signOut()}>
          <span className="font-medium text-danger">로그아웃</span>
        </button>
      </List>

      <div className="mt-6 px-1">
        <ConfirmButton
          label="동아리 나가기"
          confirmLabel={`${club.name}에서 나가요. 한 번 더 누르세요`}
          className="h-10 px-0 text-sm font-medium text-ink-faint underline underline-offset-4"
          armedClassName="h-10 bg-danger px-3 text-sm text-white"
          disabled={busy}
          onConfirm={() => void leave()}
        />
        <p className="mt-1 text-xs leading-relaxed text-ink-faint">
          아직 시작 안 한 운동의 참석·대기 신청은 취소돼요. 다시 들어오려면 가입 신청을 하고 운영진 승인을 받아야 해요.
          {isAdmin && ' 마지막 운영진은 다른 사람을 운영진으로 지정한 뒤에 나갈 수 있어요.'}
        </p>
      </div>
    </Page>
  )
}

function MenuRow({ to, label, sub, badge }: { to: string; label: string; sub?: string; badge?: React.ReactNode }) {
  return (
    <Link to={to} className="flex items-center justify-between gap-3 px-4 py-4 active:bg-floor">
      <span className="font-medium text-ink">{label}</span>
      <span className="flex items-center gap-2 text-sm text-ink-faint">
        {badge ?? sub}
        <IconChevronRight className="h-4 w-4" />
      </span>
    </Link>
  )
}
