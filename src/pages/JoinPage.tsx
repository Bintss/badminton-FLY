import { useEffect, useState } from 'react'
import { Link, Navigate, useNavigate, useParams } from 'react-router-dom'
import { ClubLogo } from '../components/ClubLogo'
import { useToast } from '../components/toast'
import { Button, Card, Empty, ListSkeleton, Page } from '../components/ui'
import { setLastClubId } from '../lib/lastClub'
import { errorMessage, supabase } from '../lib/supabase'

interface InviteInfo {
  club_id: string
  name: string
  logo_path: string | null
  my_status: string | null
  banned: boolean
}

/** 초대 링크(/join/:token): 동아리 확인 → 가입하기 한 번이면 승인 없이 회원 */
export default function JoinPage() {
  const { token = '' } = useParams()
  const navigate = useNavigate()
  const toast = useToast()
  const [info, setInfo] = useState<InviteInfo | null | undefined>(undefined)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let alive = true
    void supabase.rpc('invite_info', { p_token: token }).then(({ data, error }) => {
      if (!alive) return
      if (error) toast.error(errorMessage(error))
      setInfo(((data as InviteInfo[] | null) ?? [])[0] ?? null)
    })
    return () => {
      alive = false
    }
  }, [token, toast])

  if (info === undefined)
    return (
      <Page title="동아리 초대">
        <ListSkeleton rows={1} />
      </Page>
    )

  // 이미 회원이면 바로 그 동아리로
  if (info && info.my_status === 'approved') return <Navigate to={`/c/${info.club_id}`} replace />

  const join = async () => {
    if (!info) return
    setBusy(true)
    const { error } = await supabase.rpc('join_by_invite', { p_token: token })
    setBusy(false)
    if (error) return toast.error(errorMessage(error))
    setLastClubId(info.club_id)
    toast.success(`${info.name}에 가입했어요`)
    navigate(`/c/${info.club_id}`, { replace: true })
  }

  const toClubs = (
    <Link to="/clubs" className="mt-4 block text-center text-sm font-medium text-ink-soft underline underline-offset-2">
      동아리 목록으로
    </Link>
  )

  if (!info)
    return (
      <Page title="동아리 초대">
        <Empty title="쓸 수 없는 링크예요">링크가 바뀌었거나 꺼졌어요. 운영진에게 새 링크를 받아 주세요.</Empty>
        {toClubs}
      </Page>
    )

  return (
    <Page title="동아리 초대">
      <Card className="flex flex-col items-center py-8 text-center">
        <ClubLogo club={info} size={72} />
        <p className="mt-4 text-[20px] font-bold text-ink">{info.name}</p>
        {info.banned ? (
          <p className="mt-2 text-sm text-ink-soft">이 동아리에는 가입할 수 없어요.</p>
        ) : (
          <>
            <p className="mt-2 text-sm text-ink-soft">초대 링크로 들어왔어요. 가입하면 바로 운동 투표에 참여할 수 있어요.</p>
            <Button className="mt-6 h-14 w-full text-[17px]" disabled={busy} onClick={() => void join()}>
              {busy ? '가입하는 중' : '가입하기'}
            </Button>
          </>
        )}
      </Card>
      {toClubs}
    </Page>
  )
}
