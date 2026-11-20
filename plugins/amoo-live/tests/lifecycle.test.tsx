import { expect, test } from 'claude-code/testing'

import { COMMAND, mockUI, PANE, STARTED, bash, ran, UP, upOutput } from './fixtures'

test('rendering or reopening an ended session never starts capture and retains copyable artifacts', async ($, on) => {
  const clock = mockUI(on)
  const spawned: string[][] = []
  const copied: string[] = []
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('ui.copy', (_, e) => {
    copied.push(e.text)
    return { value: { isCopied: true } }
  })
  on('tool.call', (_, e) =>
    String(e.command).includes('env up') ? STARTED : ran('✓ 1. tap_element\nReport: /out/report.json\n'),
  )
  on('process.spawn', async function* (_, e) {
    spawned.push(e.argv as string[])
    return { value: { code: 0, signal: null } }
  })

  await $.tool.call(bash(UP))
  await $.tool.call(bash('amoo flow flows/login.amoo.json --runtime-id s-1 --output-dir /out'))
  await $.tool.call(bash('amoo env down --runtime-id s-1'))
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  await $.command.run(COMMAND)
  await clock.advance(0)

  expect(spawned).toHaveLength(0)
  expect(
    (await ui.find({ type: 'Text', text: /^(Running|Ended|Paused|Mirror failed)$/ }))?.text,
  ).toBe('Ended')
  expect((await ui.find({ type: 'Text', text: /flow login/ }))?.text).toStartWith('✓ flow login.amoo.json · ')
  expect(await ui.find({ key: 'capture' })).toBeUndefined()
  await ui.press({ key: 'copy-flow' })
  await ui.press({ key: 'copy-report' })
  expect(copied).toEqual(['flows/login.amoo.json', '/out/report.json'])
  await ui.unmount()
})

test('parallel sessions keep actions and closure scoped to the correct device', async ($, on) => {
  mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', (_, e) => {
    const command = String(e.command)
    if (command.includes('com.first')) return ran(upOutput('s-1', 'com.first', 'SIM-1'))
    if (command.includes('com.second')) return ran(upOutput('s-2', 'com.second', 'SIM-2'))
    return ran('{"ok":true}')
  })
  await $.tool.call(bash('amoo env up --app-id com.first --json'))
  await $.tool.call(bash('amoo env up --app-id com.second --json'))
  await $.tool.call(bash('amoo device --runtime-id s-1 --json tap_element label=First'))
  await $.tool.call(bash('amoo env down --runtime-id s-1 --json'))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect(await ui.find({ type: 'Text', text: /com.second/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /First/ })).toBeUndefined()
  expect(
    (await ui.find({ type: 'Text', text: /^(Running|Ended|Paused|Mirror failed)$/ }))?.text,
  ).toBe('Running')
  await ui.press({ key: 'session-s-1' })
  expect(await ui.find({ type: 'Text', text: /First/ })).toBeDefined()
  expect(
    (await ui.find({ type: 'Text', text: /^(Running|Ended|Paused|Mirror failed)$/ }))?.text,
  ).toBe('Ended')
  await ui.press({ key: 'session-s-2' })
  expect(await ui.find({ type: 'Text', text: /First/ })).toBeUndefined()
  await ui.unmount()
})

test('the manual command is registered for immediate execution during a turn', async ($, on) => {
  mockUI(on)
  const registered: unknown[] = []
  on('command.register', (_, e) => {
    registered.push(e)
    return { value: { command: e.name } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  expect(registered).toContainEqual(expect.objectContaining({ name: 'amoo-live', immediate: true }))
})

test('a failed stream stays stopped across redraws and can be retried without a new session', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => (STARTED))
  on('process.spawn', async function* () {
    spawned += 1
    yield { stream: 'stderr' as const, text: 'capture unavailable' }
    return { value: { code: null, signal: 'SIGTERM' } }
  })
  await $.tool.call(bash(UP))
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  expect(spawned).toBe(1)
  expect((await ui.find({ key: 'capture' }))?.text).toBe('Retry mirror')
  expect((await ui.find({ type: 'Text', text: /^mirror:/ }))?.text).toContain(
    'signal SIGTERM: capture unavailable',
  )
  await $.command.run(COMMAND)
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.press({ key: 'capture' })
  await clock.advance(0)
  expect(spawned).toBe(2)
  await ui.unmount()
})

test('desktop and vscode panes never start a capture they cannot display', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => (STARTED))
  on('process.spawn', async function* () {
    spawned += 1
    return { value: { code: 0, signal: null } }
  })
  await $.tool.call(bash(UP))
  for (const surface of ['desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    await clock.advance(0)
    expect(await ui.find({ text: /Live pictures need Ghostty or kitty/ })).toBeDefined()
    expect(await ui.find({ key: 'capture' })).toBeUndefined()
    await ui.unmount()
  }
  expect(spawned).toBe(0)
})

