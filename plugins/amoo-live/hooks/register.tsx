import type { EngineInterface, Register, Timer } from 'claude-code'

import { beginAction, finishAction } from './actions'
import { closeMirror, createMirrorController, shutdownMirror, synchronizeMirror } from './mirror'
import { amooToolName, PANE, selectedSession, statusLine, readView } from './model'
import type { MirrorController } from './mirror'
import { renderPane } from './pane'

export { amooToolName, describeAction, fitImage, startedSession } from './model'

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
        : 'amoo live pane opened; it fills in once start_session runs.',
    }
  }).catch(() => ({ text: 'amoo live pane could not open.' }))

  on('ui.close', async ($, e, next) => {
    if (e.id === PANE) await closeMirror($, mirror)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const tool = amooToolName(String(e.tool))
    if (!tool) return next(e)
    const id = e.tool_use_id
    await beginAction($, tool, e, id)
    if (tool === 'start_session') {
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
      await finishAction($, tool, e, id, { result: undefined, isError: true })
      throw error
    }
    await finishAction($, tool, e, id, ran)
    $.ui.status(statusLine(selectedSession(await readView($))))
    await synchronizeMirror($, mirror)
    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: 'amoo-live' }, ($, e) => renderPane($, e, mirror, amooPath))
}
