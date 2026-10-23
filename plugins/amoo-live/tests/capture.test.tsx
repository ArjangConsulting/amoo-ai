import { expect, test } from 'claude-code/testing'

import { COMMAND, mockUI, PANE, STARTED_TEXT } from './fixtures'
import type { AmooLiveView } from '../types'

test('capture started after rendering applies fragmented frames outside the render dispatch', async ($, on) => {
  const clock = mockUI(on)
  const received: unknown[] = []
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('state.set', (_, e, next) => {
    const state = e.value as AmooLiveView
    const frame = state.sessions?.find((item) => item.sessionId === 's-1')?.frame
    if (frame) received.push(frame)
    return next(e)
  })
  on('process.spawn', async function* () {
    yield { stream: 'stdout' as const, text: '{"event":"fra' }
    yield {
      stream: 'stdout' as const,
      text: 'me","frame":7,"path":"/frames/device.png","width":368,"height":800,"elapsed_ms":3500}\n',
    }
    return { value: { code: 0, signal: null } }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  expect(received).toContainEqual(
    expect.objectContaining({
      path: '/frames/device.png',
      frame: 7,
      width: 368,
      height: 800,
      elapsedMs: 3500,
    }),
  )
  expect((await ui.find({ key: 'capture' }))?.text).toBe('Retry mirror')
  expect(await ui.find({ type: 'Image' })).toBeUndefined()
  await ui.unmount()
})

test('pause gates an already queued capture and resume starts it once', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('process.spawn', async function* () {
    spawned += 1
    return { value: { code: 64, signal: null } }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'capture' })
  await clock.advance(0)
  expect(spawned).toBe(0)
  expect((await ui.find({ key: 'capture' }))?.text).toBe('Resume mirror')
  expect(await ui.find({ type: 'Text', text: /^Paused$/ })).toBeDefined()
  await ui.press({ key: 'capture' })
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.unmount()
})

test('closing the pane gates queued renders until the user explicitly reopens it', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('process.spawn', async function* () {
    spawned += 1
    return { value: { code: 64, signal: null } }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'close-pane' })
  await ui.redraw()
  await clock.advance(0)
  expect(spawned).toBe(0)
  await $.command.run(COMMAND)
  await ui.redraw()
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.unmount()
})

test('a hidden pane gates capture until a visible terminal render', async ($, on) => {
  let shown = false
  const clock = mockUI(on, () => shown)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('process.spawn', async function* () {
    spawned += 1
    return { value: { code: 64, signal: null } }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  expect(spawned).toBe(0)
  shown = true
  await ui.redraw()
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.redraw()
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.unmount()
})