test('a failed startup remains visible and cannot leave a pending row behind', async ($, on) => {
  mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', async () => {
    const pending = await $.ui.mount({ ...PANE, surface: 'desktop' })
    expect(await pending.find({ type: 'Text', text: /^Starting com.example.app/ })).toBeDefined()
    await pending.unmount()
    return ran('{"ok":false,"error":"no device"}', true)
  })
  await $.tool.call(bash(UP))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /^Starting / })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /^Startup failed: com.example.app/ })).toBeDefined()
  await ui.unmount()
})

test('pending and denied actions retain no typed secret or error body', async ($, on) => {
  mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', async (_, e) => {
    if (String(e.command).includes('env up')) return STARTED
    const pending = await $.ui.mount({ ...PANE, surface: 'desktop' })
    expect((await pending.find({ type: 'Text', text: /type_text/ }))?.text).toStartWith(
      '… type_text (7 chars) · ',
    )
    expect(await pending.find({ text: /hunter2/ })).toBeUndefined()
    await pending.unmount()
    return { deny: 'hunter2 is secret' }
  })
  await $.tool.call(bash(UP))
  const denied = await $.tool.call(bash('amoo device --runtime-id s-1 --json type_text text=hunter2'))
  expect(denied.deny).toBe('hunter2 is secret')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /type_text/ }))?.text).toStartWith('✗ type_text (7 chars) · ')
  expect(await ui.find({ text: /hunter2/ })).toBeUndefined()
  await ui.unmount()
})

test('pane failures do not prevent session tracking or run the device tool twice', async ($, on) => {
  mockUI(on)
  let calls = 0
  on('ui.open', () => {
    throw new Error('surface unavailable')
  })
  on('tool.call', () => {
    calls += 1
    return STARTED
  })
  const result = await $.tool.call(bash(UP))
  expect(result.text).toBe(STARTED.text)
  expect(calls).toBe(1)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /com.example.app/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Starting / })).toBeUndefined()
  await ui.unmount()
})

test('a new conversation after clear can start capture after the previous shutdown', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  on('classic.SessionStart', () => ({}))
  on('tool.call', () => (STARTED))
  on('process.spawn', async function* () {
    spawned += 1
    return { value: { code: 64, signal: null } }
  })
  await $.tool.call(bash(UP))
  await $.session.end({ reason: 'clear', sessionId: 'conversation-1', resume: { id: 'conversation-1' } })
  await $.classic.SessionStart({ source: 'clear', model: 'test' })
  await $.tool.call(bash(UP))
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.unmount()
})

test('a runtime leased before the pane saw it is found through env list', async ($, on) => {
  mockUI(on)
  const spawned: string[][] = []
  on('tool.call', () => ran('{"ok":true}'))
  on('process.spawn', async function* (_, e) {
    spawned.push(e.argv as string[])
    if ((e.argv as string[]).includes('list')) {
      yield {
        stream: 'stdout' as const,
        text: '{"runtimes":[{"runtime_id":"r-9","platform":"android","device":"emulator-5554","name":"Pixel"}]}\n',
      }
    }
    return { value: { code: 0, signal: null } }
  })
  await $.tool.call(bash('amoo device --runtime-id r-9 --json tap_element id=go'))
  expect(spawned[0]).toEqual(['amoo', 'env', 'list', '--json'])
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /Pixel/ }))?.text).toBe('android · Pixel')
  expect((await ui.find({ type: 'Text', text: /tap_element/ }))?.text).toStartWith("✓ tap_element 'go' · ")
  await ui.unmount()
})
