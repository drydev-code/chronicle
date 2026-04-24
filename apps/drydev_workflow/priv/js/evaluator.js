/**
 * Node.js JavaScript evaluator for DryDev.Workflow.
 * Communicates via JSON lines over stdin/stdout.
 * API-compatible with Jint (.NET JS engine).
 */
const vm = require('vm');
const readline = require('readline');
const crypto = require('crypto');

const rl = readline.createInterface({ input: process.stdin });

const TIMEOUT_MS = 4000;
const MAX_STATEMENTS = 1000;

rl.on('line', (line) => {
  let request;
  try {
    request = JSON.parse(line);
  } catch (e) {
    return;
  }

  try {
    if (request.type === 'script') {
      handleScript(request);
    } else if (request.type === 'expressions') {
      handleExpressions(request);
    }
  } catch (e) {
    respond({ id: request.id, ok: false, error: e.message, type: e instanceof SyntaxError ? 'syntax' : 'runtime' });
  }
});

function handleScript(request) {
  const inputs = request.inputs || {};
  const outputs = {};
  let statementCount = 0;

  const sandbox = {
    GetOrDefault: (name, defaultValue) => {
      if (name in inputs) return inputs[name];
      return defaultValue !== undefined ? defaultValue : null;
    },
    Set: (name, value) => { outputs[name] = value; },
    Keep: (name) => { if (name in inputs) outputs[name] = inputs[name]; },
    KeepAll: () => { Object.assign(outputs, inputs); },
    KeepAllExcept: (names) => {
      const exclude = Array.isArray(names) ? names : [names];
      for (const [k, v] of Object.entries(inputs)) {
        if (!exclude.includes(k)) outputs[k] = v;
      }
    },
    debug: () => {},
    sleep: (ms) => {
      const end = Date.now() + Math.min(ms, 4000);
      while (Date.now() < end) { /* blocking sleep */ }
    },
    Guid: {
      NewGuid: () => crypto.randomUUID(),
      Empty: '00000000-0000-0000-0000-000000000000'
    },
    console: { log: () => {}, warn: () => {}, error: () => {} },
    JSON: JSON,
    Math: Math,
    Date: Date,
    parseInt: parseInt,
    parseFloat: parseFloat,
    isNaN: isNaN,
    isFinite: isFinite,
    String: String,
    Number: Number,
    Boolean: Boolean,
    Array: Array,
    Object: Object,
    RegExp: RegExp,
    Error: Error
  };

  // Expose inputs as 'input' object for Jint compatibility
  sandbox.input = inputs;

  const context = vm.createContext(sandbox);

  // Wrap in function to allow top-level 'return' statements (Jint compatibility)
  let scriptSource = request.script;
  const wrappedSource = `(function() { ${scriptSource} })()`;

  let result;
  try {
    const script = new vm.Script(wrappedSource);
    result = script.runInContext(context, { timeout: TIMEOUT_MS });
  } catch (wrapErr) {
    // Fallback: try without wrapping (for scripts that don't use return)
    const script = new vm.Script(scriptSource);
    result = script.runInContext(context, { timeout: TIMEOUT_MS });
  }

  // If the script returned a value (from 'return {...}'), merge it into outputs
  if (result && typeof result === 'object' && !Array.isArray(result)) {
    Object.assign(outputs, result);
  }

  respond({ id: request.id, ok: true, outputs });
}

function handleExpressions(request) {
  const inputs = request.inputs || {};
  const results = [];

  const sandbox = {
    GetOrDefault: (name, defaultValue) => {
      if (name in inputs) return inputs[name];
      return defaultValue !== undefined ? defaultValue : null;
    },
    input: inputs,
    console: { log: () => {} },
    JSON: JSON,
    Math: Math,
    parseInt: parseInt,
    parseFloat: parseFloat,
    isNaN: isNaN,
    String: String,
    Number: Number,
    Boolean: Boolean
  };

  // Spread token parameters as top-level variables for expression evaluation
  for (const [key, value] of Object.entries(inputs)) {
    if (!(key in sandbox)) {
      sandbox[key] = value;
    }
  }

  const context = vm.createContext(sandbox);

  for (const item of request.expressions) {
    try {
      const script = new vm.Script(item.expr);
      const result = script.runInContext(context, { timeout: TIMEOUT_MS });
      results.push({ node_id: item.node_id, result: !!result });
    } catch (e) {
      results.push({ node_id: item.node_id, result: false });
    }
  }

  respond({ id: request.id, ok: true, results });
}

function respond(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

process.on('uncaughtException', (err) => {
  process.stderr.write(`Uncaught: ${err.message}\n`);
});
