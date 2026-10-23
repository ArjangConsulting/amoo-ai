import type { EngineInterface, ToolCallResult } from 'claude-code'

import {
  addSession,
  changeSession,
  describeAction,
  startedSession,
  structured,
  text,
  updateView,
} from './model'
import type { Input } from './model'
import type { AmooLiveAction, AmooLiveSessionView } from '../types'

const UNLISTED = new Set([
  'session_startup_status',
  'companion_status',
  'list_sessions',
  'get_session_report',
])
const MAX_ACTIONS = 50

export async function beginAction($: EngineInterface, tool: string, input: Input, id: string) {
  const startedAt = Date.now()
  if (tool === 'start_session') {
    await updateView($, (state) => ({
      ...state,
      startups: [
        ...state.startups.filter((item) => item.state === 'pending'),
        { id, appId: text(input.app_id) ?? 'app', startedAt, state: 'pending' },
      ],
    }))
  } else if (!UNLISTED.has(tool) && text(input.session_id)) {
    const action: AmooLiveAction = {
      id,
      tool,
      summary: describeAction(tool, input),
      state: 'pending',
      startedAt,
    }
    await changeSession($, String(input.session_id), (current) => {
      const actions = [...current.actions, action]
      const completed = actions.filter((item) => item.state !== 'pending').slice(-MAX_ACTIONS)
      return {
        ...current,
        actions: actions.filter((item) => item.state === 'pending' || completed.includes(item)),
      }
    })
  }
}

export async function finishAction(
  $: EngineInterface,
  tool: string,
  input: Input,
  id: string,
  ran: ToolCallResult,
): Promise<void> {
  const denied = ran.deny !== undefined
  const isOk = !denied && ran.isError !== true
  const fields = structured(ran.result)
  const state = denied ? 'denied' : isOk ? 'succeeded' : 'failed'
  if (tool === 'start_session') {
    const started = isOk ? startedSession(ran.result, ran.text) : undefined
    await updateView($, (current) => {
      const startups = current.startups.flatMap((item) =>
        item.id !== id
          ? [item]
          : started
            ? []
            : [{ ...item, state: denied ? ('denied' as const) : ('failed' as const) }],
      )
      const next = { ...current, startups }
      return started ? addSession(next, started) : next
    })
    return
  }

  const sessionId = text(input.session_id)
  if (!sessionId) return
  const updated = await changeSession($, sessionId, (current) => ({
    ...current,
    actions: current.actions.map((action) =>
      action.id === id
        ? { ...action, state, durationMs: Math.max(0, Date.now() - action.startedAt) }
        : action,
    ),
    recordingHealth: isOk
      ? (text(fields?.recording_health) ?? current.recordingHealth)
      : current.recordingHealth,
    ...(tool === 'end_session' && isOk
      ? { phase: 'ended' as const, frame: null, mirrorState: 'idle' as const }
      : {}),
    ...(isOk ? artifacts(fields, current) : {}),
  }))
  if (tool === 'end_session' && isOk && fields?.recording_health === 'failed') {
    $.ui.toast('amoo: recording failed; the session artifacts may be incomplete')
  } else if (tool.startsWith('assert_') && !isOk && !denied) {
    const appId = updated.sessions.find((item) => item.sessionId === sessionId)?.appId ?? sessionId
    $.ui.toast(`amoo: ${appId}: ${describeAction(tool, input)} failed`)
  }
}

function artifacts(fields: Input | undefined, current: AmooLiveSessionView) {
  return {
    planPath: text(fields?.plan_path) ?? current.planPath,
    flowPath: text(fields?.flow_path) ?? current.flowPath,
    artifactError:
      text(fields?.artifact_error) ??
      (text(fields?.plan_path) || text(fields?.flow_path) ? undefined : current.artifactError),
    actionCount: typeof fields?.action_count === 'number' ? fields.action_count : current.actionCount,
    warningCount: typeof fields?.warning_count === 'number' ? fields.warning_count : current.warningCount,
  }
}
