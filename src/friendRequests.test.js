import test from 'node:test'
import assert from 'node:assert/strict'
import { isFriendRequestsDisabledError } from './friendRequests.js'

test('detects the stable disabled friend requests database error', () => {
  assert.equal(isFriendRequestsDisabledError('friend requests disabled'), true)
  assert.equal(isFriendRequestsDisabledError(new Error('friend requests disabled')), true)
  assert.equal(isFriendRequestsDisabledError({ message: 'friend requests disabled' }), true)
})

test('ignores unrelated friend request errors', () => {
  assert.equal(isFriendRequestsDisabledError('user not found'), false)
  assert.equal(isFriendRequestsDisabledError(new Error('already responded')), false)
  assert.equal(isFriendRequestsDisabledError(null), false)
})
