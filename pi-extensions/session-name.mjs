const REVIEW_STATE = 'llemar-session-title-review-state';
const REVIEW_INTERVAL_FLAG = 'session-title-review-interval';
const NAMING_GUIDANCE = 'Use set_session_name to give this conversation a concise, descriptive title once its theme is clear. Name the conversation’s overarching purpose, not merely its first task. Reconsider the title when the user clarifies their intent, asks what the conversation is about, or moves to a sustained new topic. Correct an inaccurate title even if the underlying theme has not changed. Avoid renaming for brief tangents or on every turn.';

/** Let the conversation's own model maintain a durable, evolving title. */
export function registerSessionName(pi, Type) {
  pi.registerFlag(REVIEW_INTERVAL_FLAG, {
    type: 'string',
    default: '5',
    description: 'User-started runs between session-title checks after the initial check on run 3 (positive integer)',
  });
  pi.on('before_agent_start', (event, ctx) => {
    const result = { systemPrompt: `${event.systemPrompt}\n\n${NAMING_GUIDANCE}` };
    if (event.messageType !== 'user') return result;

    // Read the active branch each time: resume, reload, and tree navigation
    // must not inherit counters from a different session or abandoned branch.
    const previous = ctx.sessionManager.getBranch().findLast(entry =>
      entry.type === 'custom' && entry.customType === REVIEW_STATE)?.data;
    const userRuns = (previous?.userRuns ?? 0) + 1;
    const lastReview = previous?.lastReview ?? 0;
    const configured = Number(pi.getFlag(REVIEW_INTERVAL_FLAG));
    const interval = Number.isSafeInteger(configured) && configured > 0 ? configured : 5;
    const due = lastReview === 0 ? userRuns >= 3 : userRuns - lastReview >= interval;
    pi.appendEntry(REVIEW_STATE, { userRuns, lastReview: due ? userRuns : lastReview });
    if (due) {
      const title = pi.getSessionName();
      result.message = {
        customType: 'llemar-session-title-review',
        display: false,
        content: `Session-title check: ${title ? `The current title is ${JSON.stringify(title)}.` : 'This session is not yet named.'} Consider whether the title reflects the conversation’s overarching purpose, including any clarified intent. Call set_session_name only if naming or correcting the title would be useful. Otherwise do nothing. Don’t mention this check in your reply.`,
      };
    }
    return result;
  });
  pi.registerTool({
    name: 'set_session_name',
    label: 'Name session',
    description: 'Save a concise title describing the conversation’s overarching purpose. Correct it when intent becomes clearer or the theme changes substantially.',
    parameters: Type.Object({ name: Type.String({ description: 'A short descriptive title (roughly 3–7 words)' }) }),
    async execute(_id, { name }) {
      const title = name.replace(/\s+/g, ' ').trim();
      if (!title) throw new Error('Session title must not be empty');
      pi.setSessionName(title);
      return { content: [{ type: 'text', text: `Session named: ${title}` }], details: { name: title } };
    },
  });
}
