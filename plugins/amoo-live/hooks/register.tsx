import type { EngineInterface, Register, Timer } from 'claude-code'

import { beginCall, finishCall } from './actions'
import type { RuntimeLookup } from './actions'
import { amooCalls, lastJSONObject } from './cli'
import { closeMirror, createMirrorController, shutdownMirror, synchronizeMirror } from './mirror'
import { addSession, PANE, selectedSession, sessionFromReport, statusLine, readView, updateView } from './model'
import type { Input } from './model'
import type { MirrorController } from './mirror'
import { renderPane } from './pane'

export { amooCalls, lastJSONObject } from './cli'
export { describeAction, fitImage, sessionFromReport } from './model'

/** Reads one runtime from `amoo env list --json`; undefined when it is not listed or amoo fails. */
function runtimeLookup($: EngineInterface, amooPath: string): RuntimeLookup {
  return async (runtimeId) => {
    try {
      const child = $.process.spawn({ argv: [amooPath, 'env', 'list', '--json'] })
      let stdout = ''
      for (;;) {
        const step = await child.next()
        if (step.done) break
        if (step.value.stream === 'stdout') stdout += step.value.text
      }
      const runtimes = lastJSONObject(stdout)?.runtimes
      const entry = Array.isArray(runtimes)
        ? runtimes.find((item: unknown) => (item as Input | null)?.runtime_id === runtimeId)
        : undefined
      return entry ? sessionFromReport(entry as Input) : undefined
    } catch {
      return undefined
    }
  }
}

function startTicker($: EngineInterface, mirror: MirrorController): Timer {
  return $.clock.every(1000, async () => {
    const state = await readView($)
    if (!state.sessions.length && !state.startups.length) return
    await synchronizeMirror($, mirror)
    $.ui.status(statusLine(selectedSession(await readView($))))
    $.ui.invalidate('ui.render')
  })
}

export const register: Register = (on, options) => {
  const amooPath =
    typeof options.amooPath === 'string' && options.amooPath.length > 0 ? options.amooPath : 'amoo'
  const requestedFps = typeof options.fps === 'number' && Number.isFinite(options.fps) ? options.fps : 6
  const fps = String(Math.min(30, Math.max(0.1, requestedFps)))
  const mirror = createMirrorController(amooPath, fps)
  let ticker: Timer | undefined
  let hinted = false

  on('session.start', async ($, e, next) => {
    mirror.shuttingDown = false
    mirror.paneOpen = (await $.ui.panes()).some((pane) => pane.id === PANE)
    await $.command.register({
      name: PANE,
      description: 'Show the device amoo drives in a live pane',
      immediate: true,
    })
    ticker?.cancel()
    ticker = startTicker($, mirror)
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    ticker?.cancel()
    await shutdownMirror($, mirror)
    return next(e)
  })

  on('classic.SessionStart', { source: ['clear', 'resume', 'fork'] }, async ($, e, next) => {
    await closeMirror($, mirror)
    mirror.shuttingDown = false
    hinted = false
    ticker?.cancel()
    ticker = startTicker($, mirror)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'amoo-live' }, async ($) => {
    mirror.paneOpen = true
    await $.ui.open({ id: PANE, title: 'amoo live' })
    await synchronizeMirror($, mirror)
    const current = selectedSession(await readView($))
    return {
      text: current
        ? 'amoo live pane opened.'
        : 'amoo live pane opened; it fills in once the agent runs `amoo env up`.',
    }
  }).catch(() => ({ text: 'amoo live pane could not open.' }))

  on('ui.close', async ($, e, next) => {
    if (e.id === PANE) await closeMirror($, mirror)
    return next(e)
  }).catch(($, e, next) => next(e))

  // The agent drives amoo through Bash: `amoo env up`, `amoo device --runtime-id <id> <tool>`,
  // `amoo flow`, `amoo env down`. A background run reports nothing to follow.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const calls = e.run_in_background ? [] : amooCalls(String(e.command ?? ''))
    if (!calls.length) return next(e)
    const lookup = runtimeLookup($, amooPath)
    const known = new Set((await readView($)).sessions.map((item) => item.sessionId))
    for (const call of calls) {
      if (call.kind === 'up' || !call.runtimeId || known.has(call.runtimeId)) continue
      known.add(call.runtimeId)
      const found = await lookup(call.runtimeId)
      if (found) await updateView($, (state) => addSession(state, found, false))
    }
    const ids = calls.map((_, index) => `${e.tool_use_id}#${index}`)
    for (const [index, call] of calls.entries()) await beginCall($, call, ids[index]!)
    if (calls.some((call) => call.kind === 'up')) {
      mirror.paneOpen = true
      try {
        const opened = await $.ui.open({ id: PANE, title: 'amoo live' })
        if (!opened.isPlaced && !hinted) {
          hinted = true
          $.ui.log(`amoo-live: pane not placed: ${opened.reason}`, { to: 'debug' })
          $.ui.toast('amoo live: pane hidden. Run /amoo-live to show it while the agent works.')
        }
      } catch {
        mirror.paneOpen = false
        $.ui.log('amoo-live: could not open the pane', { to: 'debug' })
      }
    }
    let ran
    try {
      ran = await next(e)
    } catch (error) {
      for (const [index, call] of calls.entries()) {
        await finishCall($, call, ids[index]!, { result: undefined, isError: true }, lookup)
      }
      throw error
    }
    for (const [index, call] of calls.entries()) await finishCall($, call, ids[index]!, ran, lookup)
    $.ui.status(statusLine(selectedSession(await readView($))))
    await synchronizeMirror($, mirror)
    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: 'amoo-live' }, ($, e) => renderPane($, e, mirror, amooPath))
}
