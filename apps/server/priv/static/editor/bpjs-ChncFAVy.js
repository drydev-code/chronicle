const U = {
  blankStartEvent: "BlankStartEvent",
  messageStartEvent: "MessageStartEvent",
  signalStartEvent: "SignalStartEvent",
  timerStartEvent: "TimerStartEvent",
  conditionalStartEvent: "ConditionalStartEvent",
  blankEndEvent: "BlankEndEvent",
  errorEndEvent: "ErrorEndEvent",
  messageEndEvent: "MessageEndEvent",
  signalEndEvent: "SignalEndEvent",
  escalationEndEvent: "EscalationEndEvent",
  terminationEndEvent: "TerminateEndEvent",
  compensationEndEvent: "CompensationEndEvent",
  scriptTask: "ScriptTask",
  externalTask: "ServiceTaskREST",
  userTask: "UserTask",
  rulesTask: "ServiceTaskRules",
  callActivity: "CallActivity",
  manualTask: "ManualTask",
  sendTask: "SendTask",
  receiveTask: "ReceiveTask",
  parallelGateway: "ParallelGateway",
  exclusiveGateway: "XorGateway",
  inclusiveGateway: "InclusiveGateway",
  eventBasedGateway: "EventBasedGateway",
  intermediateTimerEvent: "IntermediateCatchTimerEvent",
  intermediateCatchTimerEvent: "IntermediateCatchTimerEvent",
  intermediateCatchMessageEvent: "IntermediateCatchMessageEvent",
  intermediateCatchSignalEvent: "IntermediateCatchSignalEvent",
  intermediateCatchConditionalEvent: "IntermediateCatchConditionalEvent",
  intermediateCatchLinkEvent: "IntermediateCatchLinkEvent",
  intermediateThrowMessageEvent: "IntermediateThrowMessageEvent",
  intermediateThrowSignalEvent: "IntermediateThrowSignalEvent",
  intermediateThrowErrorEvent: "IntermediateThrowErrorEvent",
  intermediateThrowEscalationEvent: "IntermediateThrowEscalationEvent",
  intermediateThrowLinkEvent: "IntermediateThrowLinkEvent",
  intermediateThrowCompensationEvent: "IntermediateThrowCompensationEvent",
  timerBoundaryEvent: "TimerBoundaryEvent",
  messageBoundaryEvent: "MessageBoundaryEvent",
  signalBoundaryEvent: "SignalBoundaryEvent",
  conditionalBoundaryEvent: "ConditionalBoundaryEvent",
  compensationBoundaryEvent: "CompensationBoundaryEvent",
  errorBoundaryEvent: "ErrorBoundaryEvent",
  escalationBoundaryEvent: "EscalationBoundaryEvent",
  nonInterruptingTimerBoundaryEvent: "NonInterruptingTimerBoundaryEvent",
  nonInterruptingMessageBoundaryEvent: "NonInterruptingMessageBoundaryEvent",
  nonInterruptingSignalBoundaryEvent: "NonInterruptingSignalBoundaryEvent",
  nonInterruptingConditionalBoundaryEvent: "NonInterruptingConditionalBoundaryEvent"
}, J = Object.fromEntries(
  Object.entries(U).map(([e, t]) => [t, e])
);
Object.assign(J, {
  FormStartEvent: "blankStartEvent",
  TerminateEndEvent: "terminationEndEvent",
  ServiceTaskREST: "externalTask",
  ServiceTaskLLM: "externalTask",
  ServiceTaskEmail: "externalTask",
  ServiceTaskSMS: "externalTask",
  ServiceTaskDB: "externalTask",
  ServiceTaskMCP: "externalTask",
  ServiceTaskRules: "rulesTask",
  SubProcess: "SubProcess"
});
const Z = {
  ServiceTaskREST: "rest",
  ServiceTaskLLM: "ai",
  ServiceTaskEmail: "email",
  ServiceTaskSMS: "sms",
  ServiceTaskDB: "database",
  ServiceTaskMCP: "mcp"
}, F = 56, K = 72, X = 180, Y = 72;
function Q(e) {
  return e && e.charAt(0).toLowerCase() + e.slice(1);
}
function u(e) {
  return Array.isArray(e) ? e.map(u) : !e || typeof e != "object" ? e : Object.fromEntries(Object.entries(e).map(([t, r]) => [Q(t), u(r)]));
}
function p(e) {
  return Object.fromEntries(
    Object.entries(e).filter(([, t]) => t != null && t !== "" && !(Array.isArray(t) && t.length === 0))
  );
}
function c(e) {
  return Array.isArray(e) ? e : [];
}
function ee(e) {
  return e.label || e.name || e.key || String(e.id);
}
function te(e) {
  return { x: 120 + e % 8 * 220, y: 120 + Math.floor(e / 8) * 140 };
}
function re(e) {
  return e.endsWith("Gateway") ? { width: K, height: K } : e.endsWith("Event") ? { width: F, height: F } : { width: X, height: Y };
}
function ne(e) {
  return typeof e == "string" ? e : (e == null ? void 0 : e.name) || (e == null ? void 0 : e.staticText);
}
function ie(e) {
  return typeof e == "string" ? e : e != null && e.durationMs ? `PT${Math.max(1, Math.round(Number(e.durationMs) / 1e3))}S` : (e == null ? void 0 : e.cronExpression) || (e == null ? void 0 : e.period);
}
function se(e) {
  var r;
  switch ((r = e.properties) == null ? void 0 : r.topic) {
    case "ai":
    case "llm":
      return "ServiceTaskLLM";
    case "email":
    case "mail":
      return "ServiceTaskEmail";
    case "sms":
      return "ServiceTaskSMS";
    case "database":
    case "db":
    case "sql":
      return "ServiceTaskDB";
    case "mcp":
      return "ServiceTaskMCP";
    default:
      return "ServiceTaskREST";
  }
}
function oe(e) {
  const t = e.type;
  return t === "externalTask" ? se(e) : U[t] || t;
}
function ae(e, t, r) {
  var a, m, y, E, d, v, T, g, f, S, b, h, k, N, x, I, w, P, B, j, C, M, A, _, O, D, V, L, H, R, q, G, $;
  const i = oe(e), n = e.activity ?? e.attachedTo, s = z(e), o = p({
    label: ee(e),
    description: e.description,
    isMerging: e.isMerging,
    script: e.script,
    resultVariable: e.resultVariable || ((a = e.properties) == null ? void 0 : a.resultVariable),
    outputVariable: (m = e.properties) == null ? void 0 : m.outputVariable,
    dmnName: e.dmnName,
    returnVariable: e.returnVariable,
    processName: typeof e.processName == "string" ? e.processName : (y = e.processName) == null ? void 0 : y.name,
    keepBusinessKey: e.keepBusinessKey,
    asAsyncCall: e.asAsyncCall,
    sequentialLoop: e.sequentialLoop,
    collectionName: e.collectionName,
    elementName: e.elementName,
    messageName: ne(e.message),
    signalName: e.signal,
    timerDefinition: ie(e.timer),
    condition: e.condition || ((E = e.properties) == null ? void 0 : E.condition),
    linkName: e.linkName || e.name,
    errorMessage: e.errorMessage || e.message,
    errorPayload: e.errorObject || e.error,
    escalationName: e.escalation,
    exceptionType: e.exceptionType,
    actorType: ((d = e.properties) == null ? void 0 : d.actorType) || r.get(String(e.id)),
    conditions: s,
    endpoint: (v = e.properties) == null ? void 0 : v.endpoint,
    method: (T = e.properties) == null ? void 0 : T.method,
    retries: (g = e.properties) == null ? void 0 : g.retries,
    connectionId: ((f = e.properties) == null ? void 0 : f.connectorId) || ((b = (S = e.properties) == null ? void 0 : S.extensions) == null ? void 0 : b.connectionId),
    queryType: (k = (h = e.properties) == null ? void 0 : h.extensions) == null ? void 0 : k.queryType,
    query: (x = (N = e.properties) == null ? void 0 : N.extensions) == null ? void 0 : x.query,
    parameters: (w = (I = e.properties) == null ? void 0 : I.extensions) == null ? void 0 : w.params,
    model: (B = (P = e.properties) == null ? void 0 : P.extensions) == null ? void 0 : B.model,
    systemPrompt: (C = (j = e.properties) == null ? void 0 : j.extensions) == null ? void 0 : C.systemPrompt,
    userPrompt: (A = (M = e.properties) == null ? void 0 : M.extensions) == null ? void 0 : A.prompt,
    fromEmail: (O = (_ = e.properties) == null ? void 0 : _.extensions) == null ? void 0 : O.fromEmail,
    to: (V = (D = e.properties) == null ? void 0 : D.extensions) == null ? void 0 : V.to,
    subject: (H = (L = e.properties) == null ? void 0 : L.extensions) == null ? void 0 : H.subject,
    body: (q = (R = e.properties) == null ? void 0 : R.extensions) == null ? void 0 : q.body,
    isHtml: ($ = (G = e.properties) == null ? void 0 : G.extensions) == null ? void 0 : $.isHtml,
    cancelActivity: !String(e.type).startsWith("nonInterrupting"),
    properties: e.properties,
    __bpjs: e
  });
  return {
    id: String(e.id),
    type: i,
    position: e.position || te(t),
    parentNode: n != null ? String(n) : void 0,
    extent: n != null ? "parent" : void 0,
    data: o,
    ...re(i)
  };
}
function z(e) {
  const t = e.expressions && typeof e.expressions == "object" ? e.expressions : {}, r = Object.entries(t).map(([i, n], s) => ({
    path: s,
    target: l(i),
    expression: String(n),
    label: i
  }));
  return e.defaultPath !== void 0 && e.defaultPath !== null && r.push({
    path: r.length,
    target: e.defaultPath,
    expression: "",
    label: "default"
  }), r.length > 0 ? r : void 0;
}
function ce(e, t, r) {
  const i = r.get(String(e.from)), n = pe(i, e.to);
  return {
    id: String(e.id || `e_${e.from}_${e.to}_${t}`),
    source: String(e.from),
    target: String(e.to),
    sourceHandle: e.sourceHandle ?? n,
    targetHandle: e.targetHandle,
    data: p({
      isRecursive: e.isRecursive,
      isDefault: e.isDefault,
      __bpjs: e
    })
  };
}
function pe(e, t) {
  if (!e) return;
  const r = z(e), i = r == null ? void 0 : r.find((n) => String(n.target) === String(t));
  return i ? String(i.path) : void 0;
}
function me(e, t) {
  const r = c(e.nodes), i = le(c(e.lanes)), n = new Map(r.map((a) => [String(a.id), a])), s = r.map((a, m) => ae(a, m, i)), o = ue(c(e.lanes));
  return {
    id: String(e.id || `process_${t + 1}`),
    name: e.name || `Process ${t + 1}`,
    description: e.description,
    isSubProcess: e.isSubProcess,
    nodes: s,
    edges: c(e.connections).map((a, m) => ce(a, m, n)),
    swimlanes: o
  };
}
function le(e) {
  const t = /* @__PURE__ */ new Map();
  for (const r of e) {
    const i = r.actorType || r.name || r.key;
    if (i)
      for (const n of c(r.nodes || r.nodeIds || r.flowNodeRefs || r.flowNodes)) {
        let s = n;
        if (n && typeof n == "object") {
          const o = n;
          s = o.id || o.nodeId || o.flowNodeRef;
        }
        s != null && t.set(String(s), i);
      }
  }
  return t;
}
function ue(e) {
  return e.map((t, r) => ({
    id: String(t.id || t.key || t.name || `lane_${r + 1}`),
    name: t.actorType || t.name || t.key || `Lane ${r + 1}`,
    x: t.x ?? 40,
    y: t.y ?? 60 + r * 160,
    width: t.width ?? 1600,
    height: t.height ?? 140,
    color: t.color
  }));
}
function ye(e) {
  if (!(!e.messageName && !e.messagePayload && !e.messagePayloadVariableName))
    return p({
      name: e.messageName,
      staticText: e.messageName,
      payloadVariableName: e.messagePayloadVariableName,
      variableName: e.messageVariableName,
      variableContent: e.messagePayload
    });
}
function Ee(e) {
  const t = e.timerDefinition || e.timerDate;
  if (t)
    return typeof t == "string" && /^PT\d+S$/i.test(t) ? { durationMs: Number(t.replace(/^PT/i, "").replace(/S$/i, "")) * 1e3 } : e.timerType === "date" ? { date: e.timerDate } : { period: t };
}
function de(e, t) {
  var n, s;
  const r = Z[e] || ((n = t.properties) == null ? void 0 : n.topic), i = p({
    ...t.properties,
    actorType: t.actorType,
    resultVariable: t.resultVariable || t.outputVariable,
    topic: r,
    connectorId: t.connectorId || t.connectionId,
    endpoint: t.endpoint,
    method: t.method,
    retries: t.retries,
    execution: t.execution,
    extensions: p({
      ...((s = t.properties) == null ? void 0 : s.extensions) || {},
      headers: t.headers,
      requestBody: t.requestBody,
      bearerToken: t.bearerToken,
      apiKey: t.apiKey,
      connectionId: t.connectionId,
      queryType: t.queryType,
      query: t.query,
      params: t.parameters,
      model: t.model,
      prompt: t.userPrompt,
      systemPrompt: t.systemPrompt,
      fromEmail: t.fromEmail,
      to: t.to,
      cc: t.cc,
      bcc: t.bcc,
      subject: t.subject,
      body: t.body,
      isHtml: t.isHtml,
      attachments: t.attachments,
      mcpServerUrl: t.mcpServerUrl,
      mcpServerName: t.mcpServerName,
      mcpOperation: t.mcpOperation,
      mcpToolName: t.mcpToolName,
      mcpToolArguments: t.mcpToolArguments,
      mcpResourceUri: t.mcpResourceUri,
      mcpPromptName: t.mcpPromptName,
      mcpPromptArguments: t.mcpPromptArguments
    })
  });
  return Object.keys(i.extensions || {}).length === 0 && delete i.extensions, i;
}
function ve(e) {
  var s, o;
  const t = e.data || {}, r = t.__bpjs || {}, i = ((s = t.__bpjs) == null ? void 0 : s.type) || J[e.type || ""] || e.type || "externalTask", n = p({
    ...r,
    id: l(e.id),
    key: t.key || ((o = t.__bpjs) == null ? void 0 : o.key) || e.id,
    type: i,
    label: t.label,
    description: t.description,
    position: e.position,
    properties: de(e.type || "", t),
    script: t.script,
    resultVariable: t.resultVariable || t.outputVariable,
    dmnName: t.dmnName || t.decisionFile,
    returnVariable: t.returnVariable || t.resultVariable,
    processName: t.processName ? { name: t.processName } : void 0,
    keepBusinessKey: t.keepBusinessKey,
    asAsyncCall: t.asAsyncCall,
    sequentialLoop: t.sequentialLoop,
    collectionName: t.collectionName,
    elementName: t.elementName,
    message: ye(t),
    signal: t.signalName,
    timer: Ee(t),
    condition: t.condition,
    linkName: t.linkName,
    errorMessage: t.errorMessage || t.exceptionType,
    errorObject: t.errorPayload,
    escalation: t.escalationName,
    isMerging: t.isMerging,
    expressions: Te(t),
    defaultPath: ge(t),
    activity: e.parentNode ? l(e.parentNode) : void 0
  });
  return Object.keys(n.properties || {}).length === 0 && delete n.properties, n;
}
function Te(e) {
  const t = c(e.conditions);
  if (t.length !== 0)
    return Object.fromEntries(
      t.filter((r) => r.expression && r.target).map((r) => [String(r.target), r.expression])
    );
}
function ge(e) {
  var t;
  return (t = c(e.conditions).find((r) => !r.expression)) == null ? void 0 : t.target;
}
function l(e) {
  return /^-?\d+$/.test(e) ? Number(e) : e;
}
function fe(e) {
  var r;
  const t = ((r = e.data) == null ? void 0 : r.__bpjs) || {};
  return p({
    ...t,
    id: e.id,
    from: l(e.source),
    to: l(e.target),
    sourceHandle: e.sourceHandle,
    targetHandle: e.targetHandle
  });
}
function Se(e, t) {
  return c(e).map((r) => ({
    id: r.id,
    name: r.name,
    actorType: r.name,
    nodes: t.filter((i) => {
      var n;
      return ((n = i.data) == null ? void 0 : n.actorType) === r.name;
    }).map((i) => l(i.id)),
    x: r.x,
    y: r.y,
    width: r.width,
    height: r.height,
    color: r.color
  }));
}
function be(e) {
  return e.map((t) => p({
    id: t.id,
    name: t.name,
    description: t.description,
    isSubProcess: t.isSubProcess,
    nodes: t.nodes.map(ve),
    connections: t.edges.map(fe),
    lanes: Se(t.swimlanes, t.nodes)
  }));
}
function W(e) {
  return u(JSON.parse(e));
}
const he = {
  id: "bpjs",
  name: "Chronicle BPJS",
  fileExtensions: [".bpjs", ".json"],
  isJson: !0,
  detect(e, t) {
    if (t != null && t.toLowerCase().endsWith(".bpjs")) return !0;
    try {
      const r = W(e);
      return Array.isArray(r.processes) || Array.isArray(r.nodes);
    } catch {
      return !1;
    }
  },
  import(e) {
    const t = W(e);
    return {
      processes: (Array.isArray(t.processes) ? t.processes : [t]).map(me),
      warnings: []
    };
  },
  export(e, t) {
    const r = {
      format: "bpjs",
      name: t,
      version: 1,
      processes: be(e)
    };
    return {
      content: `${JSON.stringify(r, null, 2)}
`,
      extension: ".bpjs",
      mimeType: "application/json"
    };
  }
};
export {
  he as bpjsAdapter
};
//# sourceMappingURL=bpjs-ChncFAVy.js.map
