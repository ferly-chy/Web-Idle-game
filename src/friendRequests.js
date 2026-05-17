export const FRIEND_REQUESTS_DISABLED_ERROR = 'friend requests disabled'

export function isFriendRequestsDisabledError(error) {
  const message = typeof error === 'string' ? error : error?.message
  return String(message || '').toLowerCase().includes(FRIEND_REQUESTS_DISABLED_ERROR)
}
