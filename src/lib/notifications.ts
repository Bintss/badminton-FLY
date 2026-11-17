import { useCallback, useEffect, useState } from 'react'
import { useAuth } from '../auth/AuthProvider'
import { supabase } from './supabase'

export interface AppNotification {
  id: number
  club_id: string | null
  session_id: string | null
  kind: string
  title: string
  body: string
  url: string
  created_at: string
  read_at: string | null
}

/** 안 읽은 알림 수 (실시간). 헤더 종 표시용 */
export function useUnreadCount() {
  const { session } = useAuth()
  const uid = session?.user.id
  const [count, setCount] = useState(0)

  const load = useCallback(async () => {
    if (!uid) return
    const { count: c } = await supabase.from('notifications').select('id', { count: 'exact', head: true }).eq('user_id', uid).is('read_at', null)
    setCount(c ?? 0)
  }, [uid])

  useEffect(() => {
    if (!uid) return
    void load()
    const channel = supabase
      .channel(`notifications:${uid}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${uid}` }, () => void load())
      .subscribe()
    const onVisible = () => document.visibilityState === 'visible' && void load()
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      document.removeEventListener('visibilitychange', onVisible)
      void supabase.removeChannel(channel)
    }
  }, [uid, load])

  return count
}
