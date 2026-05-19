import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { setLocale, t } from './i18n.js'

test('settings translations include animation toggle labels', () => {
  const expected = {
    de: {
      title: 'Animationen',
      label: 'Animationen aktivieren'
    },
    en: {
      title: 'Animations',
      label: 'Enable animations'
    },
    ru: {
      title: 'Анимации',
      label: 'Включить анимации'
    }
  }

  for (const [locale, strings] of Object.entries(expected)) {
    setLocale(locale)

    assert.equal(t('settings.animationsTitle'), strings.title)
    assert.equal(t('settings.animationsLabel'), strings.label)
    assert.notEqual(t('settings.animationsHint'), 'settings.animationsHint')
  }
})

test('settings view exposes the animation preference toggle', async () => {
  const source = await readFile(new URL('./views/SettingsView.vue', import.meta.url), 'utf8')

  assert.match(source, /import \{ animationsEnabled \} from '\.\.\/composables\/useAnimations'/)
  assert.match(source, /animationsEnabled/)
  assert.match(source, /settings\.animationsTitle/)
  assert.match(source, /settings\.animationsHint/)
  assert.match(source, /settings\.animationsLabel/)
  assert.match(source, /v-model="animationsEnabled"/)
})
