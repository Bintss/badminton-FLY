// 로그인 전에 초대 링크로 들어온 경우: 로그인(카카오 이동)을 다녀와도 그 링크로 돌아오게 기억해 둔다
const KEY = 'badminton:pendingInvite'

export function rememberInvite(token: string) {
  try {
    localStorage.setItem(KEY, token)
  } catch {
    /* 저장 못 하면 링크를 다시 누르면 된다 */
  }
}

export function peekInvite(): string | null {
  try {
    return localStorage.getItem(KEY)
  } catch {
    return null
  }
}

export function clearInvite() {
  try {
    localStorage.removeItem(KEY)
  } catch {
    /* 무시 */
  }
}
