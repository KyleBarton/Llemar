/** Companion tool for Llemar; editor actions consume ordinary RPC results. */
import { Type } from '@earendil-works/pi-ai';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { registerOpenBuffer } from './open-buffer.mjs';
import { registerSessionName } from './session-name.mjs';

export default function (pi: ExtensionAPI) {
  registerOpenBuffer(pi, Type, process.env.LLEMAR_ROOT);
  registerSessionName(pi, Type);
}
