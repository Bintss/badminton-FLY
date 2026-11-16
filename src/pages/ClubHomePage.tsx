import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useClub } from '../club/ClubLayout'
import { Badge, Card, Page } from '../components/ui'
import { supabase } from '../lib/supabase'

/** 홈: 일정 목록 (M3에서 세션 목록으로 채운다) */
export default function ClubHomePage() {
  const { club, isAdmin } = useClub()
  const [pendingCount, setPendingCount] = useState(0)

  useEffect(() => {
    if (!isAdmin) return
    supabase
      .from('club_members')
      .select('user_id', { count: 'exact', head: true })
      .eq('club_id', club.id)
      .eq('status', 'pending')
      .then(({ count }) => setPendingCount(count ?? 0))
  }, [club.id, isAdmin])

  return (
    <Page title="일정">
      <Card>
        <p className="text-sm text-neutral-500">예정된 운동이 없어요.</p>
        <p className="mt-1 text-xs text-neutral-400">정기운동 템플릿과 번개 만들기는 다음 단계(M3)에서 추가돼요.</p>
      </Card>

      <nav className="mt-6 space-y-2">
        <Link to="me" className="block">
          <Card className="flex items-center justify-between">
            <span className="font-medium text-neutral-900">내 정보</span>
            <span className="text-sm text-neutral-400">이름·급수</span>
          </Card>
        </Link>
        {isAdmin && (
          <Link to="admin/members" className="block">
            <Card className="flex items-center justify-between">
              <span className="font-medium text-neutral-900">회원 관리</span>
              {pendingCount > 0 ? <Badge tone="amber">가입 신청 {pendingCount}</Badge> : <span className="text-sm text-neutral-400">가입 승인·운영진</span>}
            </Card>
          </Link>
        )}
      </nav>
    </Page>
  )
}
