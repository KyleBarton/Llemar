import { test } from 'node:test';
import assert from 'node:assert/strict';
import { registerSessionName } from '../pi-extensions/session-name.mjs';

function harness(branch = [], interval = '5') {
  const tools = [];
  const handlers = {};
  const flags = {};
  let name;
  const pi = {
    registerTool: tool => tools.push(tool),
    on: (event, handler) => { handlers[event] = handler; },
    registerFlag: (key, options) => { flags[key] = options; },
    getFlag: () => interval,
    appendEntry: (customType, data) => branch.push({ type: 'custom', customType, data }),
    getSessionName: () => name,
    setSessionName: value => { name = value; },
  };
  const ctx = { sessionManager: { getBranch: () => branch } };
  registerSessionName(pi, { String: x => x, Object: x => x });
  return {
    tools, flags, branch, pi,
    run: (messageType = 'user') => handlers.before_agent_start({
      messageType, systemPrompt: 'Original instructions',
    }, ctx),
  };
}

test('agent is instructed to name sessions and can persist evolving titles', async () => {
  const h = harness();
  const prompt = h.run();
  assert.ok(prompt.systemPrompt.startsWith('Original instructions'));
  assert.match(prompt.systemPrompt, /set_session_name/);
  assert.match(prompt.systemPrompt, /overarching purpose/);
  assert.match(prompt.systemPrompt, /clarifies/);
  await h.tools[0].execute('id', { name: '  Session management  ' });
  assert.equal(h.pi.getSessionName(), 'Session management');
  await h.tools[0].execute('id', { name: 'Consult session previews' });
  assert.equal(h.pi.getSessionName(), 'Consult session previews');
  await assert.rejects(async () => h.tools[0].execute('id', { name: '  ' }));
});

test('hidden reminders arrive on user requests 3, 8, and 13, even without renaming', () => {
  const h = harness();
  h.pi.setSessionName('A Brief Pirate Story');
  const reviewed = [];
  for (let turn = 1; turn <= 14; turn++) {
    const result = h.run();
    if (!result.message) continue;
    reviewed.push(turn);
    assert.equal(result.message.customType, 'llemar-session-title-review');
    assert.equal(result.message.display, false);
    assert.match(result.message.content, /A Brief Pirate Story/);
    assert.match(result.message.content, /Otherwise do nothing/);
    assert.match(result.message.content, /Don’t mention/);
  }
  assert.deepEqual(reviewed, [3, 8, 13]);
});

test('custom-message runs do not advance the review schedule', () => {
  const h = harness();
  h.run();
  for (let i = 0; i < 10; i++) assert.equal(h.run('custom').message, undefined);
  assert.equal(h.branch.length, 1);
  assert.equal(h.run().message, undefined);
  assert.ok(h.run().message);
});

test('review schedule survives extension reload, resume, and active-branch changes', () => {
  const original = harness();
  original.run();
  original.run();
  const fork = structuredClone(original.branch);
  const resumed = harness(original.branch);
  assert.ok(resumed.run().message);
  for (let i = 0; i < 4; i++) assert.equal(resumed.run().message, undefined);
  assert.ok(harness(original.branch).run().message);
  // Moving the active branch back must not inherit the other branch's counter.
  original.branch.splice(0, original.branch.length, ...fork);
  assert.ok(original.run().message);
});

test('reminders include the latest title, or indicate an unnamed session', () => {
  const h = harness();
  h.run();
  h.run();
  assert.match(h.run().message.content, /not yet named/i);
  h.pi.setSessionName('Session Naming Behavior');
  for (let i = 0; i < 4; i++) h.run();
  assert.match(h.run().message.content, /Session Naming Behavior/);
});

test('review interval is configurable, with safe defaults for invalid values', () => {
  const h = harness([], '2');
  assert.equal(h.flags['session-title-review-interval'].default, '5');
  const reviewed = [];
  for (let turn = 1; turn <= 7; turn++) if (h.run().message) reviewed.push(turn);
  assert.deepEqual(reviewed, [3, 5, 7]);
  for (const invalid of ['0', '-1', '1.5', 'garbage']) {
    const fallback = harness([], invalid);
    const turns = [];
    for (let turn = 1; turn <= 8; turn++) if (fallback.run().message) turns.push(turn);
    assert.deepEqual(turns, [3, 8]);
  }
});
