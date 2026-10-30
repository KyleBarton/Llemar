/** Let the conversation's own model maintain a durable, evolving title. */
export function registerSessionName(pi, Type) {
  pi.on('before_agent_start', event => ({
    systemPrompt: `${event.systemPrompt}\n\nUse set_session_name to give this conversation a concise, descriptive title once its theme is clear. Update the title when the theme changes substantially. Name the actual topic, not the opening request; do not rename it on every turn.`,
  }));
  pi.registerTool({
    name: 'set_session_name',
    label: 'Name session',
    description: 'Save a concise title describing the current conversation theme. Update it when the theme changes substantially.',
    parameters: Type.Object({ name: Type.String({ description: 'A short descriptive title (roughly 3–7 words)' }) }),
    async execute(_id, { name }) {
      const title = name.replace(/\s+/g, ' ').trim();
      if (!title) throw new Error('Session title must not be empty');
      pi.setSessionName(title);
      return { content: [{ type: 'text', text: `Session named: ${title}` }], details: { name: title } };
    },
  });
}
