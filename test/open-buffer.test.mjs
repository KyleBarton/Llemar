import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, symlink, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openBufferTool, registerOpenBuffer } from '../pi-extensions/open-buffer.mjs';

// The helper only needs these schema constructors; no pi or model is invoked.
const Type = {
  String: options => ({ type: 'string', ...options }),
  Integer: options => ({ type: 'integer', ...options }),
  Optional: schema => ({ ...schema, optional: true }),
  Object: properties => ({ type: 'object', properties }),
};

test('registration is opt-in and schema constrains positions', () => {
  const tools = [];
  const pi = { registerTool: tool => tools.push(tool) };
  registerOpenBuffer(pi, Type, undefined);
  assert.equal(tools.length, 0);
  registerOpenBuffer(pi, Type, '/project');
  assert.equal(tools.length, 1);
  assert.equal(tools[0].name, 'open_buffer');
  assert.equal(tools[0].parameters.properties.line.minimum, 1);
});

test('validates files and returns requests without claiming display success', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'llemar-tool-'));
  try {
    const root = await realpath(directory);
    const file = join(root, 'file.txt');
    await writeFile(file, 'hello\n');
    await mkdir(join(root, 'sub'));
    await symlink(file, join(root, 'alias'));
    await symlink(tmpdir(), join(root, 'escape'));
    const tool = openBufferTool(Type, root);
    const execute = (params, signal) => tool.execute('id', params, signal, undefined, { cwd: join(root, 'sub') });
    const result = await execute({ path: '../alias', line: 2, column: 1 });
    assert.deepEqual(result.details, { version: 1, action: 'open_file', path: file, line: 2, column: 1 });
    assert.match(result.content[0].text, /requested display/);
    assert.match(result.content[0].text, /not confirmed/);
    assert.deepEqual((await execute({ path: file })).details,
      { version: 1, action: 'open_file', path: file });
    for (const params of [
      { path: '' }, { path: file, column: 1 }, { path: file, line: 0 },
      { path: file, line: 1.5 }, { path: file, line: 1, column: -1 },
      { path: '/ssh:host:/file' }, { path: '../missing' },
      { path: '.' }, { path: join(root, 'escape') },
    ]) await assert.rejects(execute(params));
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(execute({ path: file }, controller.signal), { name: 'AbortError' });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
