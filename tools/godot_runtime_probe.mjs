#!/usr/bin/env node
import net from 'node:net';

const args = process.argv.slice(2);
let host = '127.0.0.1';
let port = Number.parseInt(process.env.GODOT_MCP_RUNTIME_PORT || process.env.GODOT_RUNTIME_PORT || '7777', 10);
let timeoutMs = 10000;
let command = 'ping';
let params = {};

function usage() {
  console.error('Usage: godot_runtime_probe.mjs [--host HOST] [--port PORT] [--timeout MS] [command] [jsonParams]');
}

for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === '--host') {
    host = args[++i] || host;
  } else if (arg === '--port') {
    port = Number.parseInt(args[++i] || '', 10);
  } else if (arg === '--timeout') {
    timeoutMs = Number.parseInt(args[++i] || '', 10);
  } else if (arg === '--help' || arg === '-h') {
    usage();
    process.exit(0);
  } else if (command === 'ping') {
    command = arg;
  } else {
    try {
      params = JSON.parse(arg);
    } catch (error) {
      console.error(`Invalid jsonParams: ${error.message}`);
      process.exit(64);
    }
  }
}

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`Invalid port: ${port}`);
  process.exit(64);
}
if (!Number.isInteger(timeoutMs) || timeoutMs < 1) {
  console.error(`Invalid timeout: ${timeoutMs}`);
  process.exit(64);
}

let buffer = Buffer.alloc(0);
let settled = false;
const socket = net.createConnection({ host, port });

const timer = setTimeout(() => {
  finish(70, `Timed out waiting for Godot MCP runtime at ${host}:${port}`);
}, timeoutMs);

socket.on('connect', () => {
  socket.write(JSON.stringify({ command, params, id: Date.now() }) + '\n');
});

socket.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  const messages = readMessages();
  const response = messages.find((message) => message && message.type && message.type !== 'welcome');
  if (!response) {
    return;
  }
  const text = JSON.stringify(response, null, 2);
  finish(response.type === 'error' ? 2 : 0, text);
});

socket.on('error', (error) => {
  finish(69, `Failed to connect to Godot MCP runtime at ${host}:${port}: ${error.message}`);
});

socket.on('end', () => {
  if (!settled) {
    finish(70, `Connection closed before a ${command} response arrived`);
  }
});

function readMessages() {
  const messages = [];

  let offset = 0;
  while (offset + 4 <= buffer.length) {
    const frameLength = buffer.readUInt32LE(offset);
    if (frameLength <= 0 || offset + 4 + frameLength > buffer.length) {
      break;
    }
    parseMessage(buffer.subarray(offset + 4, offset + 4 + frameLength).toString('utf8'), messages);
    offset += 4 + frameLength;
  }
  if (offset > 0) {
    buffer = buffer.subarray(offset);
  }

  let newlineIndex = buffer.indexOf(0x0a);
  while (newlineIndex !== -1) {
    parseMessage(buffer.subarray(0, newlineIndex).toString('utf8'), messages);
    buffer = buffer.subarray(newlineIndex + 1);
    newlineIndex = buffer.indexOf(0x0a);
  }

  return messages;
}

function parseMessage(raw, out) {
  const text = raw.trim();
  if (!text) {
    return;
  }
  try {
    out.push(JSON.parse(text));
  } catch {
    // Keep waiting; framed TCP data can arrive in chunks.
  }
}

function finish(code, message) {
  if (settled) {
    return;
  }
  settled = true;
  clearTimeout(timer);
  socket.destroy();
  if (message) {
    const stream = code === 0 ? process.stdout : process.stderr;
    stream.write(`${message}\n`);
  }
  process.exit(code);
}
