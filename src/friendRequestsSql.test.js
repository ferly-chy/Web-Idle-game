import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const schemaPath = path.join(root, 'supabase', 'schema.sql')
const migrationsDir = path.join(root, 'supabase', 'migrations')
const schemaSql = readFileSync(schemaPath, 'utf8')
const migrationSql = readdirSync(migrationsDir)
  .filter((name) => name.includes('friend_requests'))
  .map((name) => readFileSync(path.join(migrationsDir, name), 'utf8'))
  .join('\n')
const combinedSql = `${schemaSql}\n${migrationSql}`

test('profiles schema and migration include the friend request preference', () => {
  assert.match(schemaSql, /friend_requests_enabled boolean not null default true/)
  assert.match(migrationSql, /alter table public\.profiles\s+add column if not exists friend_requests_enabled boolean not null default true/i)
  assert.match(schemaSql, /create or replace function public\.set_friend_requests_enabled/)
})

test('friend_request reopens declined relationships and blocks disabled new incoming requests', () => {
  assert.match(combinedSql, /friend requests disabled/)
  assert.match(combinedSql, /existing\.status = 'declined'/)
  assert.match(combinedSql, /requester_id = uid/)
  assert.match(combinedSql, /addressee_id = target/)
  assert.match(combinedSql, /responded_at = null/)
})
