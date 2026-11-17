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

const CHANGED = 'fly:notifications-changed'

/** 읽음 처리처럼 이 기기에서 알림 상태를 바꿨을 때 부른다 → 종 숫자를 바로 다시 센다 */
export function notifyUnreadChanged() {
  window.dispatchEvent(new Event(CHANGED))
}

/** 홈 화면 앱 아이콘의 숫자 (지원하는 폰·브라우저만) */
function setAppBadge(count: number) {
  const nav = navigator as Navigator & { setAppBadge?: (n?: number) => Promise<void>; clearAppBadge?: () => Promise<void> }
  try {
    if (count > 0) void nav.setAppBadge?.(count)?.catch(() => {})
    else void nav.clearAppBadge?.()?.catch(() => {})
  } catch {
    /* 지원 안 함 */
  }
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
    setAppBadge(c ?? 0)
  }, [uid])

  useEffect(() => {
    if (!uid) return
    void load()
    const channel = supabase
      .channel(`notifications:${uid}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${uid}` }, () => void load())
      .subscribe()
    const onVisible = () => document.visibilityState === 'visible' && void load()
    const onChanged = () => void load()
    document.addEventListener('visibilitychange', onVisible)
    window.addEventListener(CHANGED, onChanged)
    return () => {
      document.removeEventListener('visibilitychange', onVisible)
      window.removeEventListener(CHANGED, onChanged)
      void supabase.removeChannel(channel)
    }
  }, [uid, load])

  return count
}
