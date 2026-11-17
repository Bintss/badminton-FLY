import { useEffect, useState } from 'react'
import { supabase } from './supabase'

/**
 * 서버 시각 보정. 단말 시계가 틀려도 오픈 판정·카운트다운이 서버와 맞도록
 * server_now()를 한 번 호출해 (서버 - 단말) 차이를 구해 둔다. 왕복 시간의 절반을 보정한다.
 * 실제 신청 가능 여부는 항상 서버(register RPC)가 판정한다. 이 값은 화면 표시용.
 */
let offsetMs = 0
let syncPromise: Promise<void> | null = null

export function syncServerClock(): Promise<void> {
  if (!syncPromise) {
    syncPromise = (async () => {
      const t0 = Date.now()
      const { data, error } = await supabase.rpc('server_now')
      const t1 = Date.now()
      if (error || !data) {
        syncPromise = null // 다음에 다시 시도
        return
      }
      offsetMs = new Date(data as string).getTime() - (t0 + t1) / 2
    })()
  }
  return syncPromise
}

/** 보정된 현재 시각 (ms) */
export function serverNow(): number {
  return Date.now() + offsetMs
}

/** 보정된 현재 시각을 intervalMs마다 갱신해 돌려주는 훅 */
export function useServerNow(intervalMs = 30_000): number {
  const [now, setNow] = useState(serverNow)
  useEffect(() => {
    let alive = true
    void syncServerClock().then(() => alive && setNow(serverNow()))
    const timer = setInterval(() => setNow(serverNow()), intervalMs)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [intervalMs])
  return now
}

/**
 * 목표 시각까지 카운트다운용 훅. 남은 시간에 따라 갱신 주기를 바꾼다
 * (1시간 이상: 30초, 1분 이상: 1초, 그 안: 100ms). 목표 시각이 지나면 30초 주기.
 */
export function useCountdownNow(targetMs: number): number {
  const [now, setNow] = useState(serverNow)
  useEffect(() => {
    let alive = true
    let timer: ReturnType<typeof setTimeout>
    const tick = () => {
      if (!alive) return
      const n = serverNow()
      setNow(n)
      const left = targetMs - n
      const wait = left > 3_600_000 ? 30_000 : left > 60_000 ? 1_000 : left > 0 ? 100 : 30_000
      timer = setTimeout(tick, wait)
    }
    void syncServerClock().then(tick)
    return () => {
      alive = false
      clearTimeout(timer)
    }
  }, [targetMs])
  return now
}
