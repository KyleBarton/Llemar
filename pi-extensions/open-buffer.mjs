import { realpath, stat } from 'node:fs/promises';
import { isAbsolute, relative, resolve, sep } from 'node:path';

/** Build the companion tool independently of pi's UI/runtime. */
export function openBufferTool(Type, root) {
  return {
    name: 'open_buffer',
    label: 'Open file in Llemar',
    description: 'Request that Llemar show the user an existing project file in another window. Use when requested or clearly helpful, not for every file you inspect. Use read/search tools for reasoning. Validates the file, but does not confirm editor display.',
    parameters: Type.Object({
      path: Type.String({ minLength: 1, description: 'Local file, relative to the agent working directory or absolute.' }),
      line: Type.Optional(Type.Integer({ minimum: 1, description: '1-based line.' })),
      column: Type.Optional(Type.Integer({ minimum: 1, description: '1-based character column; requires line.' })),
    }),
    async execute(_id, params, signal, _onUpdate, ctx) {
      signal?.throwIfAborted();
      const { path, line, column } = params;
      if (typeof path !== 'string' || !path.trim() || path.includes('\0') ||
          /^\/[^/]+:/.test(path) ||
          (line !== undefined && (!Number.isSafeInteger(line) || line < 1)) ||
          (column !== undefined && (line === undefined || !Number.isSafeInteger(column) || column < 1))) {
        throw new Error('Invalid open_buffer arguments');
      }
      const canonicalRoot = await realpath(root);
      const canonicalPath = await realpath(resolve(ctx.cwd, path));
      const rel = relative(canonicalRoot, canonicalPath);
      if (!rel || isAbsolute(rel) || rel === '..' || rel.startsWith(`..${sep}`)) {
        throw new Error('Display target must be within the Llemar launch root');
      }
      if (!(await stat(canonicalPath)).isFile()) {
        throw new Error('Display target must be an existing regular file');
      }
      signal?.throwIfAborted();
      return {
        content: [{ type: 'text', text: `File validated; requested display of ${canonicalPath}${line ? ` at line ${line}` : ''}. Display is handled by Llemar and is not confirmed.` }],
        details: {
          version: 1,
          action: 'open_file',
          path: canonicalPath,
          ...(line === undefined ? {} : { line }),
          ...(column === undefined ? {} : { column }),
        },
      };
    },
  };
}

export function registerOpenBuffer(pi, Type, root) {
  // Llemar explicitly loads this extension and supplies a per-child root.
  if (root) pi.registerTool(openBufferTool(Type, root));
}
