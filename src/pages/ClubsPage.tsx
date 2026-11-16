import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthProvider'
import { Badge, Button, Card, ErrorText, Page, Spinner } from '../components/ui'
import { errorMessage, supabase } from '../lib/supabase'
import type { Club, MembershipWithClub } from '../lib/types'

export default function ClubsPage() {
  const { session, signOut } = useAuth()
  const navigate = useNavigate()
  const [memberships, setMemberships] = useState<MembershipWithClub[] | null>(null)
  const [clubs, setClubs] = useState<Club[]>([])
  const [error, setError] = useState('')
  const [busyId, setBusyId] = useState<string | null>(null)
  const [newName, setNewName] = useState('')

  const uid = session?.user.id

  const load = useCallback(async () => {
    if (!uid) return
    const [mine, all] = await Promise.all([
      supabase.from('club_members').select('*, clubs(id, name)').eq('user_id', uid).order('requested_at'),
      supabase.from('clubs').select('id, name, created_at').order('name'),
    ])
    if (mine.error || all.error) {
      setError(errorMessage(mine.error ?? all.error))
      return
    }
    setMemberships(mine.data as MembershipWithClub[])
    setClubs(all.data as Club[])
  }, [uid])

  useEffect(() => {
    void load()
  }, [load])

  const requestJoin = async (clubId: string) => {
    setBusyId(clubId)
    setError('')
    const { error } = await supabase.rpc('request_join', { p_club: clubId })
    if (error) setError(errorMessage(error))
    await load()
    setBusyId(null)
  }

  const createClub = async (e: FormEvent) => {
    e.preventDefault()
    if (!newName.trim()) return
    setBusyId('new')
    setError('')
    const { data, error } = await supabase.rpc('create_club', { p_name: newName.trim() })
    setBusyId(null)
    if (error) {
      setError(errorMessage(error))
      return
    }
    navigate(`/c/${data as string}`)
  }

  if (!memberships) return <Page title="동아리"><Spinner /><ErrorText>{error}</ErrorText></Page>

  const joinedIds = new Set(memberships.filter((m) => m.status === 'approved' || m.status === 'pending').map((m) => m.club_id))
  const others = clubs.filter((c) => !joinedIds.has(c.id))
  const visibleMine = memberships.filter((m) => m.status !== 'left')

  return (
    <Page
      title="동아리"
      action={
        <button className="text-sm text-neutral-500" onClick={() => void signOut()}>
          로그아웃
        </button>
      }
    >
      <ErrorText>{error}</ErrorText>

      <h2 className="mb-2 mt-2 text-sm font-semibold text-neutral-500">내 동아리</h2>
      {visibleMine.length === 0 && <p className="mb-4 text-sm text-neutral-500">아직 가입한 동아리가 없어요.</p>}
      <div className="space-y-2">
        {visibleMine.map((m) => (
          <Card key={m.club_id} className="flex items-center justify-between">
            <div>
              <p className="font-semibold text-neutral-900">{m.clubs?.name ?? '동아리'}</p>
              <div className="mt-1">
                {m.status === 'approved' && <Badge tone="blue">{m.role === 'admin' ? '운영진' : '회원'}</Badge>}
                {m.status === 'pending' && <Badge tone="amber">승인 대기 중</Badge>}
                {m.status === 'rejected' && <Badge>거절됨</Badge>}
              </div>
            </div>
            {m.status === 'approved' && (
              <Link to={`/c/${m.club_id}`} className="rounded-xl bg-neutral-900 px-4 py-2.5 text-sm font-semibold text-white">
                들어가기
              </Link>
            )}
            {m.status === 'pending' && (
              <Button variant="secondary" onClick={() => void load()}>
                새로고침
              </Button>
            )}
            {m.status === 'rejected' && (
              <Button variant="secondary" disabled={busyId === m.club_id} onClick={() => void requestJoin(m.club_id)}>
                다시 신청
              </Button>
            )}
          </Card>
        ))}
      </div>

      {others.length > 0 && (
        <>
          <h2 className="mb-2 mt-6 text-sm font-semibold text-neutral-500">가입 신청</h2>
          <div className="space-y-2">
            {others
              .filter((c) => !memberships.some((m) => m.club_id === c.id && m.status === 'rejected'))
              .map((c) => (
                <Card key={c.id} className="flex items-center justify-between">
                  <p className="font-semibold text-neutral-900">{c.name}</p>
                  <Button variant="secondary" disabled={busyId === c.id} onClick={() => void requestJoin(c.id)}>
                    가입 신청
                  </Button>
                </Card>
              ))}
          </div>
        </>
      )}

      <h2 className="mb-2 mt-6 text-sm font-semibold text-neutral-500">동아리 만들기</h2>
      <Card>
        <form onSubmit={createClub} className="flex gap-2">
          <input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            maxLength={50}
            placeholder="동아리 이름"
            className="h-11 min-w-0 flex-1 rounded-xl border border-neutral-200 px-3 text-[15px] outline-none focus:border-neutral-900"
          />
          <Button type="submit" disabled={busyId === 'new' || !newName.trim()}>
            만들기
          </Button>
        </form>
        <p className="mt-2 text-xs text-neutral-500">만든 사람이 첫 운영진이 돼요.</p>
      </Card>
    </Page>
  )
}
