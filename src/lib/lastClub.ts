// 마지막으로 들어간 동아리 기억 (편의 기능이라 저장 실패는 무시)
const KEY = 'badminton:lastClubId'

export function getLastClubId(): string | null {
  try {
    return localStorage.getItem(KEY)
  } catch {
    return null
  }
}

export function setLastClubId(id: string | null) {
  try {
    if (id) localStorage.setItem(KEY, id)
    else localStorage.removeItem(KEY)
  } catch {
    /* 무시 */
  }
}
