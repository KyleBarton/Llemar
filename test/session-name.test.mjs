import { test } from 'node:test';
import assert from 'node:assert/strict';
import { registerSessionName } from '../pi-extensions/session-name.mjs';

test('agent is instructed to name sessions and can persist evolving titles', async () => {
  const tools = [];
  const handlers = {};
  let name;
  const pi = {
    registerTool: tool => tools.push(tool),
    on: (event, handler) => { handlers[event] = handler; },
    setSessionName: value => { name = value; },
  };
  const Type = { String: x => x, Object: x => x };
  registerSessionName(pi, Type);
  const prompt = handlers.before_agent_start({ systemPrompt: 'Original instructions' });
  assert.ok(prompt.systemPrompt.startsWith('Original instructions'));
  assert.match(prompt.systemPrompt, /set_session_name/);
  assert.match(prompt.systemPrompt, /theme/i);
  await tools[0].execute('id', { name: '  Session management  ' });
  assert.equal(name, 'Session management');
  await tools[0].execute('id', { name: 'Consult session previews' });
  assert.equal(name, 'Consult session previews');
  await assert.rejects(async () => tools[0].execute('id', { name: '  ' }));
});
