import type { EngineInterface, ToolCallResult } from 'claude-code'

import { lastJSONObject } from './cli'
import type { AmooCall } from './cli'
import { addSession, changeSession, describeAction, sessionFromReport, text, updateView } from './model'
import type { Input } from './model'
import type { AmooLiveAction, AmooLiveSession } from '../types'

/** Discovery calls that say nothing about what the agent did to the device. */
const UNLISTED = new Set(['get_capabilities', 'get_run_telemetry', 'list_devices'])
const MAX_ACTIONS = 50
const RUNTIME_LINE = /^Runtime ID: (\S+)$/m
const REPORT_LINE = /^Report: (.+)$/m

/** Finds a runtime the agent leased before this pane saw it, through `amoo env list`. */
export type RuntimeLookup = (runtimeId: string) => Promise<AmooLiveSession | undefined>

function basename(path: string | undefined): string {
  return path?.split('/').pop() ?? 'flow'
}

function listed(call: AmooCall): { tool: string; summary: string } | undefined {
  if (call.kind === 'device' && !UNLISTED.has(call.tool)) {
    return { tool: call.tool, summary: describeAction(call.tool, call.input) }
  }
  if (call.kind === 'flow') return { tool: 'flow', summary: `flow ${basename(call.file)}` }
  return undefined
}

export async function beginCall($: EngineInterface, call: AmooCall, id: string) {
  const startedAt = Date.now()
  if (call.kind === 'up') {
    await updateView($, (state) => ({
      ...state,
      startups: [
        ...state.startups.filter((item) => item.state === 'pending'),
        { id, appId: call.appId ?? `${call.platform ?? 'ios'} device`, startedAt, state: 'pending' },
      ],
    }))
    return
  }
  const entry = listed(call)
  if (!entry || call.kind === 'down' || !call.runtimeId) return
  const action: AmooLiveAction = { id, ...entry, state: 'pending', startedAt }
  await changeSession($, call.runtimeId, (current) => {
    const actions = [...current.actions, action]
    const completed = actions.filter((item) => item.state !== 'pending').slice(-MAX_ACTIONS)
    return {
      ...current,
      actions: actions.filter((item) => item.state === 'pending' || completed.includes(item)),
    }
  })
}

/**
 * The call's outcome. A `--json` call that was not piped reports `ok` itself; otherwise the Bash
 * exit status decides, which for a pipeline is its last command's.
 */
function outcome(call: AmooCall, ran: ToolCallResult) {
  const denied = ran.deny !== undefined
  const result = denied ? undefined : (ran.result as { stdout?: unknown } | undefined)
  const stdout = typeof result?.stdout === 'string' ? result.stdout : ''
  const readable = call.kind !== 'flow' && call.json && !call.piped
  const report: Input | undefined = readable ? lastJSONObject(stdout) : undefined
  const isOk = !denied && ran.isError !== true && report?.ok !== false
  const state: AmooLiveAction['state'] = denied ? 'denied' : isOk ? 'succeeded' : 'failed'
  return { denied, isOk, state, stdout, report }
}

export async function finishCall(
  $: EngineInterface,
  call: AmooCall,
  id: string,
  ran: ToolCallResult,
  lookup: RuntimeLookup,
): Promise<void> {
  const { denied, isOk, state, stdout, report } = outcome(call, ran)
  if (call.kind === 'up') {
    const runtimeId = text(report?.runtime_id) ?? (call.piped ? undefined : RUNTIME_LINE.exec(stdout)?.[1])
    let started = isOk && report ? sessionFromReport(report, call.appId) : undefined
    if (isOk && !started && runtimeId) started = await lookup(runtimeId)
    await updateView($, (current) => {
      const startups = current.startups.flatMap((item) =>
        item.id !== id
          ? [item]
          : isOk
            ? []
            : [{ ...item, state: denied ? ('denied' as const) : ('failed' as const) }],
      )
      const next = { ...current, startups }
      return started ? addSession(next, started) : next
    })
    return
  }
  if (!call.runtimeId) return
  if (call.kind === 'down') {
    if (isOk) {
      await changeSession($, call.runtimeId, (current) => ({
        ...current,
        phase: 'ended',
        frame: null,
        mirrorState: 'idle',
      }))
    }
    return
  }
  const reportPath =
    call.kind === 'flow'
      ? ((call.piped ? undefined : REPORT_LINE.exec(stdout)?.[1]?.trim()) ??
        (call.outputDir ? `${call.outputDir.replace(/\/$/, '')}/report.json` : undefined))
      : undefined
  const updated = await changeSession($, call.runtimeId, (current) => ({
    ...current,
    actions: current.actions.map((action) =>
      action.id === id ? { ...action, state, durationMs: Math.max(0, Date.now() - action.startedAt) } : action,
    ),
    ...(call.kind === 'flow' ? { flowPath: call.file ?? current.flowPath, reportPath: reportPath ?? current.reportPath } : {}),
  }))
  const appId = updated.sessions.find((item) => item.sessionId === call.runtimeId)?.appId ?? call.runtimeId
  if (call.kind === 'device' && call.tool.startsWith('assert_') && !isOk && !denied) {
    $.ui.toast(`amoo: ${appId}: ${describeAction(call.tool, call.input)} failed`)
  } else if (call.kind === 'flow' && !isOk && !denied) {
    $.ui.toast(`amoo: ${appId}: flow ${basename(call.file)} failed`)
  }
}
